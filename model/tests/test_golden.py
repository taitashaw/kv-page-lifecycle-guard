"""Regression tests for the golden model.

These encode the properties the RTL must also satisfy. A test here that fails
is a finding, not a nuisance.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from golden import sim, traces                                   # noqa: E402
from golden.data_plane import DataPlane                          # noqa: E402
from golden.checks import Checks                                 # noqa: E402
from golden.types import (                                       # noqa: E402
    ManagedObject, ObjState, ObjType, Params, ServiceEnvelope, TrafficClass,
)

PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append((name, detail))
    print(("  PASS  " if cond else "  FAIL  ") + name + (f"   {detail}" if detail and not cond else ""))


# ------------------------------------------------------ 1. reclaim predicate

def t_reclaim_predicate():
    o = ManagedObject(key=1, tenant_id=0, obj_type=ObjType.KV_PAGE, phys_idx=0)
    o.state = ObjState.RESIDENT
    check("reclaim: all-zero object is quiescent", o.quiescent())
    for fld in ("refcount", "inflight", "fill_pending", "reserved"):
        setattr(o, fld, 1)
        check(f"reclaim: {fld}>0 blocks reuse", not o.quiescent())
        setattr(o, fld, 0)
    o.unretired_by_gen[o.generation] = 1
    check("reclaim: unretired current-gen completion blocks reuse", not o.quiescent())
    o.unretired_by_gen[o.generation] = 0
    check("reclaim: quiescent again once retired", o.quiescent())


# ------------------------------------------- 2. service credit is time-based

def t_credit_time_based_not_completion():
    """The bug John caught: service credit must be charged on ISSUE and
    replenished by TIME. Replenishing on completion double-credits."""
    p = Params(n_tenants=2, dwrr_quantum_bytes=1000, dwrr_replenish_period=10,
               dwrr_max_deficit_bytes=10_000)
    dp = DataPlane(p, ServiceEnvelope(), Checks(p))
    dp.replenish(0)
    after_first = dp.deficit[0]
    check("credit: replenish fires on period boundary", after_first == 1000, str(after_first))
    for c in range(1, 10):
        dp.replenish(c)
    check("credit: no replenish off-period", dp.deficit[0] == 1000, str(dp.deficit[0]))
    dp.replenish(10)
    check("credit: replenishes again next period", dp.deficit[0] == 2000, str(dp.deficit[0]))

    src = (Path(__file__).resolve().parents[1] / "golden" / "data_plane.py").read_text()
    tick = src.split("def tick_completions")[1].split("def ")[0]
    check("credit: tick_completions never touches deficit", "deficit" not in tick)

    cap = p.dwrr_max_deficit_bytes
    for c in range(0, 10_000, 10):
        dp.replenish(c)
    check("credit: deficit saturates, no overflow", dp.deficit[0] == cap, str(dp.deficit[0]))


# ---------------------------------------- 3. data plane never mutates lifecycle

def t_data_plane_is_not_a_mutator():
    src = (Path(__file__).resolve().parents[1] / "golden" / "data_plane.py").read_text()
    for forbidden in ("refcount", "fill_pending", ".generation =", "unretired"):
        check(f"ownership: data plane never writes {forbidden!r}",
              forbidden not in src)


# ------------------------------------------------------- 4. the counterexample

def t_counterexample():
    """The Candidate C counterexample, executable.

    Separate deadline and capacity tests each pass, yet no legal execution
    meets the deadline. Every separate-test policy must admit and go late; the
    joint predicate must reject.
    """
    p, reqs, _ = traces.one_frame_counterexample()
    got = {n: sim.run(n, p, reqs, "counterexample", strict=False)
           for n in ("edf_only", "credit_only", "lifecycle_edf", "integrated")}

    for n in ("edf_only", "credit_only", "lifecycle_edf"):
        r = got[n]
        check(f"counterexample[{n}]: admits both requests",
              r.admitted == 2, f"admitted={r.admitted}")
        check(f"counterexample[{n}]: one admitted request goes LATE",
              r.admitted - r.on_time == 1, f"admitted={r.admitted} on_time={r.on_time}")
        check(f"counterexample[{n}]: D1 deadline_miss assertion fires",
              "deadline_miss" in [v.kind for v in r.violations],
              str([v.kind for v in r.violations]))

    r = got["integrated"]
    check("counterexample[integrated]: rejects the infeasible request",
          r.admitted == 1, f"admitted={r.admitted}")
    check("counterexample[integrated]: nothing admitted goes late",
          r.admitted == r.on_time, f"admitted={r.admitted} on_time={r.on_time}")
    check("counterexample[integrated]: no D1 violation at all",
          not r.violations, str([v.kind for v in r.violations]))

    check("counterexample: separate capacity+deadline (lifecycle_edf) is NOT enough",
          got["lifecycle_edf"].admitted > got["integrated"].admitted,
          f"lifecycle={got['lifecycle_edf'].admitted} integrated={r.admitted}")

    check("counterexample: no unsafe reuse in ANY policy",
          all("unsafe_reuse" not in [v.kind for v in x.violations] for x in got.values()))


# ------------------------------------------- 5. no unsafe reuse under pressure

def t_no_unsafe_reuse():
    p, reqs, name = traces.reuse_pressure()
    for pol in ("fifo", "edf_only", "credit_only", "tuned_axi_qos",
                "lifecycle_edf", "integrated"):
        r = sim.run(pol, p, reqs, name, strict=False)
        kinds = [v.kind for v in r.violations]
        check(f"reuse-pressure[{pol}]: no unsafe_reuse", "unsafe_reuse" not in kinds, str(kinds))
        check(f"reuse-pressure[{pol}]: no cross_tenant", "cross_tenant" not in kinds, str(kinds))
        check(f"reuse-pressure[{pol}]: no underflow", "underflow" not in kinds, str(kinds))
        check(f"reuse-pressure[{pol}]: no lost completion", "lost_completion" not in kinds, str(kinds))


# --------------------------------------------------------- 6. determinism

def t_determinism():
    p, reqs, name = traces.two_tenant_workload()
    a = sim.run("integrated", p, reqs, name, strict=False).summary()
    b = sim.run("integrated", p, reqs, name, strict=False).summary()
    check("determinism: identical summary across runs", a == b)

    p2, reqs2, _ = traces.two_tenant_workload()
    check("determinism: trace regenerates identically",
          [(r.arrival, r.tenant_id, r.key, r.n_bytes) for r in reqs]
          == [(r.arrival, r.tenant_id, r.key, r.n_bytes) for r in reqs2])


# ------------------------------------- 7. speculation cannot take the reserve

def t_speculation_never_takes_reserved():
    p, reqs, name = traces.two_tenant_workload()
    for pol in ("fifo", "integrated", "tuned_axi_qos"):
        r = sim.run(pol, p, reqs, name, strict=False)
        kinds = [v.kind for v in r.violations]
        check(f"reserve[{pol}]: speculation never holds the reserved slot",
              "spec_blocks_mandatory" not in kinds, str(kinds))


# ------------------------------------------------- 8. accounting conservation

def t_accounting():
    p, reqs, name = traces.two_tenant_workload()
    r = sim.run("integrated", p, reqs, name, strict=False)
    check("accounting: admitted + rejected + expired >= offered",
          r.admitted + r.rejected + r.expired_before_admission >= r.offered,
          f"{r.admitted}+{r.rejected}+{r.expired_before_admission} vs {r.offered}")
    check("accounting: completed <= admitted",
          r.completed <= r.admitted, f"{r.completed} vs {r.admitted}")
    check("accounting: on_time <= completed",
          r.on_time <= r.completed, f"{r.on_time} vs {r.completed}")
    check("accounting: ddr utilisation in [0,1]", 0.0 <= r.ddr_util <= 1.0, str(r.ddr_util))


# --------------------------------------------- 9. admission-rate trade visible

def t_admission_trade_is_reported():
    p, reqs, name = traces.two_tenant_workload()
    rows = {pol: sim.run(pol, p, reqs, name, strict=False).summary()
            for pol in ("edf_only", "lifecycle_edf", "integrated", "tuned_axi_qos")}
    for pol, s in rows.items():
        for k in ("offered", "admitted", "completed", "on_time",
                  "expired_before_admission"):
            check(f"report[{pol}]: {k} reported separately", k in s)
    check("report: on-time-per-OFFERED is the headline metric",
          all("on_time_per_offered_%" in s for s in rows.values()))


def t_terminates_no_livelock():
    """Every policy must drain. A run that hits the cycle cap is a livelock,
    not a slow run. This caught a real deadlock where the reserved-descriptor
    rule was enforced twice, at admission and again at issue."""
    for tname, fn in traces.REGISTRY.items():
        p, reqs, _ = fn()
        last = max(r.arrival for r in reqs)
        for pol in ("fifo", "edf_only", "credit_only", "tuned_axi_qos",
                    "lifecycle_edf", "integrated"):
            r = sim.run(pol, p, reqs, tname, strict=False, max_cycles=100_000)
            check(f"terminates[{tname}/{pol}]: drains well before the cap",
                  r.cycles < 100_000 - 1, f"cycles={r.cycles}")
            check(f"terminates[{tname}/{pol}]: admitted == completed + cancelled",
                  r.completed + r.cancelled == r.admitted,
                  f"completed={r.completed} cancelled={r.cancelled} admitted={r.admitted}")
            check(f"terminates[{tname}/{pol}]: finished within 20x the arrival span",
                  r.cycles < max(1000, last * 20), f"cycles={r.cycles} last_arrival={last}")


def main():
    print("\n=== golden model regression ===\n")
    for fn in (t_reclaim_predicate, t_credit_time_based_not_completion,
               t_data_plane_is_not_a_mutator, t_counterexample,
               t_no_unsafe_reuse, t_determinism,
               t_speculation_never_takes_reserved, t_accounting,
               t_admission_trade_is_reported, t_terminates_no_livelock):
        print(f"[{fn.__name__}]")
        fn()
        print()
    print(f"PASSED {len(PASS)}   FAILED {len(FAIL)}")
    if FAIL:
        print("\nFAILURES:")
        for n, d in FAIL:
            print(f"  {n}   {d}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
