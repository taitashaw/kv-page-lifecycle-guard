# SWEEP B RESULT: DISCOVERY_NO_GO_BRANCH_CLOSED

Run `B-PRIMARY-20260824T133827Z`. Audit PASSED. Verdict computed by the frozen engine only.

## Integrity, all green before any number was read

| check | result |
|---|---|
| records present | 77,760 |
| unique (config, seed, policy) keys | 77,760, zero duplicates |
| malformed checkpoint lines | 0 |
| records per policy | 8,640 x 9 |
| distinct configurations | 8,640 |
| frozen run-input hashes | 11 of 11 match |
| N_out, L_down_max | 2, 784 |
| cohort identity | **REGENERATED from the frozen generator and matched**, not merely count-equal |
| censored requests | 0, in every policy |
| coverage-based row exclusion | none; kept == produced |

canonical SHA-256 `c30b76c78517041f8bdae04bea8398a17a86ec893e12d2651db43eabeea03b1c`

## Verdict

    cells evaluated        1728
    degenerate seed-cells  0
    cells passing >=3/5    0
    qualifying regions     0

    OUTCOME: DISCOVERY_NO_GO_BRANCH_CLOSED
    branch_closed=True  confirmation_required=False
    rtl_authorized=False  interpretation_permitted=True

**Not one cell out of 1,728 passed.** This is not a marginal miss.

## What the numbers actually look like

integrated versus tuned_axi_qos across all 8,640 comparable **configuration-seed runs** (1,728 cells across five seeds):

| statistic | value |
|---|---|
| min relative on-time gain | -9.5% |
| 5th percentile | -4.0% |
| **median** | **-0.50%** |
| 95th percentile | +3.1% |
| max | +15.0% |
| configurations reaching the +10% gate | **36 of 8,640 (0.4%)** |
| better / tie / worse | 1,258 / 2,783 / **4,599** |
| aggregate completion-retention ratio | **99.19%**, 1,548,506 candidate completions over 1,561,134 baseline completions across 8,640 **configuration-seed runs**. A ratio of sums, which IS equivalent to weighting each run by its baseline completion count. It is not an unweighted mean and not a median |

Median gain by offered load: +0.00% at 0.70, then **-0.50%, -0.53%, -0.53%** at
0.80, 0.90 and 0.95.

**The candidate is slightly worse than tuned AXI QoS more often than it is
better. It did not improve under greater pressure and showed slightly negative
median gains at higher loads.** A change from -0.50% to -0.53% is far too small
to support a degradation trend and is not claimed as one.

The 36 configurations that did clear +10% never formed a region, because no cell
reached 3 of 5 shared seeds. They are **isolated, non-qualifying observations**.
Without a statistical test they cannot be labelled noise either.

## The narrower conclusion, which is the one that stands

> Within the frozen synthetic model and parameter grid, the integrated C+D
> policy failed its discovery gate. None of 1,728 cells formed a qualifying
> adjacent-load region with at least three shared passing seeds. The C+D
> performance branch is closed.

## Consequence, per the frozen protocol

The C+D **performance** branch is CLOSED. No confirmation run. No 20-seed
validation. No RTL is authorized on the strength of this policy.

## What survives

- **The lifecycle counterexample**, as a verified correctness artifact. A page
  released while its transfer is in flight reads refcount 0 and a naive capacity
  test calls the frame free. The joint predicate rejects it; every independent
  policy, including the memory-safe one, admits it and misses. That result is
  unaffected by this verdict.
- The corrected event model, the bounded lifecycle handle, the transaction
  oracle, the critical-mutant gate and the allocator regression.
- The measured platform work: ILA budget, URAM finding, debug-hub divider, the
  passed JTAG bring-up at 301.03 MHz.
- The refuted latency bound and its correction, 1776 to 1936, with the
  independent validator.

## Honest reading

The hypothesis was that coupling deadline, capacity and lifecycle into a joint
admission forecast would improve offered-cohort on-time completion. **On this
frozen grid, under a passing audit, it does not.** It costs a little service and
buys nothing measurable. The correctness property it was built around is real
and is worth keeping; the performance claim is not.


---

## Auditor hardening applied AFTER the verdict, documentation only

Not a reason to rerun Sweep B. Both auditor versions and the failed audit
artifact are preserved (`audit_sweep_b_v1_keyed_on_tuple.py.bak`,
`runs/*/audit_artifact_FAILED_v1.json`).

Three checks added so the tuple-keying defect cannot recur silently:

**Auditor v2 is RETROSPECTIVE.** It ran AFTER performance results had been read.
Corrected auditor **v1 was the pre-unblinding gate**; v2 is **post-unblinding
corroboration** and cannot be described as the audit that protected the original
unblinding.

| check | result |
|---|---|
| `cfg_key == canonical_serialization(cfg values)` on every row | PASS |
| two cfg dicts with identical KEYS but different VALUES yield different identities | PASS |
| observed `(policy, canonical_cfg, seed)` set equals the expected Cartesian product | PASS, **77,760 members** |

The Cartesian check is the strongest **completeness and membership** evidence in
the run. It does **not** prove model semantics or numerical correctness. The
expected product is generated by an independent serialisation path, not by the
same `canonical_cfg` helper used on the observed records, so a common-mode
serialisation defect cannot make both sides agree while both are wrong.

## RTL conformance check: the existing files do NOT match the final contract

`rtl/lens2/` holds 5 SystemVerilog files and a Tcl script from the earlier
out-of-context synthesis work. They are a useful skeleton but they predate the
corrected event and lifecycle contracts.

| contract element | present in rtl/lens2 |
|---|---|
| refcount, reservation, inflight, fill_pending, generation | YES |
| **lifecycle_slot** | **ABSENT** |
| **expected_generation** | **ABSENT** |
| **transaction_tag** | **ABSENT** |
| lifecycle ops | only 4: ref, release, fill-start, fill-done |
| four-event transaction lifecycle | not modelled |

**Correction to my own claim:** the existing RTL CAN express the basic interlock.
It already carries `refcount` and `inflight`, so

    evictable = (refcount == 0) && (reservation == 0)
             && (inflight == 0) && !fill_pending

is directly expressible. What it cannot implement is the COMPLETE contract:
descriptor-to-slot lookup, expected-generation validation, tagged completion
routing, stale-descriptor rejection, and complete transaction-event accounting.

**`DDR_SERVICE_START` is not directly observable.** With PS DDR behind
SmartConnect and the Zynq memory controller, PL logic can observe DISPATCH,
AXI_ACCEPT (AR/AW handshake), AXI_FIRST_DATA (first R beat) and AXI_COMPLETE
(RLAST or B handshake). It cannot see when the DDR controller begins servicing.
`DDR_SERVICE_START` is therefore **model-only** and is replaced in the RTL and
HIL contract by `AXI_FIRST_DATA`.

The rejected EDF/deficit arbiter and credit accountant are NOT brought into V1;
they are unnecessary for a lifecycle-safety artifact.
