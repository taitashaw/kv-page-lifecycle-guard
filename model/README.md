# Golden model: two-tenant C+D falsifier

Reference implementation for the design frozen in
`docs/architecture/DECISION_004_two_tenant_falsifier.md`. The RTL must match
this cycle ordering and these invariants. A divergence between this model, XSim
and the ZCU104 is a finding, not noise.

**Everything this model produces is SYNTHETIC.** No AXI, DDR, ZCU104 or ILA
measurement is behind any number here.

## Run it

```bash
python3 tests/test_golden.py     # 138 assertions
python3 run_golden.py            # baseline table, load sweep, D4 gate
```

## Structure

| file | role |
|---|---|
| `golden/types.py` | frozen parameters, the 9-field Event, lifecycle state, reclaim predicate |
| `golden/control_plane.py` | SOLE mutator of capacity, descriptors, lifecycle |
| `golden/data_plane.py` | arbitration and issue. Emits Events, mutates nothing |
| `golden/policies.py` | the integrated predicate and five baselines |
| `golden/checks.py` | the D1 hard kills as executable assertions |
| `golden/sim.py` | the fixed cycle order the RTL must reproduce |
| `golden/traces.py` | deterministic traces, load-targeted |

Cycle order, fixed:

1. data plane retires finished transfers, emits COMPLETION
2. control plane consumes events: lifecycle, descriptor retire, capacity release
3. stale speculation is CANCELLED
4. service credit and the speculative budget replenish **by time**
5. control plane admits arrivals
6. data plane arbitrates and issues, emits ISSUE
7. D1 checks run

## THE HEADLINE RESULT: the D4 primary gate FAILS at every load

D4 requires the integrated predicate to improve on-time completions per
**offered** request by at least 10 percent over tuned AXI QoS while retaining at
least 90 percent of its completed throughput.

| load | tuned AXI QoS | integrated | relative | throughput | D4 |
|---:|---:|---:|---:|---:|---|
| 0.70 | 100.00% | 100.00% | +0.0% | 100% | **FAIL** |
| 0.80 | 99.58% | 99.58% | +0.0% | 100% | **FAIL** |
| 0.90 | 96.67% | 96.67% | +0.0% | 100% | **FAIL** |
| 0.95 | 92.92% | 92.92% | +0.0% | 100% | **FAIL** |

On the constructed counterexample the integrated predicate does the right thing,
correctly rejecting a request no legal execution can serve, but that costs
throughput and it fails D4 there too (50% retained).

This is the registered D3 kill firing: *"no tested operating region improves
offered-load SLO goodput"*. It is reported, not softened.

**The one honest caveat, which is an observation and not an excuse:** on these
traces frame capacity is never contended (64 frames, or 8 frames against 40
keys), so the three-ledger predicate reduces to the deadline test and cannot
differ from no admission control. The predicate only bites where capacity
pressure and tight deadlines coincide. Either a trace in that region is
constructed and the advantage appears, or the D3 kill stands and the branch
closes. Constructing that trace is legitimate; moving the gate is not.

## Defects this model found in its own design

Each was a real bug caught before RTL, which is the point of building the model
first.

1. **Service credit was nearly replenished on completion.** It is charged on
   issue and replenished by time. Replenishing on completion double-credits the
   token bucket. Test: `t_credit_time_based_not_completion`, which also greps
   `tick_completions` to prove it never touches `deficit`.
2. **DDR utilisation exceeded 100 percent** because overlapping transfer
   durations were summed. The 128-bit port serialises data beats; only the
   fixed overhead overlaps. Fixed with an explicit `port_free` model.
3. **The drain estimate was in the wrong units**: a count of outstanding items
   was used as a duration. The control plane now asks the data plane
   `drain_ready(phys, cycle)` and converts to cycles.
4. **A draining frame was disqualified by its own reservation.** `reserved > 0`
   IS the outstanding work, so it must not disqualify; only `refcount > 0` means
   software still holds the object.
5. **Queueing delay was reported as an AXI protocol error.** A slow transfer is
   an envelope breach, not a protocol violation.
6. **Statistics were structurally capped at `n_descriptors`.** Descriptor IDs
   are recycled and the table was keyed by ID, so a reused ID overwrote its
   predecessor and `completed` could never exceed 16. This is what produced
   identical DDR utilisation at three different offered loads.
7. **A livelock from enforcing the descriptor reserve twice**, at admission and
   again at issue. An admitted speculative descriptor holds its own slot, so
   `free_desc` stayed at or below the reserve forever. The reserve is enforced
   once, at admission.
8. **The speculative byte ceiling was a lifetime budget**, so once spent the
   design permanently disabled its own speculation and never drained. It is now
   windowed, and speculation that waits too long is CANCELLED rather than
   queued forever.
9. **Traces were roughly 5x oversubscribed**, so every policy saturated and the
   comparison measured nothing. Traces are now generated against an explicit
   target load, and deadlines are set as multiples of service time that account
   for queueing at that load.

## What the model asserts, as D1 hard kills

Each maps to an ILA trigger name so the model and the board agree on what a
failure looks like: `trig_cross_tenant_hit`,
`trig_stale_generation_completion`, `trig_reuse_not_quiescent`,
`trig_counter_underflow`, `trig_admitted_deadline_miss`,
`trig_spec_consumed_reserved`, `trig_axi_protocol_error`,
`trig_unmatched_completion`, `trig_duplicate_completion`,
`trig_lost_completion`.

On-time is measured at **completion**. The D1 kill is measured at **issue**,
because the PL can only guarantee issue: completion depends on the declared
downstream service envelope.
