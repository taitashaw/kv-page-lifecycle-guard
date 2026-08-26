"""Safety assertions, including the two conservation laws the contract names."""
from __future__ import annotations

from .types import ManagedObject, SafetyViolation, TrafficClass


class Checks:
    ILA_TRIGGERS = {
        "cross_tenant": "trig_cross_tenant_hit",
        "unsafe_reuse": "trig_frame_reuse_not_quiescent",
        "underflow": "trig_counter_underflow",
        "outstanding_exceeded": "trig_outstanding_over_limit",
        "conservation": "trig_txn_conservation_fail",
        "complete_before_accept": "trig_complete_before_accept",
        "cancel_after_accept": "trig_cancel_after_accept",
        "issue_deadline_miss": "trig_admitted_issue_deadline_miss",
        "spec_took_reserved": "trig_spec_consumed_reserved",
        "dispatch_q_overflow": "trig_dispatch_queue_overflow",
        "event_accounting": "trig_event_accounting_fail",
        "token_accounting": "trig_spec_token_accounting_fail",
        "accept_path": "trig_accept_path_violation",
    }

    def __init__(self, params, strict: bool = True):
        self.p = params
        self.strict = strict
        self.fired: list[SafetyViolation] = []

    def _fail(self, kind, cycle, detail):
        v = SafetyViolation(kind, cycle, detail)
        self.fired.append(v)
        if self.strict:
            raise v

    def check_tenant(self, d, o: ManagedObject, cycle):
        if d.tenant_id != o.tenant_id:
            self._fail("cross_tenant", cycle,
                       f"tenant {d.tenant_id} touching object of tenant {o.tenant_id}")

    def check_frame_reuse(self, o: ManagedObject, cycle):
        """frame_reused -> refcount==0 && inflight==0 && reservation==0 && !fill_pending"""
        if not o.evictable():
            self._fail("unsafe_reuse", cycle,
                       f"reuse of phys {o.phys_idx} with refcount={o.logical_refcount} "
                       f"inflight={o.inflight} reservation={o.reservation} "
                       f"fill_pending={o.fill_pending}")

    def check_conservation(self, dp, cycle):
        """n_accepted - n_completed == n_outstanding"""
        if not dp.conservation_holds():
            self._fail("conservation", cycle,
                       f"accepted {dp.n_accept} - completed {dp.n_complete} "
                       f"!= outstanding {dp.outstanding()}")

    def check_outstanding(self, dp, cycle):
        if dp.outstanding() > self.p.max_axi_outstanding:
            self._fail("outstanding_exceeded", cycle,
                       f"{dp.outstanding()} > {self.p.max_axi_outstanding}")
        if len(dp.dispatch_q) > self.p.dispatch_queue_depth:
            self._fail("dispatch_q_overflow", cycle,
                       f"{len(dp.dispatch_q)} > {self.p.dispatch_queue_depth}")

    def check_order(self, d, cycle):
        if d.completed and not d.accepted:
            self._fail("complete_before_accept", cycle,
                       f"desc {d.desc_id} completed without AXI accept")
        if d.cancelled and d.accepted:
            self._fail("cancel_after_accept", cycle,
                       f"desc {d.desc_id} cancelled after accept")

    def check_counters(self, o: ManagedObject, cycle):
        for n, v in (("refcount", o.logical_refcount), ("inflight", o.inflight),
                     ("reservation", o.reservation), ("fill", o.fill_pending)):
            if v < 0:
                self._fail("underflow", cycle, f"{n} < 0 on phys {o.phys_idx}")

    def check_issue_deadline(self, d, cycle, envelope_held):
        if d.tclass is not TrafficClass.MANDATORY or not d.accepted:
            return
        if d.accept_cycle <= d.issue_deadline or not envelope_held:
            return
        self._fail("issue_deadline_miss", cycle,
                   f"desc {d.desc_id} accepted at {d.accept_cycle}, "
                   f"issue-deadline {d.issue_deadline}")

    def check_spec_reserve(self, cp, cycle):
        for d in cp.desc_table.values():
            if d.tclass is TrafficClass.SPECULATIVE and d.reserved_slot:
                self._fail("spec_took_reserved", cycle,
                           f"speculative desc {d.desc_id} holds the reserved slot")

    def per_cycle(self, cp, dp, cycle, envelope_held):
        ok, why = cp.event_accounting()
        if not ok:
            self._fail("event_accounting", cycle, why)
        ok, why = dp.token_accounting(cp.all_desc)
        if not ok:
            self._fail("token_accounting", cycle, why)
        ok, why = dp.accept_path_integrity(cp.all_desc)
        if not ok:
            self._fail("accept_path", cycle, why)
        for o in cp.by_phys.values():
            self.check_counters(o, cycle)
        self.check_conservation(dp, cycle)
        self.check_outstanding(dp, cycle)
        self.check_spec_reserve(cp, cycle)
        for d in cp.desc_table.values():
            self.check_order(d, cycle)
            self.check_issue_deadline(d, cycle, envelope_held)
