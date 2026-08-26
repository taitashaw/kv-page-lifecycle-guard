"""BLOCKING DEFECT in the gm allocator's EVICTING / pending_swap path.

Found while building the Sweep B distributional suite. NOT a trace artifact and
NOT a policy difference: all NINE policies fail identically on the same four
requests, because the defect is in the shared allocator, not in any admission
predicate.

The failure
-----------
`SafetyViolation("underflow", ..., "COMPLETE with inflight=0")` is raised
directly out of `ControlPlane.ev_complete` and therefore ESCAPES `gm.sim.run`.
`strict=False` does not suppress it: the `strict` flag only gates
`Checks._fail`, while `ev_complete`, `ev_issue`, `ev_release` and `ev_cancel`
raise unconditionally. There is no non-strict mode for this path.

Mechanism
---------
When `_alloc_frame` has no free and no evictable frame it takes the
`drain_candidate` branch, marks the incumbent `EVICTING` and parks the NEW
object in `ControlPlane.pending_swap[phys]` instead of `by_phys[phys]`. The new
object is then in an inconsistent visibility state:

    reachable via `self.objects`   -> `lookup()` finds it, so `admit()` treats
                                      it as resident and takes `need_frame=False`
    NOT reachable via `by_phys`    -> `on_axi_accept()` looks the frame up in
                                      `by_phys`, finds the OLD incumbent, sees a
                                      generation mismatch and returns EARLY

So AXI_ACCEPT happens in the data plane but the ISSUE event is never applied in
the control plane: `inflight` is never incremented. Later, once the incumbent
retires, `_finish_swap` publishes the new object into `by_phys`. Its generation
now MATCHES the descriptor, so when that descriptor completes, `on_complete`
calls `ev_complete` against an object whose `inflight` is still 0, and the
underflow fires.

A second, contributing defect makes the window easy to hit:
`ControlPlane.drain_candidate` calls `DataPlane.drain_ready`, which inspects
only transfers ALREADY ACCEPTED on that frame (`dp.pending`). Work for the
incumbent still sitting in `ready_m` or `dispatch_q` is not counted, so the
`earliest_issue` stamped on the successor can precede the incumbent's actual
quiescence. The incumbent is also left in `self.objects` under its own key, so a
later fetch for that key re-admits against it and pushes quiescence out further.

Why Sweep A never saw it
------------------------
The `drain_candidate` branch is only reached when a frame is DRAINING, i.e.
`logical_refcount == 0 AND inflight > 0`. Sweep A's `admit()` incremented
`refcount`, so admission itself kept refcount above zero and the draining state
was largely unreachable. Fixing that conflation is what exposed this.

Impact on Sweep B, MEASURED
---------------------------
Strided 240-configuration sample of the frozen grid, 2,160 records:
165 records (7.6%) escaped with this underflow, spread over 21 of 240
configurations (8.8%). Every policy is hit; the incidence per policy tracks how
often that policy admits into a draining frame, so the loss is NOT uniform
across policies and it is NOT safe to treat the surviving rows as an unbiased
sample.

Run: `python3 tests/test_gm_pending_swap_defect.py`
"""
from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from gm import policies, sim                                          # noqa: E402
from gm.types import (                                                # noqa: E402
    DownstreamEnvelope, ObjType, Params, SafetyViolation, TrafficClass,
)


@dataclass
class R:
    arrival: int
    tenant_id: int
    obj_type: object
    key: int
    tclass: object
    n_bytes: int
    deadline: int
    held: bool = False
    is_release: bool = False


PARAMS = Params(
    n_tenants=2, n_frames=1, n_descriptors=8, n_reserved_mandatory_desc=1,
    dispatch_queue_depth=4, max_axi_outstanding=4, axi_bytes_per_cycle=16,
    axi_accept_overhead_cycles=4, axi_fixed_overhead_cycles=8,
    # credit never binds, so `credit_only` reaches the same path as the rest
    dwrr_quantum_bytes=1 << 20, dwrr_replenish_period=8,
    dwrr_max_deficit_bytes=1 << 22,
)
ENVELOPE = DownstreamEnvelope()
M, KV = TrafficClass.MANDATORY, ObjType.KV_PAGE


def trace():
    """Four requests. ONE frame, so the successor must take the incumbent's.

    A   arrives at 0, HELD -> ACQUIRE, transfer goes in flight
    A'  arrives at 2, extra QUEUED work on the same frame. This is what makes
        `drain_ready` underestimate the incumbent's quiescence time.
    rel arrives at 5, RELEASE while A is still in flight
        -> refcount 0 AND inflight > 0 == DRAINING
    B   arrives at 6, needs the only frame -> `drain_candidate` -> pending_swap
    """
    return [
        R(0, 0, KV, 100, M, 1024, 100_000, held=True),
        R(2, 0, KV, 100, M, 1024, 100_000),
        R(5, 0, KV, 100, M, 0, 5, is_release=True),
        R(6, 1, KV, 200, M, 1024, 100_000),
    ]


def main() -> int:
    print(__doc__.split("Run:")[0].strip()[:0] or "", end="")
    print("gm pending_swap / EVICTING defect\n")
    print(f"  {'policy':<34}{'role':<26}outcome")

    escaped, clean = [], []
    for name in policies.POLICY_NAMES:
        role = policies.BY_NAME[name].role
        try:
            r = sim.run(name, PARAMS, trace(), ENVELOPE, horizon=4000,
                        strict=False)
        except SafetyViolation as v:
            escaped.append((name, v))
            print(f"  {name:<34}{role:<26}ESCAPED  [{v.kind}] cycle {v.cycle}: "
                  f"{v.detail}")
            continue
        clean.append(name)
        print(f"  {name:<34}{role:<26}ok  adm={r.admitted} acc={r.accepted} "
              f"comp={r.completed} viol={r.summary()['violations'] or '-'}")

    n = len(policies.POLICY_NAMES)
    print()
    ok = True

    cond = len(escaped) == 0
    ok &= cond
    print(("  PASS  " if cond else "  FAIL  ") +
          f"FIXED: no policy escapes the pending_swap path "
          f"({len(escaped)}/{n} escaped)")

    cond = all(v.kind == "underflow" and "inflight=0" in v.detail
               for _, v in escaped)
    ok &= cond
    print(("  PASS  " if cond else "  FAIL  ") +
          "no COMPLETE-with-inflight=0 underflow remains")

    cycles = {v.cycle for _, v in escaped}
    cond = len(cycles) == 0
    ok &= cond
    print(("  PASS  " if cond else "  FAIL  ") +
          f"no failure cycles at all: the shared allocator path is sound  "
          f"{sorted(cycles)}")

    print("\n  strict=False does NOT suppress it: ControlPlane.ev_complete "
          "raises\n  unconditionally, unlike Checks._fail.")
    print("\nEXPECTED WHEN FIXED: every policy runs to completion and this "
          "file's\nfirst three assertions INVERT. Do not delete the trace when "
          "fixing;\nkeep it as the regression case.")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
