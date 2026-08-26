"""Control plane. SOLE mutator of page lifecycle, capacity and descriptors.

Implements the six-event contract exactly:

    event                logical_refcount  reservation  inflight
    ACQUIRE                     +1              0           0
    ADMIT                        0             +1           0
    ISSUE                        0             -1          +1
    COMPLETE                     0              0          -1
    RELEASE                     -1              0           0
    CANCEL before issue          0             -1           0

ADMIT DOES NOT CREATE A LOGICAL REFERENCE. Conflating the two is what
invalidated Sweep A.
"""
from __future__ import annotations

from .types import (
    Descriptor, ManagedObject, ObjState, ObjType, Params, SafetyViolation,
    TrafficClass,
)


class ControlPlane:
    def __init__(self, params: Params, checks, cov):
        self.p = params
        self.checks = checks
        self.cov = cov

        self.objects: dict[tuple, ManagedObject] = {}
        self.by_phys: dict[int, ManagedObject] = {}
        self.free_frames: list[int] = list(range(params.n_frames))
        self.free_desc: list[int] = list(range(params.n_descriptors))
        # BOUNDED lifecycle RAM. In RTL this is a real memory indexed by slot;
        # here the entry is the ManagedObject, but obj_for() may only read
        # phys_idx and generation from it, exactly as the hardware would.
        self.lifecycle_ram: list = [None] * params.n_meta_entries
        self.free_slots: list[int] = list(range(params.n_meta_entries))
        self.desc_table: dict[int, Descriptor] = {}     # live only
        self.all_desc: list[Descriptor] = []            # every descriptor, stats
        self.reserved_desc_free = params.n_reserved_mandatory_desc
        self.dp = None

        self.n_admitted = 0
        self.n_rejected = 0
        self.n_acquire = 0
        self.n_release = 0
        self.n_stale_release = 0
        self.n_cancel = 0
        self.n_admit_ev = 0
        self.n_issue_ev = 0
        self.n_complete_ev = 0

    # ------------------------------------------------------------- accessors

    def okey(self, t, ot, k): return (t, ot, k)

    def lookup(self, t, ot, k):
        return self.objects.get(self.okey(t, ot, k))

    def evictable_frames(self) -> int:
        return sum(1 for o in self.by_phys.values() if o.evictable())

    # ------------------------------------------------- LIFECYCLE EVENTS, exact

    def ev_acquire(self, o: ManagedObject) -> None:
        o.logical_refcount += 1
        self.n_acquire += 1

    def ev_admit(self, o: ManagedObject) -> None:
        o.reservation += 1
        self.n_admit_ev += 1

    def ev_issue(self, o: ManagedObject, cycle: int) -> None:
        if o.reservation <= 0:
            raise SafetyViolation("underflow", cycle,
                                  f"ISSUE with reservation=0 on phys {o.phys_idx}")
        o.reservation -= 1
        o.inflight += 1
        self.n_issue_ev += 1

    def ev_complete(self, o: ManagedObject, cycle: int) -> None:
        if o.inflight <= 0:
            raise SafetyViolation("underflow", cycle,
                                  f"COMPLETE with inflight=0 on phys {o.phys_idx}")
        o.inflight -= 1
        self.n_complete_ev += 1
        if o.fill_pending > 0:
            o.fill_pending -= 1
            if o.fill_pending == 0 and o.state is ObjState.FILL_IN_FLIGHT:
                o.state = ObjState.RESIDENT

    def ev_release(self, o: ManagedObject, cycle: int) -> None:
        if o.logical_refcount <= 0:
            raise SafetyViolation("underflow", cycle,
                                  f"RELEASE with refcount=0 on phys {o.phys_idx}")
        o.logical_refcount -= 1
        self.n_release += 1

    def ev_cancel(self, o: ManagedObject, cycle: int) -> None:
        if o.reservation <= 0:
            raise SafetyViolation("underflow", cycle,
                                  f"CANCEL with reservation=0 on phys {o.phys_idx}")
        o.reservation -= 1
        self.n_cancel += 1

    def event_accounting(self) -> tuple[bool, str]:
        """Three global conservation laws over the six-event contract.

        A counter changed without emitting its event breaks one of these. That
        is how the ADMIT-increments-refcount and COMPLETE-decrements-refcount
        mutants evade any purely local assertion.
        """
        live = list(self.by_phys.values()) + list(getattr(self, "pending_swap", {}).values())
        rc = sum(o.logical_refcount for o in live)
        rv = sum(o.reservation for o in live)
        inf = sum(o.inflight for o in live)
        if rc != self.n_acquire - self.n_release:
            return False, f"sum(refcount)={rc} != acquire {self.n_acquire} - release {self.n_release}"
        if rv != self.n_admit_ev - self.n_issue_ev - self.n_cancel:
            return False, (f"sum(reservation)={rv} != admit {self.n_admit_ev} "
                           f"- issue {self.n_issue_ev} - cancel {self.n_cancel}")
        if inf != self.n_issue_ev - self.n_complete_ev:
            return False, f"sum(inflight)={inf} != issue {self.n_issue_ev} - complete {self.n_complete_ev}"
        return True, ""

    # -------------------------------------------------------------- allocation

    def _reclaim(self, cycle: int) -> int | None:
        for phys, o in list(self.by_phys.items()):
            if o.state is ObjState.INVALID or not o.evictable():
                continue
            self.checks.check_frame_reuse(o, cycle)
            k = self.okey(o.tenant_id, o.obj_type, o.key)
            if self.objects.get(k) is o:      # may already be unpublished at EVICTING
                del self.objects[k]
            self._free_slot(o)
            del self.by_phys[phys]
            succ = getattr(self, "pending_swap", {}).pop(phys, None)
            if succ is not None:
                self.by_phys[phys] = succ     # publish rather than strand it
            return phys
        return None

    def drain_candidate(self, cycle: int):
        """A DRAINING frame: logical_refcount == 0 AND inflight > 0.

        It will become reusable; it is not reusable now. Exactly the state a
        lifecycle-blind capacity test misreads as free.
        """
        best = None
        for phys, o in self.by_phys.items():
            if o.state in (ObjState.INVALID, ObjState.EVICTING):
                continue
            if not o.draining():
                continue
            ready = self.dp.drain_ready(phys, cycle) if self.dp else cycle
            if best is None or ready < best[1]:
                best = (phys, ready)
        return best

    def _alloc_frame(self, cycle: int):
        if self.free_frames:
            return self.free_frames.pop(0), cycle
        phys = self._reclaim(cycle)
        if phys is not None:
            return phys, cycle
        cand = self.drain_candidate(cycle)
        if cand is None:
            return None
        phys, ready = cand
        inc = self.by_phys[phys]
        inc.state = ObjState.EVICTING
        # unpublish it NOW: the frame is promised to a successor, so a later
        # fetch must not hit it and re-admit against a doomed object.
        k = self.okey(inc.tenant_id, inc.obj_type, inc.key)
        if self.objects.get(k) is inc:
            del self.objects[k]
        return phys, ready

    def _free_slot(self, o) -> None:
        if o.slot >= 0 and self.lifecycle_ram[o.slot] is o:
            self.lifecycle_ram[o.slot] = None
            self.free_slots.append(o.slot)
            o.slot = -1

    def _alloc_desc(self, tclass: TrafficClass):
        n = len(self.free_desc)
        if tclass is TrafficClass.SPECULATIVE:
            if n <= self.reserved_desc_free:
                return None, False
            return self.free_desc.pop(0), False
        if not self.free_desc:
            return None, False
        return self.free_desc.pop(0), n <= self.reserved_desc_free

    # --------------------------------------------------------------- admission

    def admit(self, req, cycle: int, policy_ok: bool, l_down_max: int):
        if not policy_ok:
            self.n_rejected += 1
            self.cov.lifecycle_deferral_events += 1
            return None

        o = self.lookup(req.tenant_id, req.obj_type, req.key)
        need_frame = o is None
        earliest = cycle

        desc_id, used_reserved = self._alloc_desc(req.tclass)
        if desc_id is None:
            self.n_rejected += 1
            return None

        if need_frame:
            slack = req.deadline - cycle
            alloc = self._alloc_frame(cycle)
            self.cov.on_alloc_request(self, alloc is None, slack)
            if alloc is None:
                self.free_desc.insert(0, desc_id)
                self.n_rejected += 1
                return None
            phys, earliest = alloc
            if earliest > cycle:
                self.cov.miss_waited_for_retire += 1
            incumbent = self.by_phys.get(phys)
            gen = 0
            if incumbent is not None and incumbent.state is ObjState.EVICTING:
                gen = (incumbent.generation + 1) % self.p.gen_mod
                self.pending_swap = getattr(self, "pending_swap", {})
            if not self.free_slots:
                self.free_frames.insert(0, phys) if phys in () else None
                self.free_desc.insert(0, desc_id)
                self.n_rejected += 1
                return None
            slot = self.free_slots.pop(0)
            o = ManagedObject(key=req.key, tenant_id=req.tenant_id,
                              obj_type=req.obj_type, phys_idx=phys,
                              generation=gen, state=ObjState.ALLOCATED_EMPTY,
                              slot=slot)
            self.lifecycle_ram[slot] = o
            self.objects[self.okey(req.tenant_id, req.obj_type, req.key)] = o
            o.fill_pending += 1                       # FILL_START
            if incumbent is not None and incumbent.state is ObjState.EVICTING:
                self.pending_swap[phys] = o
            else:
                self.by_phys[phys] = o

        # ADMIT: reservation only. NO logical reference.
        self.ev_admit(o)
        if getattr(req, "held", False):
            self.ev_acquire(o)                        # ACQUIRE, separate event

        d = Descriptor(
            desc_id=desc_id, tenant_id=req.tenant_id, obj_type=req.obj_type,
            obj_key=req.key, phys_idx=o.phys_idx, generation=o.generation,
            tclass=req.tclass, n_bytes=req.n_bytes,
            slo_deadline=req.deadline,
            issue_deadline=req.deadline - l_down_max,
            arrival=req.arrival, reserved_slot=used_reserved,
            acquires_ref=getattr(req, "held", False),
        )
        d.earliest_issue = earliest
        d.lifecycle_slot = o.slot
        d.expected_generation = o.generation
        d.transaction_tag = desc_id
        d.obj_ref = o                      # debug only; obj_for never reads it
        self.desc_table[desc_id] = d
        self.all_desc.append(d)
        self.n_admitted += 1
        return d

    def release_ref(self, tenant_id, obj_type, key, cycle: int) -> bool:
        o = self.lookup(tenant_id, obj_type, key)
        if o is None or o.logical_refcount == 0:
            self.n_stale_release += 1
            return False
        self.ev_release(o, cycle)
        return True

    # ----------------------------------------------- transaction feedback

    def obj_for(self, d: Descriptor):
        """The object this descriptor was ADMITTED against.

        Neither `by_phys` nor `objects` is a sound index here. by_phys is not
        authoritative while a swap is pending, `objects` loses the incumbent the
        moment it is marked EVICTING, and (phys_idx, generation) is not unique
        across objects, which produced an `ISSUE with reservation=0` when the
        lookup resolved to a different object that happened to share a
        generation.

        The descriptor carries a direct reference, which mirrors the hardware:
        the lifecycle RAM is indexed by phys_idx and the generation field is
        what detects staleness. A generation mismatch means the frame was
        rebound underneath this descriptor, so the transaction is stale and must
        not mutate current state.
        """
        slot = d.lifecycle_slot
        if slot < 0 or slot >= len(self.lifecycle_ram):
            return None
        entry = self.lifecycle_ram[slot]
        if entry is None:
            return None
        # the ONLY two fields the hardware compares
        if entry.phys_idx != d.phys_idx:
            return None
        if entry.generation != d.expected_generation:
            return None
        return entry

    def on_axi_accept(self, d: Descriptor, cycle: int) -> None:
        o = self.obj_for(d)
        if o is None:
            return
        self.checks.check_tenant(d, o, cycle)
        self.ev_issue(o, cycle)
        if o.state is ObjState.ALLOCATED_EMPTY:
            o.state = ObjState.FILL_IN_FLIGHT

    def on_complete(self, d: Descriptor, cycle: int) -> None:
        o = self.obj_for(d)
        if o is not None:
            self.checks.check_tenant(d, o, cycle)
            self.ev_complete(o, cycle)
        self._retire(d, cycle)
        # the swap is finished against the INCUMBENT holding the frame, which
        # may not be the object this descriptor belonged to
        incumbent = self.by_phys.get(d.phys_idx)
        if incumbent is not None:
            self._finish_swap(incumbent, cycle)

    def on_cancel_pre_issue(self, d: Descriptor, cycle: int) -> None:
        if d.accepted:
            raise SafetyViolation("cancel_after_accept", cycle,
                                  f"desc {d.desc_id} cancelled after AXI accept")
        o = self.obj_for(d)
        if o is not None:
            self.ev_cancel(o, cycle)
            if o.fill_pending > 0:
                o.fill_pending -= 1
        d.cancel_cycle = cycle
        self._free_desc(d)

    def _retire(self, d: Descriptor, cycle: int) -> None:
        self._free_desc(d)

    def _free_desc(self, d: Descriptor) -> None:
        if self.desc_table.get(d.desc_id) is d:
            del self.desc_table[d.desc_id]
        self.free_desc.append(d.desc_id)

    def _finish_swap(self, o: ManagedObject, cycle: int) -> None:
        swaps = getattr(self, "pending_swap", None)
        if not swaps:
            return
        succ = swaps.get(o.phys_idx)
        if succ is None or o.state is not ObjState.EVICTING or not o.evictable():
            return
        self.checks.check_frame_reuse(o, cycle)
        k = self.okey(o.tenant_id, o.obj_type, o.key)
        if self.objects.get(k) is o:
            del self.objects[k]      # already unpublished at EVICTING; belt and braces
        self._free_slot(o)
        self.by_phys[o.phys_idx] = succ
        del swaps[o.phys_idx]
