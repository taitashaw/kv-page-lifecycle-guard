# Red team review of the architecture boundary

Run 2026-08-23 before any production RTL, as the brief requires. The job is to
falsify, not to confirm. Five attacks were pressed. Two failed, two succeeded
and forced changes, one is fatal to a claim we had not yet made in public.

---

## ATTACK 1: the byte arithmetic does not close. FAILED, the design survives.

Per access, with p the fraction judged confident, m the miss rate among those,
and r the ratio of cheap to full representation size, a miss costs both the
cheap fetch and the exact fetch:

    E = p[(1-m)Bc + m(Bc + Bf)] + (1-p)Bf
      = p*Bc + Bf(1 - p + p*m)

This beats exact fetch whenever Bc < Bf(1-m), that is **m < 1 - r**.

At INT4 against FP16 (r = 0.25) the design saves bytes while the miss rate among
confident fetches stays **below 75 percent**. That is a far more forgiving
condition than expected, and it is the single strongest structural argument for
the architecture.

Measured operating points, bytes relative to exact fetch:

| p | m = 0.05 | m = 0.15 | m = 0.30 |
|---|---|---|---|
| 0.6 | 0.58x | 0.64x | 0.73x |
| 0.8 | 0.44x | 0.52x | 0.64x |
| 0.9 | 0.37x | 0.46x | 0.60x |

**Worst case is bounded and computable**: if every confident fetch is wrong, cost
is 1 + r, that is **1.25x exact fetch at INT4, 1.50x at INT8**. This replaces the
vague phrase "bounded-cost fallback" with a specific number that can be stated in
advance and checked on hardware. Use the number, not the adjective.

---

## ATTACK 2: the cheap copy has to come from somewhere, and that cost was missing. SUCCEEDED.

To fetch a low-precision copy, one must exist. Compressing at read time saves
nothing, because the bytes have already crossed the bus. So the cheap copy must
be written alongside the full one, which costs DDR capacity and write bandwidth.
**The trade study did not account for this.**

Quantified: 1.25x capacity and 1.25x write traffic at r = 0.25.

It amortises, because in decode each token's KV is written once and read once per
subsequent token, so for context length L the read to write ratio is about L/2.
At L = 2048 the extra write is 0.024 percent of the benefit; at L = 8192 it is
0.006 percent.

**REQUIRED CHANGE**: SPEC.md must state the dual-representation storage cost
explicitly, and the evaluation must MEASURE total bytes including writes, not
only read traffic. Reporting read savings alone would be the exact kind of
hidden-cost accounting the brief forbids.

---

## ATTACK 3: Learn-then-Test cannot run in hardware. SUCCEEDED, and it demotes a claim.

Learn-then-Test is an offline procedure: it selects a threshold on held-out data
with a finite-sample validity guarantee. It does not need to execute in the
fabric. Only the resulting constant does.

That is convenient for implementation and damaging to the novelty story. What
remains in hardware is **a comparison of a confidence value against a constant
threshold**, which is precisely what Intel WO2025184895A1 claims: incorporate a
hint "if the reuse likelihood is greater than a threshold", with a dependent
claim expressly reciting key-value cache requests.

**REQUIRED CHANGE**: stop describing calibration as a hardware contribution. The
honest split is:

- hardware contribution: a representation-selecting fetch engine with a bounded
  exact-recovery path, and the counters that make the bound checkable
- methodology contribution: an offline risk-control procedure that makes the
  exactness claim defensible rather than anecdotal

Both are real. Conflating them would not survive review.

---

## ATTACK 4: this is HOBBIT with a fallback bolted on. PARTIALLY SUCCEEDED.

HOBBIT already selects fetch precision from a runtime score. A reviewer can
fairly characterise candidate A as HOBBIT plus a fallback, and that framing
lands.

The rebuttal is narrow but genuine: HOBBIT's low-precision result is final, so
its accuracy loss is permanent and unquantified for that token. Adding a bounded
exact-recovery path is what converts an unquantified quality loss into a stated
risk level with a worst-case cost of 1.25x. The contribution is the guarantee,
not the precision selection.

**REQUIRED CHANGE**: the paper and any public copy must state the HOBBIT
relationship in the first paragraph of related work, in these terms, rather than
letting a reviewer discover it.

---

## ATTACK 5: the novelty score rests on sweeps that were never completed. STANDS. UNRESOLVED.

Candidate A scored 25 of 30 on novelty. That score rests on two prior-art sweeps
that completed and two that were killed by a session limit and never redone:
the KV-cache prior art, including whether the fourteen arXiv IDs in the brief
resolve at all, and the edge-FPGA LLM inference survey.

