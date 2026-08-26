# Corrected model (`gm/`) status

Replaces `golden/`, quarantined with Sweep A. **Requirements contract is frozen.
The implementation and execution manifest are NOT frozen** until this file
records a clean gate, which it now does for the test gate only.

## Gate result: CRITICAL-MUTANT GATE passed. 9 of 9 named mutants killed.

**This proves coverage of those nine faults, not general model correctness.**
90 assertions across two suites, 0 failing: 62 in the mutation suite, 28 in the
transaction-oracle and counterexample suite.

**Five of nine survived the first pass.** The suite was giving false assurance
until it was strengthened, which is the same failure mode that let Sweep A run
on wrong semantics. Recorded because a suite that cannot kill an injected defect
is worse than no suite.

| mutation | first pass | now | what kills it |
|---|---|---|---|
| ADMIT increments logical_refcount | SURVIVED | killed | event-accounting law |
| COMPLETE decrements refcount not inflight | SURVIVED | killed | event-accounting law |
| draining frame treated as evictable | killed | killed | frame-reuse assertion |
| outstanding limit exceeded by one | killed | killed | bounds check |
| DISPATCH treated as AXI acceptance | SURVIVED | killed | accept-path integrity |
| completes before acceptance | killed | killed | order check |
| indefinite priority bypass | killed | killed | `l_down_max` refuses a bound |
| speculative token refunded | SURVIVED | killed | directed unit test |
| deadline `<=` changed to `<` | SURVIVED | killed | directed boundary test |

Two mutants needed **directed unit tests** rather than workload tests, and the
reason is a real constraint, not laziness. For the token refund: a bucket large
enough for speculation to be admitted keeps tokens at the burst ceiling where a
refund is absorbed by the cap, while a bucket small enough for a refund to show
gets speculation rejected at admission so it is never cancelled. The two
requirements are mutually exclusive in one configuration.

The refund mutant also initially **never executed at all**: 72 speculative
requests were offered and all were rejected at admission, so nothing reached the
queue to time out. A mutation that never runs cannot be killed, and the suite
did not notice. There is now an explicit assertion that cancellations occur.

## Three conservation laws, checked every cycle

    sum(logical_refcount) == n_acquire - n_release
    sum(reservation)      == n_admit - n_issue - n_cancel
    sum(inflight)         == n_issue - n_complete

Plus `n_accepted - n_completed == n_outstanding`, token accounting against
accepted speculative bytes with a non-saturating shadow, and accept-path
integrity (`accept_cycle` may be set only by `tick_accept`).

## Independent oracle

40 reachable `(refcount, reservation, inflight, fill)` states enumerated
directly from the contract table, not by calling the model. The model agrees on
**every** state for both `evictable()` and `draining()`.

## L_down,max is derived, and refuses to exist without a progress guarantee

    L_down,max,i <= B_fixed + (N_out - 1) * C_max + C_i + bypass + refresh

`DownstreamEnvelope.l_down_max()` raises rather than returning a number when
`fifo_non_preemptive` is false and bypass is unbounded. A finite outstanding
limit bounds queue length, not latency. At `N_out=4, C_i=144` it returns 1776
cycles, against the 144 that Sweep A wrongly used.

## Frozen counts

Eight policies, asserted at import:

| policy | role |
|---|---|
| tuned_axi_qos | primary baseline |
| independent_dual_guard | **negative control**, lifecycle-blind by design |
| independent_safe_guard | **the fair comparator** |
| integrated | candidate |
| fifo, edf_only, credit_only, lifecycle_edf | comparators |

**8,640 configs x 8 policies = 69,120 records** for the distributional suite,
plus separate targeted-correctness runs.

## Coverage, rebuilt

- `no_safe_victim_with_demand_cycles` is explicitly labelled **NESTED** inside
  `no_safe_victim_cycles` and kept only as a severity measure. The two are never
  paired as independent dimensions.
- `frames_full_cycles` is gone. Replaced by the event-sensitive
  `alloc_blocked_no_evictable` plus `occupancy_high_water`, which is reported and
  explicitly **not** treated as contention.
- New orthogonal dimensions: `draining_frames_max`,
  `alloc_requests_while_evictable_zero`, `lifecycle_deferral_events`, and the
  distribution of deadline slack when allocation is blocked.
- All of these are **annotations for stratification. None is an eligibility
  filter.**

## Speculative tokens: OPTION A, confirmed by construction

