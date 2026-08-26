# SWEEP A IS QUARANTINED AND INVALIDATED

Not "exploratory". **Invalidated.** Confirmed semantic defects act directly on
deadlines, eviction state and the coverage filter, so its numbers are
**debugging evidence only**. They may not support GO, may not support closure,
and may not be used to predict whether Sweep B will pass.

Explicitly NOT trustworthy: the 449 valid configurations, the 5.2% validity
rate, the per-bin hit rates, and the preliminary gain range of -8.8% to +7.9%.

The final run was killed before writing its JSON. Nothing of it is retained
beyond this notice.

## Confirmed defects

1. **`admit()` incremented `refcount`**, conflating admission with acquisition.
   Changes evictability, drain-state reachability, capacity blocking,
   safe-victim selection, six-bin validity, and therefore policy behaviour.
2. **`L_down,max` was the isolated transfer latency**, but `tick_issue` queues
   after the event it named "issue", so no such bound was justified.
3. **`capacity_block_cycles` is a strict SUBSET of `no_safe_victim_cycles`.**
   Verified in source: the increment sits INSIDE `if not safe:`. The two are not
   independent conditions, which is why they read 47.6% and 47.7%. One bin, not
   two.
4. **`frames_full_cycles` is vacuous.** `by_phys` saturates at `n_frames` for any
   working set at or above the pool and never falls back, so the bin measures
   "warmup finished", not contention. It read 100% on every config.

## What survives

- The original D3/D4 failure on the non-contended workload, preserved separately
  and NOT superseded by anything here.
- The lifecycle counterexample, pending re-verification under the corrected
  event contract.
- The 96-cell denominator definition.
- The nine construction-time defects, which were real bugs.

## Retired

**The 138-passing-test result is retired.** Tests passing against incorrect
semantics prove internal consistency, not correctness.
