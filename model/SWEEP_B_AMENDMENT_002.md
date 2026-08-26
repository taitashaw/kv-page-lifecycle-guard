# SWEEP B AMENDMENT 002

```
run_id: B-PRIMARY-20260824T133827Z
previous_amendment_sha256: 3ad74c389496d6c53853ac317ecbf3e7da500a3f79bcf08b6595b4e7120a3065
changes_experimental_inputs: false
created_utc: 2026-08-24T14:17:43Z
```

Amendment 001 is FINALIZED and read-only. Its self-hash section was invalid
and has been removed; its checksum is detached in
`SWEEP_B_AMENDMENT_001.md.sha256`.

## FINDING: the numeric decision thresholds were NOT cryptographically frozen

This is the honest label, not a formality. Checked read-only:

| location | numeric gates present? |
|---|---|
| any of the 11 hashed inputs | **NO** |
| `runs/B-PRIMARY-20260824T133827Z/manifest.json` | **NO** |
| `sweep_b.py` | **NO**, it computes descriptive aggregates only and prints "No GO/NO-GO is inferred here" |
| `SWEEP_B_CONTRACT.md` section 7 (pre-launch, 03:55Z) | protocol only: 20 fresh seeds, paired CI excluding zero, no parameter changes. **The numeric gates are NOT restated** |
| `quarantine_sweep_A/FROZEN_SWEEP_PLAN.md` lines 47-48 (2026-08-23) | **YES**, and this is the contemporaneous pre-launch decision record |
| `SWEEP_B_AMENDMENT_001.md` | yes, but that file is POST-LAUNCH and therefore not evidence of predeclaration |

**Status: PREDECLARED and CONTEMPORANEOUS, but NOT cryptographically frozen.**
The gates were written down on 2026-08-23, before Sweep A, and carried
forward unchanged. They were never revised. But they live only in prose, and
the single pre-launch document that states them numerically is itself
QUARANTINED, because the quarantine concerned the invalid MODEL, not the
thresholds. That is a weaker chain than a manifest entry and is labelled as
such rather than presented as frozen.

**BINDING ON THE CONFIRMATORY RUN: every threshold goes directly into the
immutable manifest.** No prose, no amendment, no external file.

`FROZEN_VALUES_EXTRACT.json` is a read-only extraction of everything the
hashed source DOES determine: `N_out = 2`, `L_down,max = 784`, the full
envelope, the nine policies, `row_exclusion: none`, and the exact censoring
predicate `uncensored = [r for r in fetches if r.deadline <= horizon]`.
It changed nothing and read no performance rows.

## Evidence package now includes the excluded test files

The four test files that are NOT runtime inputs are still required to
reproduce the claimed pre-launch gate, so they are hashed in
`EVIDENCE_PACKAGE.sha256` alongside the auditor, the independent validator
and its report, the extractor, and both prose records. Changing any of them
would not invalidate the numerical sweep, but it would change which gate was
demonstrated.

## Process identity, corrected

```
run_pid:          2310723
pid_start_ticks:  82169320
boot_id:          a04665be-796b-4331-8cf4-571ab9c453cf
```

Start ticks are unique only within one boot, so they are paired with the
boot id. Both were captured AFTER launch, so this is a **late-captured
identity check**, not launch-time provenance. **The run-specific advisory
lock remains the stronger continuity evidence.**

## Wording correction

`-r--r--r--` is **protection against accidental editing, not immutability**.
The owner can restore write permission at any time.
