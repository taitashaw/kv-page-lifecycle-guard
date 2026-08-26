# Sweep B contract. Frozen before any implementation.

Supersedes `SWEEP_B_BLOCKING_CORRECTIONS.md`, which is folded in. Sweep A is
quarantined and invalidated.

---

## 1. The event/state contract, replacing the current model

**Admission does NOT create a logical reference.** That single conflation is
what forced two earlier corrections to held-reference semantics and it
invalidated Sweep A's lifecycle results.

| event | logical_refcount | reservation | inflight |
|---|---:|---:|---:|
| ACQUIRE | +1 | 0 | 0 |
| ADMIT | 0 | +1 | 0 |
| ISSUE | 0 | -1 | +1 |
| COMPLETE | 0 | 0 | -1 |
| RELEASE | -1 | 0 | 0 |
| CANCEL before issue | 0 | -1 | 0 |

A **draining** page is exactly `logical_refcount == 0 AND inflight > 0`.

`fill_pending` is a separate counter incremented by FILL_START and decremented
by FILL_COMPLETE. Eviction requires ownership, inflight, reservation and fill
state to all permit release.

Speculative tokens: charge on **actual AXI acceptance**, not at selection.
Pre-issue cancellation consumes no token. Post-issue cancellation gets no
refund. The descriptor is not returned until outstanding activity retires.

## 2. DISPATCH and AXI_ISSUE are separate events. Architecture frozen: MULTIPLE OUTSTANDING.

The current `start = max(cycle + overhead, port_free)` means the event named
"issue" is really enqueue. Two events, named and separated:

    DISPATCH / ENQUEUE   at `cycle`
    AXI_ISSUE / SERVICE_START at `start`

**Chosen: multiple outstanding transfers**, matching the `max_axi_outstanding`
parameter already in the design. Consequences that are now binding:

- `L_down,max` MUST include bounded downstream queue, arbitration and service
  latency. It is NOT the isolated transfer latency.
- **The downstream queue must be BOUNDED, or no finite `L_down,max` exists.**
  The bound is `max_axi_outstanding`, and `L_down,max` is derived from it:
  `L_down,max = max_axi_outstanding * max_service_time + arbitration_bound`.
- Feasibility compares the **predicted physical issue time** against
  `D_issue,i = A_i + SLO_i - L_down,max,i`.
- Predecessors' service times still contribute to the predicted issue time.
  Only request i's own downstream latency is excluded, and only once.

## 3. Coverage bins are ANNOTATIONS, never eligibility filters

Sweep B splits into two suites that are never mixed:

**Targeted correctness suite.** A common forced prefix drives every policy into
an identical state, then the lifecycle/capacity/deadline intersection is
reproduced. This proves or falsifies the counterexample. Small, deterministic,
auditable.

**Distributional performance suite.** The complete frozen grid, **no bin-based
row exclusion at all**. Coverage bins are recorded as annotations for
stratification only. Even a policy-neutral oracle can encode the candidate
mechanism, so nothing decides eligibility.

Two bins are rebuilt because Sweep A's were defective:

- `capacity_block` and `no_safe_victim` must be **independent conditions**, with
  a test exhibiting each without the other.
- `frames_full` is replaced. Saturated occupancy measures warmup, not
  contention. Replacement measures time spent with **zero reclaimable frames
  while demand exists**.

## 4. Comparators

| policy | role |
|---|---|
| `independent_dual_guard` | **negative control**, intentionally lifecycle-blind. Not a performance comparator |
| `independent_safe_guard` | **the real comparator**. Identical metadata, identical eviction invariants, identical allocator. Differs ONLY by deciding deadline and capacity independently instead of by joint forecast |
| `tuned_axi_qos` | the baseline most likely to kill the project |

## 5. Fixed measurement horizon

All policies are measured over the **same** horizon. A policy that rejects more
work and drains earlier must not be able to show inflated utilisation or
throughput.

## 6. Run hygiene, after three orphaned copies raced on one output path

- unique run ID and its own output directory
- a lock enforcing exactly one active process
- record PID, source hash, config hash and seed list
- each completed run written as an independent checkpoint
- final JSON written to a temp file and **atomically renamed**
- console summary printed only AFTER the authoritative result is safely written
- **never pipe the producer into `head`**

## 7. Statistical protocol

- Sweep B is confirmatory only for the region it does not itself select.
- If no qualifying region: close the C+D **performance** branch, retaining the
  lifecycle counterexample as a verified correctness artifact.
- If a qualifying region: freeze it, validate on **at least 20 fresh unused
  seeds**, require a **paired confidence interval on the improvement excluding
  zero**, and permit **no further parameter changes**.

## 8. Before Sweep B runs

1. implement the corrected event/state model
2. re-run the regression suite, which is retired until then
3. **add mutation tests**, because the previous 138 passes demonstrated internal
   consistency against wrong semantics
4. re-verify the lifecycle counterexample under the corrected contract
5. only then freeze and run
