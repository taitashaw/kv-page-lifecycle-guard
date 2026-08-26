"""Mutation suite plus an independent small-state oracle.

The previous model's 138 passing tests proved internal consistency against wrong
semantics. A suite that cannot kill a deliberately injected defect is worthless,
so every mutation below MUST be detected. A surviving mutant is a failing gate.
"""
from __future__ import annotations

import itertools
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from gm import control_plane, data_plane, policies, sim              # noqa: E402
from gm.types import (                                               # noqa: E402
    DownstreamEnvelope, ManagedObject, ObjType, Params, TrafficClass,
)

PASS, FAIL = [], []


def ck(name, cond, detail=""):
    (PASS if cond else FAIL).append((name, detail))
    print(("  PASS  " if cond else "  FAIL  ") + name +
          (f"   {detail}" if detail and not cond else ""))


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


def workload():
    """Small, deterministic, and it forces reuse of a draining frame."""
    reqs = []
    t = 0
    for i in range(24):
        reqs.append(R(t, i % 2, ObjType.KV_PAGE, i % 5,
                      TrafficClass.MANDATORY, 2176, t + 4000,
                      held=(i % 3 == 0)))
        if i % 3 == 0:
            reqs.append(R(t + 40, i % 2, ObjType.KV_PAGE, i % 5,
                          TrafficClass.MANDATORY, 0, t + 4000, is_release=True))
        # burst of speculation that CANNOT all be served, so some times out
        # and is cancelled pre-issue. Without real cancellations the refund
        # mutant never executes and the gate is vacuous.
        for j in range(3):
            reqs.append(R(t + 5 + j, i % 2, ObjType.EXPERT, 900 + i * 4 + j,
                          TrafficClass.SPECULATIVE, 4096, t + 9000))
        t += 90
    reqs.sort(key=lambda r: (r.arrival, r.is_release))
    return reqs


# Speculation must be ADMITTED (plenty of tokens and descriptors) yet unable to
# DISPATCH, because mandatory work always holds the port. It then times out in
# ready_s and is cancelled pre-issue, which is the only path that exercises the
# refund mutant.
P = Params(n_frames=3, n_descriptors=24, n_tenants=2,
           dispatch_queue_depth=4, max_axi_outstanding=2,
           spec_bucket_burst_bytes=1 << 20, spec_bucket_refill_per_cycle=64,
           speculative_max_wait=250)
E = DownstreamEnvelope()
HORIZON = 12000


def run_all(strict=False):
    return {n: sim.run(n, P, workload(), E, HORIZON, strict=strict)
            for n in policies.POLICY_NAMES}


def detected(res) -> bool:
    """A mutation is DETECTED if any policy trips a safety assertion."""
    return any(r.violations for r in res.values())


# =========================================================== independent oracle

def oracle_reachable_states():
    """Independent enumeration of the six-event contract on ONE page.

    Written from the contract table directly, NOT by calling the model. It
    enumerates every reachable (refcount, reservation, inflight, fill) tuple
    under the legal event set and derives which are evictable and which are
    draining.
    """
    start = (0, 0, 0, 0)
    seen, frontier = {start}, [start]
    while frontier:
        rc, rv, inf, fp = frontier.pop()
        nxt = []
        nxt.append((rc + 1, rv, inf, fp))                     # ACQUIRE
        nxt.append((rc, rv + 1, inf, fp + 1))                 # ADMIT (+FILL_START)
        if rv > 0:
            nxt.append((rc, rv - 1, inf + 1, fp))             # ISSUE
            nxt.append((rc, rv - 1, inf, max(0, fp - 1)))     # CANCEL pre-issue
        if inf > 0:
            nxt.append((rc, rv, inf - 1, max(0, fp - 1)))     # COMPLETE
        if rc > 0:
            nxt.append((rc - 1, rv, inf, fp))                 # RELEASE
        for s in nxt:
            if max(s) <= 3 and s not in seen:
                seen.add(s)
                frontier.append(s)
    return seen


def t_oracle():
    states = oracle_reachable_states()
    ck("oracle: reachable state space enumerated", len(states) >= 30, str(len(states)))

    for rc, rv, inf, fp in states:
        o = ManagedObject(key=0, tenant_id=0, obj_type=ObjType.KV_PAGE, phys_idx=0)
        o.logical_refcount, o.reservation, o.inflight, o.fill_pending = rc, rv, inf, fp
        oracle_evictable = (rc == 0 and rv == 0 and inf == 0 and fp == 0)
        oracle_draining = (rc == 0 and inf > 0)
        if o.evictable() != oracle_evictable:
            ck(f"oracle: evictable disagrees at {(rc,rv,inf,fp)}", False)
            return
        if o.draining() != oracle_draining:
            ck(f"oracle: draining disagrees at {(rc,rv,inf,fp)}", False)
            return
    ck("oracle: model agrees with the contract on EVERY reachable state", True)

    drain = [s for s in states if s[0] == 0 and s[2] > 0]
    ck("oracle: draining states exist and are never evictable",
       drain and all(not (s[1] == 0 and s[2] == 0 and s[3] == 0) for s in drain),
       f"{len(drain)} draining states")


