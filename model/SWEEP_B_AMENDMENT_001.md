# SWEEP B AMENDMENT 001

```
run_id: B-PRIMARY-20260824T133827Z
original_manifest_sha256: a73d1862cd1bbf50fabd4122ab82456c078447126f0e0719d1636e4cd470c72f
changes_experimental_inputs: false
created_utc: 2026-08-24T13:57:55Z
```

Append-only. Records post-launch documentation ONLY. It changes no
experimental input and is not itself a hashed input.

## Run validity confirmed

`SWEEP_B_FROZEN.md` was edited after launch. Checked immediately: it is
**NOT** among the eleven hashed inputs, so no hash drift occurred and the
run remains VALID. `SWEEP_B_FROZEN.md` has been truncated back to its
launch state and is now append-only-forbidden; this file supersedes it for
everything after launch.

## CORRECTION 1: the hashed-input inventory was overstated

I said "all nine gm/*.py files, the runner, all five test files" were
hashed. That is fifteen files. **Only eleven are hashed**, and the
distinction matters:

| file | role |
|---|---|
| `gm/__init__.py` | EXECUTION INPUT, can change a number |
| `gm/checks.py` | EXECUTION INPUT, can change a number |
| `gm/control_plane.py` | EXECUTION INPUT, can change a number |
| `gm/coverage.py` | EXECUTION INPUT, can change a number |
| `gm/data_plane.py` | EXECUTION INPUT, can change a number |
| `gm/policies.py` | EXECUTION INPUT, can change a number |
| `gm/sim.py` | EXECUTION INPUT, can change a number |
| `gm/traces_b.py` | EXECUTION INPUT, can change a number |
| `gm/types.py` | EXECUTION INPUT, can change a number |
| `sweep_b.py` | EXECUTION INPUT, can change a number |
| `tests/test_gm_targeted.py` | EXECUTION INPUT: the targeted suite's expected count is pinned to its sha256 |

The other four test files (`test_gm_mutations`, `test_gm_counterexample`,
`test_gm_pending_swap_defect`, `test_gm_handle`) are **EVIDENCE
ARTIFACTS**, not execution inputs. They gate the source before launch and
cannot alter a sweep record. They are correctly excluded from the manifest.

## CORRECTION 2: the bound gate must show BOTH outcomes

```
Original 1776-cycle formula : REJECTED by the independent validator
                              (observed 1936 at the shipped point;
                               443/675 in-domain cells refuted)
Corrected formula           : PASS against the independent validator
Frozen N_out                : 2
Frozen L_down,max           : 784 cycles
```

Importing the worker and observing 784 checks CONFIGURATION CONSISTENCY,
not independent correctness. The independence comes from
`validate_ldownmax.py`, which never imports `gm/data_plane.py`.

## CORRECTION 3: "47" is ASSERTIONS, not records

Measured: 46 static `ck(` call sites, **47 assertions executed** (one sits
in a loop). The manifest field is named `targeted_suite.expected_records`,
which is a **misnomer** that I repeated. It counts assertions in the
targeted correctness suite. It is not comparable to a distributional
record and the two are never summed.

The manifest cannot be corrected without invalidating the run, so the
field name stands and this amendment is the authority on its meaning.

---

## Bound-validation gate, previously missing from the table

| gate | result |
|---|---|
| independent latency-bound validator | **REFUTED the old 1776 form**, corrected to the current one; `LDOWNMAX_VALIDATION.md`, 26 KB report, `validate_ldownmax.py` 48 KB |

Read-only verification against the frozen workers, imports only:

    N_out            == 2        PASS
    l_down_max()     == 784      PASS
    policy_count     == 9        PASS
    config_count     == 8640     PASS
    expected_records == 77760    PASS

Manifest confirms 11 hashed inputs, `row_exclusion: none`, coverage recorded as
"annotations for stratification only; never an eligibility filter", and the
targeted suite counted SEPARATELY at 47 records with its staleness check clean.

## INTERRUPTION RULE

**Process interruption may resume from verified checkpoints.** Losing at most
one configuration to a kill is the whole reason checkpoints are fsync'd.

**Any change to a hashed input requires abandoning the run and creating a new
run id.** A changed experiment may never continue under an existing identity.
`audit_sweep_b.py` enforces this by re-hashing every frozen input at audit time
and declaring the run INVALID on drift.

## FINAL AUDIT, required before the verdict may be read

`audit_sweep_b.py` refuses to run while any `sweep_b.py` process is live,
because inspecting partial performance rows mid-flight is what the protocol
forbids. It establishes:

- 77,760 valid records
- 77,760 unique (config, seed, policy) keys, zero duplicates
- zero missing expected keys, zero malformed lines
- 8,640 records per policy, 9 records per configuration, 8,640 distinct configs
- every frozen source and configuration hash still matching
- canonically sorted output before its SHA-256 is taken
- censored requests reported per policy
- kept rows == produced rows, so no annotation excluded anything

