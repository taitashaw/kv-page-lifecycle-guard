"""Data plane. FOUR transaction events, two separately bounded queues.

    DISPATCH           policy selected it -> internal bounded dispatch queue
    AXI_ACCEPT         AR/AW handshake    -> AXI outstanding count increments
    DDR_SERVICE_START  internal, after older transactions
    COMPLETE           RLAST / B handshake

Both depths are bounded and both are frozen. Bounding only the AXI counter would
let the internal dispatch queue grow while remaining protocol-compliant, which
would destroy the L_down_max derivation.

The data plane mutates NO page lifecycle state. It reports transactions; the
control plane applies the lifecycle events.
"""
from __future__ import annotations

from .types import Descriptor, Params, RespStatus, TrafficClass


class _Outstanding:
    __slots__ = ("desc", "service_start", "done", "nbytes")

    def __init__(self, desc, service_start, done, nbytes):
        self.desc, self.service_start, self.done, self.nbytes = \
            desc, service_start, done, nbytes


class DataPlane:
    def __init__(self, params: Params, envelope, checks):
        self.p = params
        self.env = envelope
        self.checks = checks

        self.ready_m: list[Descriptor] = []      # admitted, not yet dispatched
        self.ready_s: list[Descriptor] = []
        self.dispatch_q: list[Descriptor] = []   # DISPATCHed, not yet accepted
        self.pending: list[_Outstanding] = []    # ACCEPTed, not yet complete

        self.deficit = [0] * params.n_tenants
        self.spec_tokens = params.spec_bucket_burst_bytes
        self.port_free = 0

        self.n_dispatch = 0
        self.n_accept = 0
        self.n_complete = 0
        self.n_spec_accept = 0
        self.spec_charged = 0
        self._tok_shadow = params.spec_bucket_burst_bytes   # uncapped ledger
        self.overflow_discarded = 0                        # refill lost to the cap
        self.total_bytes = 0
        self.busy_cycles = 0

    # ------------------------------------------------------------- accounting

    def outstanding(self) -> int:
        return len(self.pending)

    def conservation_holds(self) -> bool:
        """n_accepted - n_completed == n_outstanding"""
        return self.n_accept - self.n_complete == self.outstanding()

    def drain_ready(self, phys_idx: int, cycle: int) -> int:
        latest = cycle
        for f in self.pending:
            if f.desc.phys_idx == phys_idx:
                latest = max(latest, f.done)
        # dispatched but not yet accepted ALSO holds the frame. Counting only
        # accepted transfers let earliest_issue precede real quiescence.
        for d in self.dispatch_q:
            if d.phys_idx == phys_idx:
                latest = max(latest, cycle + self.p.axi_accept_overhead_cycles
                             + self.p.axi_fixed_overhead_cycles
                             + self._beats(d.n_bytes))
        return latest

    def _beats(self, nbytes: int) -> int:
        return -(-nbytes // self.p.axi_bytes_per_cycle)

    # ------------------------------------------------------------- replenish

    def replenish(self, cycle: int) -> None:
        if cycle % self.p.dwrr_replenish_period == 0:
            for t in range(self.p.n_tenants):
                self.deficit[t] = min(self.deficit[t] + self.p.dwrr_quantum_bytes,
                                      self.p.dwrr_max_deficit_bytes)
        refill = self.p.spec_bucket_refill_per_cycle
        raw = self.spec_tokens + refill
        capped = min(self.p.spec_bucket_burst_bytes, raw)
        self.overflow_discarded += raw - capped        # refill lost to the ceiling
        self.spec_tokens = capped
        self._tok_shadow += refill                     # uncapped, no clipping

    def enqueue(self, d: Descriptor) -> None:
        (self.ready_m if d.tclass is TrafficClass.MANDATORY
         else self.ready_s).append(d)

    # ---------------------------------------------------------- 4. COMPLETE

    def tick_complete(self, cycle: int) -> list[Descriptor]:
        out, keep = [], []
        for f in self.pending:
            if f.done <= cycle:
                f.desc.complete_cycle = cycle
                f.desc.status = RespStatus.OKAY
                out.append(f.desc)
                self.n_complete += 1
            else:
                keep.append(f)
        self.pending = keep
        return out

    # ------------------------------------------------------- 2/3. AXI_ACCEPT

    def tick_accept(self, cycle: int) -> list[Descriptor]:
        """AR/AW handshake. Outstanding increments HERE, not at dispatch."""
        accepted = []
        while (self.dispatch_q
               and len(self.pending) < self.p.max_axi_outstanding):
            d = self.dispatch_q[0]
            if cycle < d.dispatch_cycle + self.p.axi_accept_overhead_cycles:
                break
            if getattr(d, "earliest_issue", 0) > cycle:
                break
            self.dispatch_q.pop(0)
            d.accept_cycle = cycle
            beats = self._beats(d.n_bytes)
            start = max(cycle + self.p.axi_fixed_overhead_cycles, self.port_free)
            d.service_start_cycle = start
            done = start + beats
            self.port_free = done
            self.pending.append(_Outstanding(d, start, done, d.n_bytes))
            self.n_accept += 1
            if d.tclass is TrafficClass.SPECULATIVE:
                self.spec_tokens -= d.n_bytes      # charged on ACTUAL acceptance
                self.spec_charged += d.n_bytes
                self._tok_shadow -= d.n_bytes
                self.n_spec_accept += 1
            self.deficit[d.tenant_id] -= d.n_bytes
            self.total_bytes += d.n_bytes
            self.busy_cycles += beats
            accepted.append(d)
        return accepted

    # ------------------------------------------------------------ 1. DISPATCH

    def _pick_mandatory(self, cycle: int):
        if not self.ready_m:
            return None
        for d in sorted(self.ready_m,
                        key=lambda x: (x.issue_deadline, x.arrival, x.desc_id)):
            if self.deficit[d.tenant_id] >= d.n_bytes:
                return d
        return None

    def _pick_speculative(self, cycle: int):
        if not self.ready_s or self.ready_m:
            return None
        for d in sorted(self.ready_s, key=lambda x: (x.arrival, x.desc_id)):
            if d.n_bytes > self.spec_tokens:
                continue
            if self.deficit[d.tenant_id] >= d.n_bytes:
                return d
        return None

    def tick_dispatch(self, cycle: int) -> list[Descriptor]:
        if len(self.dispatch_q) >= self.p.dispatch_queue_depth:
            return []
        d = self._pick_mandatory(cycle)
        if d is not None:
            self.ready_m.remove(d)
        else:
            d = self._pick_speculative(cycle)
            if d is None:
                return []
            self.ready_s.remove(d)
        d.dispatch_cycle = cycle
        self.dispatch_q.append(d)
        self.n_dispatch += 1
        return [d]

    # ------------------------------------------------------------- cancel

    def cancel_stale_speculation(self, cycle: int) -> list[Descriptor]:
        """Pre-issue cancellation only. Consumes NO token, because the token is
        charged at AXI acceptance, which has not happened."""
        out, keep = [], []
        for d in self.ready_s:
            if cycle - d.arrival > self.p.speculative_max_wait:
                out.append(d)
            else:
                keep.append(d)
        self.ready_s = keep
        keep2 = []
        for d in self.dispatch_q:
            if (d.tclass is TrafficClass.SPECULATIVE
                    and cycle - d.arrival > self.p.speculative_max_wait):
                out.append(d)
            else:
                keep2.append(d)
        self.dispatch_q = keep2
        return out

    def token_accounting(self, all_desc) -> tuple[bool, str]:
        """Tokens are charged at AXI acceptance and NEVER refunded. So the
        running charge must equal the bytes of every accepted speculative
        descriptor. A refund shows up as a shortfall."""
        expect = sum(d.n_bytes for d in all_desc
                     if d.accepted and d.tclass is TrafficClass.SPECULATIVE)
        if self.spec_charged != expect:
            return False, f"spec_charged {self.spec_charged} != accepted spec bytes {expect}"
        # tokens = shadow - overflow_discarded, exactly. Any other value means
        # the counter moved outside replenish/accept, i.e. a refund.
        expect_tokens = self._tok_shadow - self.overflow_discarded
        if self.spec_tokens != expect_tokens:
            return False, (f"spec_tokens {self.spec_tokens} != shadow {self._tok_shadow} "
                           f"- discarded {self.overflow_discarded} = {expect_tokens}: "
                           f"tokens moved outside replenish/accept")
        return True, ""

    def accept_path_integrity(self, all_desc) -> tuple[bool, str]:
        """accept_cycle may be set ONLY by tick_accept, so the number of
        descriptors carrying one must equal n_accept. This is what catches
        DISPATCH being treated as acceptance."""
        n = sum(1 for d in all_desc if d.accepted)
        if n != self.n_accept:
            return False, f"{n} descriptors have accept_cycle but n_accept={self.n_accept}"
        return True, ""

    def snapshot(self) -> dict:
        return {"ready_m": len(self.ready_m), "ready_s": len(self.ready_s),
                "dispatch_q": len(self.dispatch_q),
                "outstanding": self.outstanding(),
                "n_dispatch": self.n_dispatch, "n_accept": self.n_accept,
                "n_complete": self.n_complete,
                "conservation": self.conservation_holds()}
