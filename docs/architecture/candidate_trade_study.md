# Candidate architecture trade study

Run 2026-08-23 against the brief's weights: defensible novelty 30, ZCU104
feasibility 20, systems impact 20, hardware measurability 15, reproducibility
10, clarity of the central insight 5. Reject below 80.

Inputs: docs/research/prior_art_matrix.md, docs/research/patent_landscape.md,
docs/research/platform_envelope.md, docs/architecture/feasibility_envelope.md.

DISCLOSURE OF BIAS: candidate A is the brief's own starting hypothesis. It is
reported here as surviving, so the reasons and the kill criteria are stated
explicitly and the reader can check whether the scoring was rigged toward it.

## Scores

| candidate | nov/30 | feas/20 | impact/20 | meas/15 | repro/10 | clar/5 | TOTAL | verdict |
|---|---|---|---|---|---|---|---|---|
| A  Confidence-Gated Precision Prefetch | ~~25~~ ~~21~~ 17 | 18 | 17 | 14 | 9 | 5 | ~~88~~ ~~84~~ **80** | **AT THE GATE** |
| B  Bounded-Cost Speculative Fetch only | 18 | 19 | 12 | 14 | 9 | 4 | **76** | reject |
| C  Coalescing Predictive Page Scheduler | 10 | 19 | 14 | 14 | 9 | 3 | **69** | reject |
| D  Compressed-domain page selection | 14 | 14 | 15 | 10 | 8 | 3 | **64** | reject |
| E  Risk-controlled multi-tenant admission | 20 | 17 | 16 | 13 | 9 | 4 | **79** | reject |

## Why each score fell where it did

### A. Confidence-Gated Precision Prefetch, 84 (revised down from 88), SELECTED

Predict which KV pages or experts are needed next; attach a confidence with
finite-sample validity; use that confidence to choose WHICH REPRESENTATION to
fetch (cheap low-precision copy when confident, exact copy when not); and carry
a bounded-cost exact fallback when the cheap copy proves insufficient.

Novelty 25/30. The b-to-c coupling is unclaimed in every paper and patent found
across two independent sweeps. Points deducted, not for absence of a gap, but
for the composite-obviousness exposure: Intel WO2025184895A1 supplies predict
plus threshold confidence with a dependent claim expressly reciting KV cache
requests; Tenstorrent US20240111525A1 supplies a fidelity control value setting
precision with no limitation on its origin; Tenstorrent US20250298621A1 supplies
aggressive-mode execution with cancel and conservative re-execution. Three live
patents, two sharing an inventor core. The design must therefore carry weight on
HOW confidence is calibrated and HOW the fallback cost is bounded, not on the
combination being new.

Feasibility 18/20. Predictor table, confidence accumulator, representation
selector and fallback sequencer are small state machines and arithmetic. They
fit inside 4.75 MB with room for ILA. Deduction because the design MUST coalesce
into 128 to 192 byte bursts or the measured 70 percent small-burst penalty eats
the entire benefit, and that constrains the page granularity.

Impact 17/20. Bytes moved is the binding constraint on this board and, per the
literature, in decode generally. A mechanism that reduces bytes per useful
result attacks the actual bottleneck. Deduction because the gain depends on
predictor quality on real traces, which is not yet measured.

Measurability 14/15. Every claim is countable in hardware: bytes moved per
token, fallback frequency, prediction recall and precision, and above all
whether the risk-control guarantee holds empirically. That last one is a
falsifiable claim a hostile reviewer can check.

Clarity 5/5. "Fetch the cheap copy when the predictor is confident, the exact
copy when it is not, and never be wrong without a bounded way back."

### B. Bounded-cost speculative fetch alone, 76, REJECT

The fallback bound without the precision lever. Novelty 18/30 because
Tenstorrent US20250298621A1 already claims aggressive execution, detection of a
wrong assumption, cancellation and conservative re-execution. Impact 12/20
because without choosing representation there is little to save: you either
prefetched right or you did not.

### C. Coalescing predictive page scheduler, 69, REJECT

Predict page access and reorder DDR requests into efficient bursts. Novelty
10/30: prefetch coalescing is one of the most heavily trodden areas in computer
architecture and the AMD and Intel portfolios crowd it densely. It would be a
good engineering result and a poor research result.

### D. Compressed-domain page selection, 64, REJECT