## HANDOFF. Sweep B success does NOT authorize Vivado.

Sweep B is the DISTRIBUTIONAL DISCOVERY pass. The confirmatory rule is binding.

    Sweep B fails
        -> close the C+D performance branch
        -> no Vivado project

    Sweep B discovers a qualifying region
        -> freeze that exact region, parameters unchanged
        -> >= 20 FRESH, previously unused deterministic seeds
        -> paired comparisons vs tuned_axi_qos AND separable_conservative_guard
        -> paired confidence interval on the improvement must EXCLUDE ZERO
        -> reapply the ORIGINAL hard gates unchanged:
             >= 10% offered-load on-time goodput improvement
             >= 90% of tuned AXI QoS completed throughput
             improvement at TWO ADJACENT load points
             no safety or accounting trigger
             benefit NOT produced solely by rejecting more work
        -> confirmatory FAILURE: close the branch
        -> confirmatory SUCCESS: begin RTL and batch regression
             -> V1: OPEN VIVADO

## Carried into the RTL specification, not blocking Sweep B

The bounded descriptor models RTL identity correctly **provided**:

1. `lifecycle_slot` and `expected_generation` receive EXPLICIT WIDTHS in the RTL
   spec. `Params` currently declares `w_generation = 8`; `lifecycle_slot` needs
   `ceil(log2(n_meta_entries))` and must be stated, not implied.
2. **Slot reuse is PROHIBITED while any matching reservation or transaction
   remains outstanding.** The model frees a slot only via `_free_slot`, which
   runs on reclaim and on swap completion, both gated by `evictable()`. That
   ordering must be an explicit RTL invariant rather than an emergent property.

---

## PROVENANCE TIGHTENING, appended 2026-08-24T14:02:40Z

### The frozen document is a RECONSTRUCTED launch copy, not a proven restoration

`SWEEP_B_FROZEN.md` was never itself hashed at launch, so **no launch-time
hash exists and byte-for-byte restoration cannot be proven.** A 3,645-byte
length is not evidence. Calling it "restored to its launch state" was
wrong on two counts, because the do-not-edit marker I added was itself
post-launch text, so a file containing it could not be the launch state.

The marker has been removed and the prohibition moved to the filesystem:

```
reconstructed_launch_copy_sha256: 4f32ff28258014c8f55dacac1eaebe5fc7de23af6c1d5d3bb4d6e1b089eb83d6
launch_copy_sha256:               NONE RECORDED
match:                            UNPROVABLE
permissions:                      -r--r--r--
```

This does not affect run validity: the file is not an experimental input.

### CORRECTION 4: three categories, not two

`tests/test_gm_targeted.py` is **not** a runtime input. `sweep_b.py` never
imports or executes it. Correct classification:

| category | files | role |
|---|---|---|
| **runtime inputs** | the 9 `gm/*.py` + `sweep_b.py` | model, policies, runner, embedded configuration. Can change a number |
| **gate inputs** | `tests/test_gm_targeted.py` | pre-launch verification. Its hash protects the MEANING of the targeted-suite evidence, not any sweep record |
| **evidence tools** | `validate_ldownmax.py`, `audit_sweep_b.py` | interpret and audit frozen outputs. Never experimental inputs |

Keeping the gate input inside the eleven protected hashes is conservative
and stays. Only the role label was wrong.

### What the manifest pins, and what it does NOT

Declared explicitly and human-readable: the nine-policy list, all 8,640
configuration keys as a 7-axis product, the seed list, the horizon rule,
`row_exclusion: none`, the exact launch argv, and a config hash.

**NOT declared explicitly:** `N_out = 2`, `L_down,max = 784`, the
thresholds and the censoring rule. These are pinned only TRANSITIVELY, via
`source_sha256["gm/types.py"]` and `["gm/sim.py"]`. That is
cryptographically sound but not self-describing, so a reader must recompute
them from the pinned source rather than read them off the manifest. Recorded
as a manifest-schema defect to fix in the confirmatory run, not in this one.

### Process identity, for the audit

```
run_pid:          2310723
pid_start_ticks:  82169320
```

The manifest is immutable and predates this field, so the audit treats it
as optional and falls back to cmdline plus run-id matching when absent.
The audit additionally refuses while ANY process matching this run id is
alive, not just the parent.

### CORRECTION 5: the "47" wording, final form

```
46 static assertion call sites
47 dynamic assertion evaluations
 0 failures
```

The term "records" is retired for this suite entirely.

### Evidence package

Hashes are NOT recorded inside this file. A file cannot contain the
SHA-256 of its own final contents. See the detached
`SWEEP_B_AMENDMENT_001.md.sha256` and `EVIDENCE_PACKAGE.sha256`.
