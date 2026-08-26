"""Policies. EIGHT total, and the list is frozen for record counting."""
from __future__ import annotations

from .types import TrafficClass


class Policy:
    name = "base"
    role = "comparator"

    def __init__(self, params, envelope):
        self.p = params
        self.env = envelope

    def _svc(self, nbytes):
        return -(-nbytes // self.p.axi_bytes_per_cycle) + self.p.axi_fixed_overhead_cycles

    def _ahead(self, req, dp):
        return sum(self._svc(d.n_bytes) for d in dp.ready_m
                   if d.slo_deadline <= req.deadline) \
            + sum(self._svc(d.n_bytes) for d in dp.dispatch_q)

    def _drain(self, cp, cycle):
        """Cycles until SOME frame is legally reusable, or None."""
        if cp.free_frames or cp.evictable_frames():
            return 0
        cand = cp.drain_candidate(cycle)
        return None if cand is None else max(0, cand[1] - cycle)

    def feasible(self, req, cycle, cp, dp, d_issue):
        raise NotImplementedError


class Fifo(Policy):
    name = "fifo"
    def feasible(self, req, cycle, cp, dp, d_issue): return True


class EdfOnly(Policy):
    name = "edf_only"
    def feasible(self, req, cycle, cp, dp, d_issue):
        if req.tclass is not TrafficClass.MANDATORY: return True
        return cycle + self._ahead(req, dp) <= d_issue


class CreditOnly(Policy):
    name = "credit_only"
    def feasible(self, req, cycle, cp, dp, d_issue):
        return dp.deficit[req.tenant_id] >= req.n_bytes


class TunedAxiQos(Policy):
    name = "tuned_axi_qos"
    role = "primary baseline"
    def feasible(self, req, cycle, cp, dp, d_issue): return True


class LifecycleEdf(Policy):
    name = "lifecycle_edf"
    def feasible(self, req, cycle, cp, dp, d_issue):
        if req.tclass is not TrafficClass.MANDATORY: return True
        if cycle + self._ahead(req, dp) > d_issue: return False
        if cp.lookup(req.tenant_id, req.obj_type, req.key) is not None: return True
        return self._drain(cp, cycle) is not None


class IndependentDualGuard(Policy):
    """NEGATIVE CONTROL, intentionally lifecycle-blind. Not a performance
    comparator. Its capacity test may be unsafe by design."""
    name = "independent_dual_guard"
    role = "negative control"
    def feasible(self, req, cycle, cp, dp, d_issue):
        if req.tclass is not TrafficClass.MANDATORY: return True
        if cycle + self._ahead(req, dp) > d_issue: return False
        if cp.lookup(req.tenant_id, req.obj_type, req.key) is not None: return True
        if cp.free_frames: return True
        return any(o.logical_refcount == 0 for o in cp.by_phys.values())


class IndependentMemorySafeGuard(Policy):
    """Safe allocator, INDEPENDENT feasibility decisions.

    Identical metadata, identical eviction invariants, identical allocator.
    Differs from Integrated only by deciding deadline and capacity separately
    rather than by a joint forecast."""
    name = "independent_memory_safe_guard"
    role = "safe independent"
    def feasible(self, req, cycle, cp, dp, d_issue):
        if req.tclass is not TrafficClass.MANDATORY: return True
        if cycle + self._ahead(req, dp) > d_issue:       # deadline test, alone
            return False
        if cp.lookup(req.tenant_id, req.obj_type, req.key) is not None:
            return True
        return self._drain(cp, cycle) is not None        # capacity test, alone


class SeparableConservativeGuard(Policy):
    """Assumes a WORST-CASE lifecycle delay in its deadline test, but never
    computes the candidate's joint forecast.

    This is the comparator that actually tests the candidate's claim: does the
    joint forecast admit MORE USEFUL WORK than a conservative policy that offers
    the same admission guarantee? A conservative policy can reject the
    counterexample without any joint reasoning, simply by always budgeting for
    the worst drain.
    """
    name = "separable_conservative_guard"
    role = "conservative independent"

    def feasible(self, req, cycle, cp, dp, d_issue):
        if req.tclass is not TrafficClass.MANDATORY:
            return True
        # deadline test with a CONSTANT worst-case lifecycle allowance, not the
        # measured drain of any particular frame
        worst_drain = self.env.c_max_cycles
        if cycle + self._ahead(req, dp) + worst_drain > d_issue:
            return False
        if cp.lookup(req.tenant_id, req.obj_type, req.key) is not None:
            return True
        return self._drain(cp, cycle) is not None      # capacity test, separate


class Integrated(Policy):
    """Joint forecast: deadline, capacity and non-evictable state together."""
    name = "integrated"
    role = "candidate"
    def feasible(self, req, cycle, cp, dp, d_issue):
        if req.tclass is TrafficClass.SPECULATIVE:
            if len(cp.free_desc) <= cp.reserved_desc_free: return False
            return dp.spec_tokens >= req.n_bytes
        hit = cp.lookup(req.tenant_id, req.obj_type, req.key) is not None
        drain = 0 if hit else self._drain(cp, cycle)
        if drain is None: return False
        ahead = self._ahead(req, dp)
        blind_ok = cycle + ahead <= d_issue
        joint_ok = cycle + drain + ahead <= d_issue
        if blind_ok and not joint_ok:
            cp.cov.feasible_until_lifecycle += 1
        return joint_ok


ALL_POLICIES = [Fifo, EdfOnly, CreditOnly, TunedAxiQos, LifecycleEdf,
                IndependentDualGuard, IndependentMemorySafeGuard,
                SeparableConservativeGuard, Integrated]
BY_NAME = {c.name: c for c in ALL_POLICIES}
POLICY_NAMES = tuple(c.name for c in ALL_POLICIES)
assert len(ALL_POLICIES) == 9, "policy count is frozen at 9"