Score pages without decompressing them. Novelty 14/30 because compressed-domain
attention already exists in the literature. Feasibility 14/20 and measurability
10/15 because establishing that the mathematics is valid requires model-level
quality evaluation, which the board cannot perform: it would move the burden of
proof off the hardware and onto host software.

### E. Risk-controlled multi-tenant admission, 79, REJECT, and it is the close one

Conformal risk control deciding which speculative fetches are admitted under a
bandwidth budget with deadline guarantees. Scored 79, one point below the gate,
and the deciding factor is that cxl-kv-forge-qos already implements tenant
credits, token buckets, a deadline-aware tournament arbiter and SLA telemetry,
closed at 350 MHz. The genuinely new part would be the risk-control layer, which
is a component of candidate A rather than a separate architecture. RECOMMENDATION
carried forward: fold the admission idea into A as a later phase rather than
pursuing it standalone.

## The selected boundary

Selected bottleneck: bytes moved per generated token during decode, when the
working set lives in DDR and the on-chip capacity is two orders of magnitude too
small to hold it.

Selected architecture: candidate A.

Closest five prior works: ST-MoE (arXiv 2606.15453), HOBBIT (arXiv 2411.01433),
CXL-SpecKV (arXiv 2512.11920, FPGA'26), RFVP (ACM TACO 2016), and CALM
(arXiv 2207.07061) for the risk-control method rather than the architecture.

What is new, precisely: using a confidence with finite-sample validity to select
the REPRESENTATION of speculatively fetched inference data, paired with a
fallback whose worst-case cost is bounded and stated in advance.

What is reused: group quantization from kvcache-compress-engine, top-k selection
structure from moe-router-engine, and the AXI and DMA data-path pattern from
both. Learn-then-Test is taken from the calibration literature unchanged.

## The falsifiable hypothesis

At a stated risk level epsilon, the design moves strictly fewer bytes per token
than exact fetch, while the measured rate of exactness violations does not
exceed epsilon on held-out traces.

## The minimum experiment that can disprove it

Replay a held-out trace through the board with counters enabled. If measured
bytes per token is not below the exact-fetch baseline, or if the exactness
violation rate exceeds epsilon, the hypothesis is dead as stated.

## Kill criteria agreed in advance

1. If predictor accuracy on real traces is so low that the fallback path
   dominates and total bytes moved exceeds exact fetch, the design loses. Report
   it and pivot to candidate E.
2. If required page granularity forces bursts below 128 bytes, the measured
   small-burst penalty erases the benefit. Redesign the page layout or stop.
3. If the risk-control guarantee cannot be demonstrated empirically on hardware,
   drop every calibration claim and describe the work as a confidence-gated
   prefetcher with measured hit rates, which is a weaker but honest result.

## Status after red team and the blocking sweep

The adversarial review ran (docs/reviews/red_team_findings.md) and pressed five
attacks. The byte arithmetic survived and produced a specific worst-case bound of
1.25x exact fetch. Two claims were demoted: the dual-representation storage cost
must be measured, and calibration is an offline methodology rather than a
hardware contribution.

The blocking sweep then ran (docs/research/kv_precision_sweep.md). All fourteen
arXiv IDs in the brief resolve. No anticipating reference was found, but three
papers now own the individual ingredients: Don't Waste Bits (2604.04722) and
HOBBIT (2411.01433) own runtime-score-selects-precision, Conf-KV (2605.24786)
owns model-confidence-drives-KV-policy, and DualDecoder (2607.26475) owns
predictive KV prefetch.

NOVELTY REVISED TWICE. 25 to 21 after the KV precision sweep, then 21 to 17
after the deep full-text sweep found APEX and TRACE. Candidate A total is now
80 against a gate of 80: exactly at the threshold, no margin.

See docs/research/deep_sweep_findings.md. APEX (CODES/ESWEEK 2026, IEEE TCAD,
peer reviewed) calibrates a data-movement predictor with an ordinal-logistic
CDF and uses that confidence to set prefetch VOLUME. That withdraws my earlier
claim that nobody calibrates a data-movement predictor. TRACE publishes
multi-representation storage with partial fetch and exact recovery, driven by
static config.

What remains open is ONLY: the coupling of a predictor's confidence to the
fetched representation, and a stated numeric worst-case bound.

DECISION REQUIRED FROM JOHN before RTL. See the honest options below.


---

## Post-sweep decision point, added 2026-08-23

Candidate A now scores exactly 80 against a gate of 80. Three honest options:

**Option 1: proceed as narrowed.** Claim only the (b) to (c) coupling and the
1.25x numeric bound. Cite APEX and TRACE as nearest neighbours in the first
paragraph. Pre-empt SpecMD's negative result explicitly. This is defensible but
the contribution is now one mechanism and one number, not an architecture.

**Option 2: raise the contribution by adding what nobody has.** The sweep found
that a formal worst-case traffic guarantee does not exist anywhere in this
literature. Make THAT the headline rather than the coupling: an accelerator with
a proved, runtime-asserted bound on bytes moved per token under adversarial
misprediction. The coupling becomes the mechanism, the bound becomes the claim.
This is stronger, more falsifiable, and plays to the formal-methods work already
proven in the adjacent projects.

**Option 3: pivot.** The scoring is at the gate and Apple has published a
negative result in the adjacent regime. A pivot is legitimate and the kill
criteria permit it.

RECOMMENDATION: Option 2. The bound is the rarer contribution, it is checkable
on hardware from counters, it is exactly the kind of claim that survives hostile
review, and it aligns with a demonstrated capability rather than a new one.

---

## FOURTH REVISION, 2026-08-23: CANDIDATE A FALLS BELOW THE GATE

The full venue proceedings sweep (docs/research/venue_proceedings_sweep.md,
~2,300 papers) found every TRIPLE of the four elements occupied by
peer-reviewed work:

- (a)+(b)+(c): EARTH (ASPLOS 2026), Token-Picker (DAC 2024), SpeCache (ICML
  2025), SliceMoE (DAC 2026), FATE (preprint)
- (a)+(d): ECHO (OSDI 2026), which is precisely the "lead with the bound"
  reframing I recommended one step earlier
- (c)+(d partial): DecDEC (OSDI 2025), BitSpec (ASPLOS 2025)

Also: MoE-APEX (ASPLOS 2026) IS HOBBIT published, so the nearest neighbour is
now peer-reviewed rather than a preprint.

**Novelty 17 to 13 of 30. Candidate A total 80 to 76. BELOW the gate of 80.**

Per the kill criteria agreed in advance, this must be reported rather than
argued around.

## What is genuinely left

1. All four elements together. Still unoccupied.
2. **A proved bandwidth amplification factor.** Across the whole sweep, ECHO's
   context-proportional counter is the only enforced cap on speculative traffic,
   and it is an engineering guardrail. No paper anywhere states "bounded
   bandwidth amplification" or "at most Nx traffic". Our 1.25x is derived from
   the representation ratio and asserted at runtime as invariant 8, which is a
   different kind of object from a counter.

## THREE HONEST OPTIONS, for John's decision

**Option A: proceed, repositioned as an evidence and verification contribution
rather than an architecture contribution.** The architectural novelty is thin
and the trade study says so. But two things remain genuinely unoccupied and both
play to demonstrated strength rather than invention:

- a PROVED, runtime-asserted bandwidth amplification bound, where no published
  work has one
- ILA-grade hardware evidence, where the edge-FPGA survey found that NOT ONE
  paper in the field shows a board photo, an external power-meter trace, or a
  hardware-in-the-loop capture

That is a formal-methods-plus-silicon-evidence contribution, which is exactly
what the FabricGuard, RetryGuard and LinkGuard work already demonstrates. The
claim becomes: the first hardware implementation of confidence-gated precision
fetch with a proved traffic bound, verified in simulation and on silicon with
published ILA captures. Weaker as architecture, stronger as evidence, and
honest.

**Option B: pivot to the unoccupied KV-cache-manager-in-fabric gap.** The
edge-FPGA survey found nobody has built a real KV cache manager in Zynq
UltraScale+ fabric: TeLLMe v2 has only address ports, Hummingbird and DATE'25
manage KV in software, and the detailed KV hardware (Titanus, HiKV) is all ASIC
and all simulated. That is a wider gap than the one we have been chasing.

**Option C: stop.** The kill criteria permit it and nothing has been built yet,
which is precisely why the gates ran first.

RECOMMENDATION: Option A, with Option B folded in. Build the KV page manager in
fabric, which nobody has done on this class of part, and make its distinguishing
property the proved traffic bound with ILA evidence. That combines the two
genuinely open gaps and neither of them requires out-inventing ASPLOS.