# ================================================================== mutations

def mutate(name, patch, unpatch):
    print(f"\n[mutant] {name}")
    patch()
    try:
        res = run_all()
        killed = detected(res)
    except Exception as e:
        killed = True
        print(f"    (raised {type(e).__name__}: {str(e)[:70]})")
    finally:
        unpatch()
    ck(f"mutation killed: {name}", killed,
       "SURVIVED - the suite cannot detect this defect")


def t_mutations():
    base = run_all()
    ck("baseline: cancellations actually occur, so the refund mutant executes",
       any(r.cancelled > 0 for r in base.values()),
       f"cancelled={{n: r.cancelled for n, r in base.items()}}")
    ck("baseline: unmutated model has no violations", not detected(base),
       str({n: r.violations for n, r in base.items() if r.violations}))
    ck("baseline: transaction conservation holds for every policy",
       all("conservation" not in r.summary()["violations"] for r in base.values()))

    CP, DP = control_plane.ControlPlane, data_plane.DataPlane

    # 1. ADMIT must not create a logical reference
    orig = CP.ev_admit
    mutate("ADMIT increments logical_refcount",
           lambda: setattr(CP, "ev_admit",
                           lambda self, o: (setattr(o, "reservation", o.reservation + 1),
                                            setattr(o, "logical_refcount",
                                                    o.logical_refcount + 1))),
           lambda: setattr(CP, "ev_admit", orig))

    # 2. COMPLETE must decrement inflight, not refcount
    orig = CP.ev_complete
    def bad_complete(self, o, cycle):
        if o.logical_refcount > 0:
            o.logical_refcount -= 1
        else:
            o.inflight -= 1
    mutate("COMPLETE decrements refcount instead of inflight",
           lambda: setattr(CP, "ev_complete", bad_complete),
           lambda: setattr(CP, "ev_complete", orig))

    # 3. reuse of a draining frame
    orig = ManagedObject.evictable
    mutate("draining frame treated as evictable",
           lambda: setattr(ManagedObject, "evictable",
                           lambda self: self.logical_refcount == 0),
           lambda: setattr(ManagedObject, "evictable", orig))

    # 4. outstanding limit exceeded by one
    orig = DP.tick_accept
    def over_accept(self, cycle):
        self.p = self.p.__class__(**{**self.p.__dict__,
                                     "max_axi_outstanding": self.p.max_axi_outstanding + 1})
        return orig(self, cycle)
    mutate("AXI outstanding limit exceeded by one",
           lambda: setattr(DP, "tick_accept", over_accept),
           lambda: setattr(DP, "tick_accept", orig))

    # 5. DISPATCH treated as AXI acceptance
    orig = DP.tick_dispatch
    def dispatch_is_accept(self, cycle):
        out = orig(self, cycle)
        for d in out:
            d.accept_cycle = cycle
        return out
    mutate("DISPATCH treated as AXI acceptance",
           lambda: setattr(DP, "tick_dispatch", dispatch_is_accept),
           lambda: setattr(DP, "tick_dispatch", orig))

    # 6. completion before acceptance
    orig = DP.tick_dispatch
    def complete_early(self, cycle):
        out = orig(self, cycle)
        for d in out:
            d.complete_cycle = cycle
        return out
    mutate("transfer completes before acceptance",
           lambda: setattr(DP, "tick_dispatch", complete_early),
           lambda: setattr(DP, "tick_dispatch", orig))

    # 7. unbounded priority bypass destroys L_down_max
    def unbounded():
        try:
            DownstreamEnvelope(fifo_non_preemptive=False,
                               max_bypass_transactions=0).l_down_max(4, 144)
            return False
        except ValueError:
            return True
    ck("mutation killed: indefinite priority bypass admits no finite bound",
       unbounded(), "l_down_max returned a bound with unbounded bypass")

    # 8. speculative token refunded after an accepted transfer
    orig = CP.on_cancel_pre_issue
    def refund(self, d, cycle):
        if self.dp is not None:
            self.dp.spec_tokens += d.n_bytes       # refund regardless of accept
        d.cancel_cycle = cycle
        self._free_desc(d)
    CP.on_cancel_pre_issue = refund
    try:
        before = len(FAIL)
        t_token_no_refund()
        killed = len(FAIL) > before
    finally:
        CP.on_cancel_pre_issue = orig
    while len(FAIL) > before:
        FAIL.pop()
    print("\n[mutant] speculative token refunded after issued cancellation")
    ck("mutation killed: speculative token refunded after issued cancellation",
       killed, "SURVIVED - no directed cancellation case exists")

    # 9. deadline comparison <= becomes <
    from gm import checks as _checks
    orig = _checks.Checks.check_issue_deadline
    def strict_lt(self, d, cycle, env_held):
        if d.tclass is not TrafficClass.MANDATORY or not d.accepted:
            return
        if d.accept_cycle < d.issue_deadline or not env_held:
            return
        self._fail("issue_deadline_miss", cycle, f"desc {d.desc_id} (mutated <)")
    _checks.Checks.check_issue_deadline = strict_lt
    try:
        before = len(FAIL)
        t_deadline_boundary()
        killed = len(FAIL) > before
    finally:
        _checks.Checks.check_issue_deadline = orig
    for _ in range(len(FAIL) - before if killed else 0):
        FAIL.pop()
    print("\n[mutant] deadline comparison <= changed to <")
    ck("mutation killed: deadline comparison <= changed to <", killed,
       "SURVIVED - no directed boundary case exists")