`control_plane.py` contains no reference to `spec_tokens` at all, so admission
cannot reserve or move them.

    ADMIT           no token change
    AXI_ACCEPT      tokens -= bytes
    CANCEL queued   no token change
    CANCEL issued   impossible; asserted as `cancel_after_accept`

The earlier wording implied the model refunded tokens on a queued timeout. It
does not. **The refund existed only inside the injected mutant**, which is what
the directed test now kills.

Shadow arithmetic corrected to separate the ledger from the physical counter:

    shadow_{t+1}  = shadow_t + refill - charge          (uncapped)
    tokens_{t+1}  = min(B, tokens_t + refill) - charge  (capped)
    overflow_discarded += raw - capped

and the invariant is `tokens == shadow - overflow_discarded` exactly. Without
the discard term the two are not expected to match once the bucket saturates,
which is why a refund was invisible at the ceiling.

## L_down,max ledger, fully reconstructable

At `N_out = 4`, `C_i = 144`:

| component | value | derivation |
|---|---:|---|
| `B_fixed` | 32 | fixed arbitration + protocol |
| `(N_out - 1) x C_max` | 1536 | 3 x 512 |
| `C_i` | 144 | this transfer |
| `B_bypass_cycles` | 0 | 0 transactions x 512 |
| refresh / backpressure | 64 | per window |
| **total** | **1776** | function returns 1776 |

`bypass` is a TRANSACTION COUNT multiplied by `C_max`, not raw cycles. The
function raises rather than returning a number when bypass is unbounded and
service is not FIFO non-preemptive.

**On the ZCU104 this remains a CONDITIONAL service-envelope guarantee.**
Simulation and ILA can detect violations and measure observed maxima. Neither
can prove the PS DDR controller's universal worst-case response time.

## Independent oracles: predicate AND transaction

The predicate oracle (40 states) validates only `evictable()` and `draining()`.
A separate **transaction oracle** now exhaustively explores the 8^5 five-event
sequence space over two objects, two frames and two tags, rejecting illegal
transitions and enforcing:

    COMPLETE(tag)   -> previously AXI_ACCEPT(tag)
    AXI_ACCEPT(tag) at most once
    COMPLETE(tag)   at most once
    frame_reuse     -> no outstanding tag references the old generation

Global transaction conservation alone can miss completing the WRONG tag; the
per-tag properties are what close that.

## Counterexample RE-VERIFIED under the corrected contract

`tests/test_gm_counterexample.py`, 28 assertions, 0 failing.

The draining state is reached as `logical_refcount == 0 AND inflight > 0`, and
`d_issue = d_SLO - L_down,max = 3 - 2 = 1` reconstructs from the ledger.

| policy | role | admitted | on time |
|---|---|---:|---:|
| edf_only, credit_only, fifo, tuned_axi_qos | comparators | 2 | 1 |
| lifecycle_edf | comparator | 2 | 1 |
| independent_dual_guard | negative control | 2 | 1 |
| **independent_safe_guard** | **fair comparator** | **2** | **1** |
| **integrated** | candidate | **1** | **1** |

**The result that matters: the FAIR comparator fails too.** A policy with
identical metadata, identical eviction invariants and identical allocator, safe
in every respect, still admits work it cannot serve because it evaluates
deadline and capacity INDEPENDENTLY. Only the joint forecast rejects. If
`independent_safe_guard` had admitted 1 it would have been secretly doing the
joint forecast and would not be a fair comparator; the test asserts this
explicitly.

No policy commits an unsafe frame reuse or breaks transaction conservation.

## Coverage wording, corrected

`no_safe_victim_with_demand_cycles` being a strict SUBSET does not make it the
same condition as its parent. It makes it **unsuitable as an independent
coverage axis while remaining useful as a nested severity counter**, which is
how it is now labelled and used.

## Fixed horizon, verified

`sim.run` loops `range(horizon)` unconditionally with no policy-specific drain
extension. Measured identical (12000) across all eight policies. Warmup, arrival
and observation intervals are shared because the trace and the horizon are both
inputs, not derived from policy behaviour.

## Still open before Sweep B may be frozen

1. build the targeted correctness suite with a common forced prefix, and freeze
   its OWN expected record count separately from the distributional 69,120
2. build the distributional suite with no bin-based row exclusion
3. run hygiene: unique run id, lock, per-run checkpoints, atomic rename,
   console output only after the authoritative write, never pipe into `head`
4. **validate the `L_down,max` derivation against measured behaviour**, since
   the analytic bound is currently asserted rather than empirically corroborated

Four items, and the fourth is the one previously missing from the count.