The MoE and speculation sweep covered expert prefetch thoroughly. **Nobody has
yet swept KV-cache prefetch with precision selection specifically.** That is the
nearest neighbourhood to the actual claim.

**THIS IS THE BLOCKING FINDING.** Novelty cannot be asserted at 25 of 30 until
that sweep runs. Provisional score pending completion: treat as unknown, not as
25.

---

## Disposition

| finding | severity | status |
|---|---|---|
| 1 byte arithmetic | none, design survives | closed, use the 1.25x number |
| 2 dual-representation cost unaccounted | material | fix required in SPEC.md and evaluation |
| 3 calibration is offline, not hardware | material | claim demoted, split stated |
| 4 HOBBIT proximity | moderate | disclose in related work, first paragraph |
| 5 incomplete prior-art sweep | BLOCKING | must complete before RTL |

## Verdict

The architecture is sound and the arithmetic is stronger than expected. Two
claims have been demoted to their honest form. **The boundary is NOT accepted
for RTL** until the KV-cache prefetch-with-precision sweep is complete, because
that is the one neighbourhood where an anticipating reference is most likely to
live and where nobody has looked.

---

# ATTACK 6: THE BOUND IS VACUOUSLY SATISFIABLE. SUCCEEDED.

Raised by the adversarial judge at the close of the prior-art sweep,
23 Aug 2026. This is the most serious finding in the file and it lands on the
claim that Decision 001 just made the headline.

## The attack

Invariant 8 states `bytes_read <= 1.25 * (n_req * 256)`. Two degenerate
policies satisfy it while doing no useful work whatsoever:

1. **Never take the compact path.** Always fetch exact. Traffic is exactly
   1.0x. Invariant holds.
2. **Always take the compact path AND always re-fetch exact.** Traffic is
   64 + 256 = 320 B per request, exactly 1.25x. Invariant holds.

**So the bound alone certifies nothing about whether the mechanism works.**
It is a safety property in the strict sense: it forbids a bad outcome and says
nothing about achieving a good one. A reviewer who notices this, and they will,
can say the guarantee is satisfied by a design that has been switched off.

## The second half of the attack, which is worse

If the compact representation is at most 0.25x the exact one, and the exact
fetch is issued at most once per miss, then "at most 1.25x" is **a one-line
arithmetic identity that falls out of the size ratio by construction**. It is
not a theorem with content. Any two-representation scheme with a bounded compact
size gets the same statement for free. **Token-Picker's design already implies
it and merely declined to write it down.** So the contribution risks reading as
a bookkeeping observation about Token-Picker dressed up as a guarantee.

## Verdict: the attack succeeds. Two fixes are required.

### Fix 1: state the bound honestly as a safety property, and say it is vacuously satisfiable

The spec must say, in the same paragraph as invariant 8, that the bound is a
safety property, that it is satisfiable by a disabled design, and that it
therefore certifies the absence of a harm rather than the presence of a
benefit. Anything less is overclaiming and will be caught.

### Fix 2: add a non-vacuousness witness, carried by hardware counters, NOT by the proof

The evidence that the mechanism does useful work cannot come from an invariant,
because it is a performance claim and this project does not assert liveness
anywhere. It has to come from MEASURED counters:

- `n_compact_sufficient`: compact path taken AND no exact fetch followed
- the achieved ratio `bytes_read / (n_req * 256)`, which must be measurably
  BELOW 1.0 for the design to be doing anything
- both read from the register aperture on hardware, at the ILA gate

The write-up then carries a two-part claim that is honest end to end: a proved
and runtime-asserted ceiling of 1.25x, plus a MEASURED achieved ratio below
1.0. Neither half alone is worth anything. The first without the second is
vacuous; the second without the first is the ordinary empirical claim every
paper in the sweep already makes.

This is consistent with the standing discipline: safety properties are proved,
performance is measured and labelled MEASURED, and the two are never conflated.

## Related weakness the judge also names, recorded but not fixable here

Nothing in the swept literature bounds ACCURACY loss either, so this design
inherits the field's standard weakness of guaranteeing the cheap side of the
trade and evaluating the expensive side empirically. That is already recorded
honestly in SPEC.md section 2 as the split between delivery exactness (enforced
in hardware) and value exactness (risk-controlled offline, NOT enforced). It
does not get better under the pivot and must not be quietly dropped from it.

## Why this does not kill the project under Decision 001

Because Decision 001 already moved the headline off the mechanism and onto the
artifact: a real KV cache page manager in Zynq UltraScale+ fabric, which nobody
has built, carrying a bound that is honestly described and measured evidence
that no published FPGA LLM accelerator paper provides. The judge independently
recommended the same pivot for the same reason, having been given the three
options without a recommendation attached.
