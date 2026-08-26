"""Coverage instrumentation. ANNOTATIONS ONLY, never eligibility filters.

Two bins from the quarantined model were defective and are replaced here:

- `capacity_block_cycles` was NESTED inside `no_safe_victim_cycles`, so the two
  could not serve as independent coverage dimensions. The narrower counter is
  retained as a SEVERITY measure and explicitly labelled as nested.
- `frames_full_cycles` was persistent, so it recorded warmup rather than
  contention and read 100% on every config. Replaced with an EVENT-SENSITIVE
  measurement plus a separate occupancy high-water mark that is reported but is
  not treated as contention.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class Coverage:
    # ---- event-sensitive contention, replacing persistent frames_full
    #: allocation_requested && free_frames == 0 && evictable_frames == 0
    alloc_blocked_no_evictable: int = 0
    #: reported, NOT treated as contention
    occupancy_high_water: int = 0

    # ---- nested severity measure, explicitly labelled
    #: cycles with no safe victim available (the OUTER condition)
    no_safe_victim_cycles: int = 0
    #: NESTED inside the above: no safe victim AND demand waiting.
    #: Severity, not an independent dimension.
    no_safe_victim_with_demand_cycles: int = 0

    # ---- orthogonal dimensions
    #: how deep the draining state ever got. Independent of victim availability.
    draining_frames_max: int = 0
    #: allocations attempted while the evictable set was empty
    alloc_requests_while_evictable_zero: int = 0
    #: admissions deferred specifically because of lifecycle state
    lifecycle_deferral_events: int = 0
    #: deadline slack observed at the moment allocation was blocked
    slack_when_blocked: list = field(default_factory=list)

    # ---- mechanism reachability
    #: feasible ignoring lifecycle, infeasible once lifecycle is included
    feasible_until_lifecycle: int = 0
    #: a miss that had to wait for a reference or in-flight transfer to retire
    miss_waited_for_retire: int = 0

    def sample(self, cp, dp, cycle: int) -> None:
        occupied = len(cp.by_phys)
        self.occupancy_high_water = max(self.occupancy_high_water, occupied)

        evictable = sum(1 for o in cp.by_phys.values() if o.evictable())
        draining = sum(1 for o in cp.by_phys.values() if o.draining())
        self.draining_frames_max = max(self.draining_frames_max, draining)

        if not cp.free_frames and evictable == 0:
            self.no_safe_victim_cycles += 1
            if dp.dispatch_q or dp.pending:
                self.no_safe_victim_with_demand_cycles += 1

    def on_alloc_request(self, cp, blocked: bool, slack: int | None) -> None:
        """Called at the MOMENT an allocation is requested, not every cycle."""
        evictable = sum(1 for o in cp.by_phys.values() if o.evictable())
        if evictable == 0:
            self.alloc_requests_while_evictable_zero += 1
        if blocked and not cp.free_frames and evictable == 0:
            self.alloc_blocked_no_evictable += 1
            if slack is not None:
                self.slack_when_blocked.append(slack)

    def as_dict(self) -> dict:
        d = {k: v for k, v in self.__dict__.items() if k != "slack_when_blocked"}
        s = sorted(self.slack_when_blocked)
        d["slack_when_blocked_n"] = len(s)
        d["slack_when_blocked_median"] = s[len(s) // 2] if s else None
        d["slack_when_blocked_min"] = s[0] if s else None
        return d


#: Recorded for stratification ONLY. Nothing here decides which rows are kept.
ANNOTATION_KEYS = (
    "alloc_blocked_no_evictable",
    "draining_frames_max",
    "alloc_requests_while_evictable_zero",
    "lifecycle_deferral_events",
    "feasible_until_lifecycle",
    "miss_waited_for_retire",
    "no_safe_victim_cycles",
)

#: NESTED, kept only as a severity measure. Never paired with its parent as an
#: independent dimension.
NESTED_SEVERITY_KEYS = ("no_safe_victim_with_demand_cycles",)

#: Reported but explicitly NOT contention.
NON_CONTENTION_KEYS = ("occupancy_high_water",)
