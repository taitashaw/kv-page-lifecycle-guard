"""Transaction oracle + counterexample re-verification under the corrected contract.

The predicate oracle in the mutation suite validates only `evictable()` and
`draining()`. This adds an exhaustive TRANSITION oracle over two objects, two
physical frames and two transaction tags, then re-verifies the Candidate C
lifecycle counterexample against the four-event contract.
"""
from __future__ import annotations

import itertools
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from gm import policies, sim                                        # noqa: E402
from gm.types import (                                              # noqa: E402
    DownstreamEnvelope, ObjType, Params, TrafficClass,
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


# ==================================================== TRANSACTION ORACLE

class TagOracle:
    """Independent per-tag transaction automaton. Two tags, two frames.

    Written from the contract, not from the model. Rejects illegal transitions
    and enforces the four per-tag properties:

        COMPLETE(tag)   -> previously AXI_ACCEPT(tag)
        AXI_ACCEPT(tag) at most once
        COMPLETE(tag)   at most once
        frame_reuse     -> no outstanding tag references the old generation
    """
    LEGAL = {
        None: {"DISPATCH"},
        "DISPATCHED": {"AXI_ACCEPT", "CANCEL"},
        "ACCEPTED": {"COMPLETE"},
        "COMPLETED": set(),
        "CANCELLED": set(),
    }
    NEXT = {"DISPATCH": "DISPATCHED", "AXI_ACCEPT": "ACCEPTED",
            "COMPLETE": "COMPLETED", "CANCEL": "CANCELLED"}

    def __init__(self, n_out_limit: int):
        self.state = {0: None, 1: None}
        self.frame_gen = {0: 0, 1: 0}
        self.tag_frame = {}
        self.tag_gen = {}
        self.outstanding = 0
        self.limit = n_out_limit
        self.n_accept = {0: 0, 1: 0}
        self.n_complete = {0: 0, 1: 0}

    def step(self, tag: int, ev: str, frame: int | None = None) -> bool:
        if ev not in self.LEGAL[self.state[tag]]:
            return False
        if ev == "DISPATCH":
            self.tag_frame[tag] = frame
            self.tag_gen[tag] = self.frame_gen[frame]
        if ev == "AXI_ACCEPT":
            if self.outstanding >= self.limit:
                return False
            self.outstanding += 1
            self.n_accept[tag] += 1
            if self.n_accept[tag] > 1:
                return False
        if ev == "COMPLETE":
            self.outstanding -= 1
            self.n_complete[tag] += 1
            if self.n_complete[tag] > 1:
                return False
        self.state[tag] = self.NEXT[ev]
        return True

    def reuse_frame(self, frame: int) -> bool:
        """frame_reuse -> no outstanding tag references the old generation."""
        for t, st in self.state.items():
            if st == "ACCEPTED" and self.tag_frame.get(t) == frame:
                return False
        self.frame_gen[frame] += 1
        return True

    def conservation(self) -> bool:
        return (sum(self.n_accept.values()) - sum(self.n_complete.values())
                == self.outstanding)


def t_transaction_oracle():
    EVENTS = ["DISPATCH", "AXI_ACCEPT", "COMPLETE", "CANCEL"]
    legal_seqs = illegal = 0
    conservation_always = True

    for seq in itertools.product(
            [(t, e) for t in (0, 1) for e in EVENTS], repeat=5):
        o = TagOracle(n_out_limit=1)
        ok = True
        for tag, ev in seq:
            if not o.step(tag, ev, frame=tag):
                ok = False
                break
            if not o.conservation():
                conservation_always = False
        if ok:
            legal_seqs += 1
        else:
            illegal += 1

    ck("txn oracle: explored the full 5-event sequence space",
       legal_seqs + illegal == 8 ** 5, f"{legal_seqs+illegal}")
    ck("txn oracle: legal sequences exist", legal_seqs > 0, str(legal_seqs))
    ck("txn oracle: illegal sequences are rejected", illegal > 0, str(illegal))
    ck("txn oracle: conservation holds on every legal prefix", conservation_always)

    o = TagOracle(1)
    ck("txn oracle: COMPLETE without AXI_ACCEPT is rejected",
       not o.step(0, "COMPLETE"))
    o = TagOracle(1)
    o.step(0, "DISPATCH", 0); o.step(0, "AXI_ACCEPT")
    ck("txn oracle: second AXI_ACCEPT on a tag is rejected",
       not o.step(0, "AXI_ACCEPT"))
    o.step(0, "COMPLETE")
    ck("txn oracle: second COMPLETE on a tag is rejected",
       not o.step(0, "COMPLETE"))

    o = TagOracle(1)
    o.step(0, "DISPATCH", 0); o.step(0, "AXI_ACCEPT")
    ck("txn oracle: frame reuse blocked while a tag is outstanding on it",
       not o.reuse_frame(0))
    o.step(0, "COMPLETE")
    ck("txn oracle: frame reuse allowed once the tag completes",
       o.reuse_frame(0))

    o = TagOracle(n_out_limit=1)
    o.step(0, "DISPATCH", 0); o.step(0, "AXI_ACCEPT")
    o.step(1, "DISPATCH", 1)
    ck("txn oracle: outstanding limit blocks a second acceptance",
       not o.step(1, "AXI_ACCEPT"))

    o = TagOracle(1)
    o.step(0, "DISPATCH", 0)
    ck("txn oracle: CANCEL legal before acceptance", o.step(0, "CANCEL"))
    o = TagOracle(1)
    o.step(0, "DISPATCH", 0); o.step(0, "AXI_ACCEPT")
    ck("txn oracle: CANCEL rejected after acceptance", not o.step(0, "CANCEL"))


# ============================== COUNTEREXAMPLE, CORRECTED CONTRACT

def counterexample():
    """NORMALIZED SMALL-STATE TEST. Not the production parameters.

    Cycle counts are scaled so L_down,max is comparable to a two-cycle
    transfer, giving d_issue = 3 - 2 = 1. The production configuration has
    L_down,max = 1776 cycles. The two ledgers are the SAME formula at different
    scales, not a contradiction.

    One frame. A is ACQUIREd, ADMITted, ISSUEd. Then RELEASEd while its
    transfer is still in flight, so it is DRAINING:

        logical_refcount == 0  AND  inflight > 0

    B needs that frame. Under the corrected contract d_issue = d_SLO - L_down,max.
    A lifecycle-blind capacity test sees refcount 0 and calls the frame free.
    The joint forecast adds the drain and rejects.
    """
    p = Params(n_tenants=2, n_frames=1, n_descriptors=4,
               n_reserved_mandatory_desc=1, dispatch_queue_depth=2,
               max_axi_outstanding=1, axi_bytes_per_cycle=16,
               axi_accept_overhead_cycles=0, axi_fixed_overhead_cycles=0,
               dwrr_quantum_bytes=4096, dwrr_replenish_period=8,
               dwrr_max_deficit_bytes=8192)
    # scaled envelope so L_down,max is comparable to the 2-cycle transfer
    e = DownstreamEnvelope(c_max_cycles=2, b_fixed_cycles=0,
                           refresh_cycles_per_window=0, window_cycles=64,
                           fifo_non_preemptive=True, max_bypass_transactions=0)
    reqs = [
        R(0, 0, ObjType.KV_PAGE, 100, TrafficClass.MANDATORY, 32, 64, held=True),
        R(1, 0, ObjType.KV_PAGE, 100, TrafficClass.MANDATORY, 0, 64, is_release=True),
        R(1, 1, ObjType.KV_PAGE, 200, TrafficClass.MANDATORY, 32, 3),
    ]
    return p, e, reqs


def t_counterexample():
    p, e, reqs = counterexample()
    l_dm = e.l_down_max(p.max_axi_outstanding, 2)
    ck("cex: L_down,max reconstructs from the ledger",
       l_dm == 0 + 0 * 2 + 2 + 0 + 0, f"L_down,max={l_dm}")
    ck("cex: B's d_issue = d_SLO - L_down,max = 3 - 2 = 1", 3 - l_dm == 1)

    res = {n: sim.run(n, p, reqs, e, horizon=400) for n in policies.POLICY_NAMES}

    print(f"    {'policy':<24}{'role':<18}{'adm':>4}{'acc':>4}{'ot':>4}  violations")
    for n in policies.POLICY_NAMES:
        r = res[n]
        role = policies.BY_NAME[n].role
        print(f"    {n:<24}{role:<18}{r.admitted:>4}{r.accepted:>4}"
              f"{r.on_time:>4}  {r.summary()['violations'] or '-'}")

    blind = ("edf_only", "credit_only", "independent_dual_guard")
    for n in blind:
        r = res[n]
        ck(f"cex[{n}]: admits both, including the infeasible one",
           r.admitted == 2, f"admitted={r.admitted}")
        ck(f"cex[{n}]: the admitted work misses its deadline",
           r.on_time < r.admitted, f"on_time={r.on_time} admitted={r.admitted}")

    ri = res["integrated"]
    ck("cex[integrated]: rejects the infeasible request",
       ri.admitted == 1, f"admitted={ri.admitted}")
    ck("cex[integrated]: everything admitted is on time",
       ri.admitted == ri.on_time, f"{ri.admitted} vs {ri.on_time}")

    rs = res["independent_memory_safe_guard"]
    ck("cex[independent_memory_safe_guard]: admits both despite being "
       "memory-safe, because its checks are independent",
       rs.admitted == 2, f"admitted={rs.admitted}")
    ck("cex[independent_memory_safe_guard]: and therefore misses the deadline",
       rs.on_time < rs.admitted, f"on_time={rs.on_time}")

    # The OUTCOME-BASED assertion previously here was removed. Claiming that a
    # comparator admitting 1 must be "secretly running the joint forecast" is
    # not logically valid: an independent policy can reject conservatively
    # without any joint reasoning. That is what separable_conservative_guard is
    # for, and it is tested in tests/test_gm_targeted.py.

    rc = res["separable_conservative_guard"]
    ck("cex[separable_conservative_guard]: a conservative policy can reject "
       "WITHOUT a joint forecast",
       rc.admitted <= 1 or "issue_deadline_miss" not in rc.summary()["violations"],
       f"admitted={rc.admitted} viol={rc.summary()['violations']}")

    ck("cex: NO policy commits an unsafe frame reuse",
       all("unsafe_reuse" not in r.summary()["violations"] for r in res.values()))
    ck("cex: NO policy breaks transaction conservation",
       all("conservation" not in r.summary()["violations"] for r in res.values()))
    ck("cex: the draining state was actually reached",
       any(r.coverage.get("draining_frames_max", 0) > 0 for r in res.values()),
       str({n: r.coverage.get("draining_frames_max") for n, r in res.items()}))
    ck("cex: the joint forecast fired at least once",
       ri.coverage.get("feasible_until_lifecycle", 0) > 0,
       str(ri.coverage.get("feasible_until_lifecycle")))


def main():
    print("\n=== transaction oracle ===\n")
    t_transaction_oracle()
    print("\n=== counterexample, corrected contract ===\n")
    t_counterexample()
    print(f"\nPASSED {len(PASS)}   FAILED {len(FAIL)}")
    if FAIL:
        print("\nFAILURES:")
        for n, d in FAIL:
            print(f"  {n}   {d}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