def t_deadline_boundary():
    """A request accepted EXACTLY on its issue deadline is on time. Nothing in
    the random workload lands on the boundary, so the <= vs < mutation was
    invisible until this directed case existed."""
    from gm.checks import Checks
    from gm.types import Descriptor

    class Probe:
        def __init__(self): self.fired = []
        strict = False
        def _fail(self, k, c, d): self.fired.append(k)

    for accept, dl, expect_fire in ((100, 100, False),   # exactly on it
                                    (101, 100, True),    # one past
                                    (99, 100, False)):   # one early
        d = Descriptor(desc_id=0, tenant_id=0, obj_type=ObjType.KV_PAGE,
                       obj_key=0, phys_idx=0, generation=0,
                       tclass=TrafficClass.MANDATORY, n_bytes=2176,
                       slo_deadline=dl + 500, issue_deadline=dl, arrival=0)
        d.accept_cycle = accept
        c = Checks(P, strict=False)
        c.check_issue_deadline(d, accept, True)
        fired = bool(c.fired)
        ck(f"boundary: accept={accept} deadline={dl} -> "
           f"{'violation' if expect_fire else 'no violation'}",
           fired == expect_fire, f"fired={fired}")


def t_token_no_refund():
    """Directed: cancellation must move NO tokens.

    A workload test cannot see this. With a bucket large enough for speculation
    to be admitted, tokens sit at the burst ceiling and a refund is absorbed by
    the cap; with a bucket small enough for a refund to show, speculation is
    rejected at admission and never cancelled. The two requirements are
    mutually exclusive in one config, so this is a unit test.
    """
    from gm.checks import Checks
    from gm.coverage import Coverage
    from gm.control_plane import ControlPlane
    from gm.data_plane import DataPlane
    from gm.types import Descriptor

    pp = Params(n_frames=2, n_descriptors=4, n_tenants=2,
                spec_bucket_burst_bytes=8192, spec_bucket_refill_per_cycle=0)
    ch = Checks(pp, strict=False)
    cp = ControlPlane(pp, ch, Coverage())
    dp = DataPlane(pp, E, ch)
    cp.dp = dp

    from gm.types import ManagedObject, ObjState
    o = ManagedObject(key=1, tenant_id=0, obj_type=ObjType.EXPERT, phys_idx=0)
    o.state = ObjState.ALLOCATED_EMPTY
    cp.by_phys[0] = o
    cp.objects[cp.okey(0, ObjType.EXPERT, 1)] = o
    cp.ev_admit(o)
    o.fill_pending += 1

    d = Descriptor(desc_id=0, tenant_id=0, obj_type=ObjType.EXPERT, obj_key=1,
                   phys_idx=0, generation=0, tclass=TrafficClass.SPECULATIVE,
                   n_bytes=4096, slo_deadline=9999, issue_deadline=9000, arrival=0)
    cp.desc_table[0] = d
    cp.all_desc.append(d)

    before = dp.spec_tokens
    cp.on_cancel_pre_issue(d, 10)
    after = dp.spec_tokens
    ck("token: pre-issue cancellation moves NO tokens", before == after,
       f"{before} -> {after}")

    ok, why = dp.token_accounting(cp.all_desc)
    ck("token: accounting holds after cancellation", ok, why)


def t_conservation_and_bounds():
    res = run_all()
    for n, r in res.items():
        s = r.summary()
        ck(f"conservation[{n}]: accepted - completed == outstanding",
           "conservation" not in s["violations"], str(s["violations"]))
        ck(f"bounds[{n}]: outstanding never exceeds the limit",
           "outstanding_exceeded" not in s["violations"])
        ck(f"bounds[{n}]: dispatch queue never overflows",
           "dispatch_q_overflow" not in s["violations"])
        ck(f"safety[{n}]: no unsafe frame reuse",
           "unsafe_reuse" not in s["violations"])
        ck(f"order[{n}]: never completes before acceptance",
           "complete_before_accept" not in s["violations"])


def main():
    print("\n=== corrected model: oracle, conservation, mutation suite ===\n")
    print("[t_oracle]"); t_oracle()
    print("\n[t_deadline_boundary]"); t_deadline_boundary()
    print("\n[t_token_no_refund]"); t_token_no_refund()
    print("\n[t_conservation_and_bounds]"); t_conservation_and_bounds()
    print("\n[t_mutations]"); t_mutations()
    print(f"\nPASSED {len(PASS)}   FAILED {len(FAIL)}")
    if FAIL:
        print("\nFAILURES:")
        for n, d in FAIL:
            print(f"  {n}   {d}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
