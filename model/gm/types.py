"""Corrected golden model. Four-event transaction lifecycle.

Replaces `golden/`, which is quarantined with Sweep A.

Authority: model/SWEEP_B_CONTRACT.md plus the four corrections that followed it.
Nothing here is frozen for execution until the independent oracle and the
mutation suite pass.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from enum import IntEnum


# ---------------------------------------------------------------- transaction

class TxnEvent(IntEnum):
    """FOUR events, not two. DISPATCH is not AXI acceptance.

    DISPATCH           policy selected it; placed in the internal bounded queue
    AXI_ACCEPT         AR/AW handshake. The AXI outstanding count increments HERE
    DDR_SERVICE_START  internal model event, after older transactions
    COMPLETE           RLAST for reads, B-channel handshake for writes

    AXI_ACCEPT and COMPLETE are the hardware-observable boundary events and are
    the ones an ILA can trigger on. DDR_SERVICE_START is internal and is not
    claimed to be observable.
    """
    DISPATCH = 0
    AXI_ACCEPT = 1
    DDR_SERVICE_START = 2
    COMPLETE = 3
    CANCEL = 4
    ERROR = 5


class LifecycleEvent(IntEnum):
    """The six-event page contract. ADMIT does NOT create a logical reference."""
    ACQUIRE = 0      # logical_refcount +1
    ADMIT = 1        # reservation      +1
    ISSUE = 2        # reservation -1, inflight +1
    COMPLETE = 3     # inflight         -1
    RELEASE = 4      # logical_refcount -1
    CANCEL = 5       # reservation      -1   (pre-issue only)


class ObjType(IntEnum):
    KV_PAGE = 0
    EXPERT = 1


class TrafficClass(IntEnum):
    MANDATORY = 0
    SPECULATIVE = 1


class RespStatus(IntEnum):
    OKAY = 0
    SLVERR = 1
    DECERR = 2


class ObjState(IntEnum):
    INVALID = 0
    ALLOCATED_EMPTY = 1
    FILL_IN_FLIGHT = 2
    RESIDENT = 3
    EVICTING = 4


# ----------------------------------------------------- downstream envelope

@dataclass(frozen=True)
class DownstreamEnvelope:
    """DECLARED downstream progress envelope.

    A finite outstanding limit bounds QUEUE LENGTH, not response latency. Every
    field below is required before any finite L_down,max exists, and the whole
    guarantee stays conditional on this envelope holding. AXI itself provides no
    transaction-latency guarantee.
    """
    c_max_cycles: int = 512          # max service time of ANY single transfer
    b_fixed_cycles: int = 32         # fixed arbitration + protocol overhead
    refresh_cycles_per_window: int = 64
    window_cycles: int = 1024
    fifo_non_preemptive: bool = True  # response ordering is defined and FIFO
    max_bypass_transactions: int = 0  # bounded priority bypass; 0 under FIFO

    def l_down_max(self, n_outstanding: int, c_i: int) -> int:
        """Worst-case AXI_ACCEPT -> COMPLETE latency for transaction i.

            w = N_out*B_fixed + (N_out-1)*C_max + C_i + bypass*C_max
            u = window_cycles - refresh_cycles_per_window
            L = w + refresh * ceil(w / u)

        CORRECTED after independent validation REFUTED the previous form, which
        was `B_fixed + (N_out-1)*C_max + C_i + bypass + refresh`. Two defects,
        both "a per-occurrence cost charged once":

        1. B_fixed is paid by EVERY transaction ahead of i, not once. The old
           form understated by (N_out-1)*B_fixed, and this is present even at
           refresh = 0, so it is not a refresh artefact.
        2. refresh was charged once, but the interval spans many windows.
           `window_cycles` was a declared envelope field that this function
           never read. At the default point the span is 1808 cycles against 960
           usable per window, so refresh is owed twice, not once.

        At N_out=4, C_i=144 the old form returned 1776 and an independent
        discrete-event model observed 1936 deterministically. The corrected form
        returns exactly 1936.

        Valid ONLY under FIFO non-preemptive service with bounded bypass.
        """
        if not self.fifo_non_preemptive and self.max_bypass_transactions <= 0:
            raise ValueError(
                "no arbitration progress guarantee: bypass is unbounded, so no "
                "finite L_down_max exists regardless of outstanding depth")
        if c_i > self.c_max_cycles:
            raise ValueError(
                f"internally inconsistent envelope: C_i={c_i} exceeds "
                f"C_max={self.c_max_cycles}. C_max must bound every service time")
        usable = self.window_cycles - self.refresh_cycles_per_window
        if usable <= 0:
            raise ValueError(
                "refresh consumes the entire window: no progress guarantee, so "
                "no finite L_down_max exists")
        work = (n_outstanding * self.b_fixed_cycles
                + (n_outstanding - 1) * self.c_max_cycles
                + c_i
                + self.max_bypass_transactions * self.c_max_cycles)
        windows = -(-work // usable)          # ceil
        return work + self.refresh_cycles_per_window * windows


# ---------------------------------------------------------------- parameters

@dataclass(frozen=True)
class Params:
    n_tenants: int = 3
    n_frames: int = 8
    n_descriptors: int = 16
    n_reserved_mandatory_desc: int = 1
    n_meta_entries: int = 64

    # BOTH depths are frozen. Bounding one and not the other lets the internal
    # queue grow while the AXI counter stays compliant.
    dispatch_queue_depth: int = 8      # internal, post-policy, pre-AXI
    # PRIMARY SWEEP DEPTH, frozen at 2. Under the declared envelope the
    # conditional bound is 240 / 784 / 1392 / 1936 cycles at depths 1/2/3/4,
    # and the tightest declared SLO class is inadmissible from depth 3 upward.
    # Depths {1,3,4} are a SEPARATE pre-registered sensitivity study; the depth
    # is NOT selected after observing performance.
    max_axi_outstanding: int = 2       # AR/AW accepted but not yet completed

    axi_bytes_per_cycle: int = 16
    axi_accept_overhead_cycles: int = 4   # DISPATCH -> AXI_ACCEPT
    axi_fixed_overhead_cycles: int = 8    # AXI_ACCEPT -> DDR_SERVICE_START floor

    dwrr_quantum_bytes: int = 8192
    dwrr_replenish_period: int = 256
    dwrr_max_deficit_bytes: int = 32768

    spec_bucket_burst_bytes: int = 1 << 15
    spec_bucket_refill_per_cycle: int = 4
    speculative_max_wait: int = 4096

    w_generation: int = 8
    w_refcount: int = 8
    w_inflight: int = 6

    @property
    def gen_mod(self) -> int:
        return 1 << self.w_generation


# --------------------------------------------------------------------- objects

@dataclass
class ManagedObject:
    """Counters are NEVER overloaded. See the six-event contract.

    logical_refcount  ACQUIRE / RELEASE
    reservation       ADMIT   / ISSUE or CANCEL
    inflight          ISSUE   / COMPLETE
    fill_pending      FILL_START / FILL_COMPLETE
    """
    key: int
    tenant_id: int
    obj_type: ObjType
    phys_idx: int

    slot: int = -1               # index into the bounded lifecycle RAM
    generation: int = 0
    logical_refcount: int = 0
    reservation: int = 0
    inflight: int = 0
    fill_pending: int = 0
    state: ObjState = ObjState.INVALID

    def draining(self) -> bool:
        """Exactly the definition in the contract."""
        return self.logical_refcount == 0 and self.inflight > 0

    def evictable(self) -> bool:
        """frame_reused -> refcount == 0 && inflight == 0
                        && reservation == 0 && !fill_pending"""
        return (self.logical_refcount == 0 and self.inflight == 0
                and self.reservation == 0 and self.fill_pending == 0)


@dataclass
class Descriptor:
    desc_id: int
    tenant_id: int
    obj_type: ObjType
    obj_key: int
    phys_idx: int
    generation: int
    tclass: TrafficClass
    n_bytes: int
    slo_deadline: int          # A_i + SLO_i, the COMPLETION deadline
    issue_deadline: int        # A_i + SLO_i - L_down,max,i
    arrival: int
    reserved_slot: bool = False
    acquires_ref: bool = False   # a held page: ACQUIRE at admit, RELEASE later
    # RTL-REALIZABLE IDENTITY. A descriptor carries a bounded handle, never a
    # pointer. At ISSUE and COMPLETE the model performs exactly:
    #     entry = lifecycle_ram[lifecycle_slot]
    #     valid = entry.phys_idx   == descriptor.phys_idx
    #          and entry.generation == descriptor.expected_generation
    lifecycle_slot: int = -1
    expected_generation: int = -1
    transaction_tag: int = -1
    obj_ref: object = None       # DEBUG ONLY. Never read by obj_for().

    dispatch_cycle: int = -1
    accept_cycle: int = -1
    service_start_cycle: int = -1
    complete_cycle: int = -1
    cancel_cycle: int = -1
    status: RespStatus = RespStatus.OKAY

    @property
    def dispatched(self) -> bool: return self.dispatch_cycle >= 0
    @property
    def accepted(self) -> bool: return self.accept_cycle >= 0
    @property
    def completed(self) -> bool: return self.complete_cycle >= 0
    @property
    def cancelled(self) -> bool: return self.cancel_cycle >= 0


class SafetyViolation(Exception):
    def __init__(self, kind: str, cycle: int, detail: str):
        self.kind, self.cycle, self.detail = kind, cycle, detail
        super().__init__(f"[{kind}] cycle {cycle}: {detail}")
