# Deep full-text sweep: what survives and what does not

Run 2026-08-23. Full texts fetched, not abstracts. This sweep materially
narrows the claim and CORRECTS an earlier finding of mine that was wrong.

## CORRECTION TO A PREVIOUS FINDING

The first prior-art sweep recorded: "Zero works in this corpus calibrate a
data-movement predictor." **That is false and must be withdrawn.**

**APEX, arXiv 2608.11688, CODES/ESWEEK 2026, going to IEEE TCAD, peer reviewed.**
Kanani, Badawi, Ogras, University of Wisconsin-Madison. It calibrates a
data-movement predictor with an ordinal-logistic CDF, p_delta(x) =
sigma(theta_delta - w^T x), trained with cumulative binary cross-entropy,
modelling Pr(delta >= delta* | x).

APEX uses that calibrated confidence to set PREFETCH VOLUME: it fetches the top
(k + delta_hat(x)) experts. It never uses it to select a representation. It also
has a correctness-preserving mode where missing experts are fetched on demand
while execution starts on what is available. No numeric worst-case bound.

It was accepted three weeks before this sweep. It is the obvious reviewer
question: "why is your representation selection not a trivial extension of
APEX?"

## The other two that most threaten the claim

**TRACE, arXiv 2509.03377, ASAP7 ASIC with CXL.** Stores multiple precision
ALIASES over the same physical bit planes. The controller "always returns the
sign plane and the most significant exponent/mantissa planes implied by
(r_e, r_m). It does not inspect per-element values to decide which planes to
fetch." Fallback to full precision is exact.

So multi-representation storage with partial fetch and exact recovery is
ALREADY PUBLISHED. What is open is only the DRIVER of the decision: TRACE uses
pointer arithmetic on a static per-allocation config, with no predictor and no
confidence and no bound.

**SpecMD, arXiv 2602.03921, Apple.** This is a NEGATIVE RESULT that lands
directly on the thesis and a reviewer who knows it will treat it as
disconfirming evidence:

- "Fetch Lowest Bit and Drop Priority Cascade show inconsistent results across
  models, offering no clear advantage over simpler strategies."
- "Higher prediction accuracy does not guarantee better cache performance in
  term of speed."
- for Mixtral, "the size of the experts is too large for the available
  bandwidth, which limits the benefit of a dynamic prefetch system."

It also supplies support for our insistence on an EXACT fallback:
- "Substitution Score fails across all configurations, suggesting that replacing
  missing experts with functionally similar alternatives is unreliable,
  regardless of capacity level."

**Our distinction from SpecMD, and it is legitimate but must be argued:** their
negative result is in the MoE expert regime where a single expert is hundreds of
megabytes and dwarfs available bandwidth. CGPF operates on 256-byte KV pages,
a fundamentally different size regime where the transfer granularity is at the
burst sweet spot rather than orders of magnitude above it. That distinction has
to be made explicitly and early, not left for a reviewer to reject.

## What is now OCCUPIED and must not be claimed

| leg | owners |
|---|---|
| (a) predict what data is needed next | APEX, DualDecoder, MoE-SpeQ, DraftExpert, SpeCache, BuddyMoE |
| (b) calibrated confidence on that prediction | **APEX (ordinal-logistic, peer reviewed)**, MoBiLE, DraftExpert |
| (c) runtime score selects representation | TRACE, SliceMoE (DAC 2026), ELMoE-3D, Lynx, VeriCache, SpeCache, HOBBIT, Don't Waste Bits, KVTuner |
| (a)+(b) as a pair | **APEX owns this outright** |
| (a)+(c) as a pair | SpeCache, ELMoE-3D, DyMoE |

## What remains genuinely open

1. **The (b) to (c) coupling.** A PREDICTOR's confidence selecting the
   representation that gets fetched. Not found in any verified work. Every
   mixed-precision fetch decision verified is driven by something else: gating
   or router score, sensitivity, token importance, batch size, static config, or
   fixed stream priority. MoE-SpeQ is the near miss: it literally stores
   (expert_id, confidence_score) from gating logits, then quantizes everything
   uniformly to INT4 and never uses the confidence for precision.
2. **A stated worst-case bound on speculative data movement.** Essentially not
   found. Closest is OasisKV: "admits at most C blocks per KV head per decoding
   step, regardless of how many positions changed", a hard per-step admission
   cap. SP-MoE's expression looks like a bound but the authors describe
   approximating it with profiled timings, so it is a heuristic. A dedicated
   sweep for speculative plus bandwidth plus bound returned zero papers with a
   formal worst-case traffic guarantee.

## Traction: research-only, but watched by people who move fast

Production frameworks implement none of (a) through (d). vLLM ships fp8_e4m3 and
fp8_e5m2 KV cache set once at init via kv_cache_dtype, per-tensor or per-head
scales, with no dynamic per-page precision selection and no speculative KV
prefetch. llama.cpp exposes static -ctk and -ctv KV quantization and static
--n-cpu-moe expert placement, with no predictor.

Industry labs appear as CO-AUTHORS, not adopters: Apple (SpecMD), Huawei (Lynx,
SpeCache), Microsoft Research (VeriCache, OasisKV), Samsung (ELMoE-3D,
VeriCache), Tencent (DyMoE). The problem area is validated and the space is
being watched by organisations that can move faster than we can.

## Peer-reviewed 2026 venues now in this space

DAC 2026 (SliceMoE), ASP-DAC 2026 (MoBiLE), CODES/ESWEEK 2026 and IEEE TCAD
(APEX), PPoPP 2026 (BuddyMoE). The FPGA lane specifically remains thin: an arXiv
sweep for KV cache plus FPGA returned 11 papers, of which only CXL-SpecKV does
speculative KV on FPGA, and its artifact does not reproduce.

## Unverified, flagged

- citation counts: Semantic Scholar returned HTTP 429 on every attempt, no
  numbers estimated
- SpecKV (Galim et al. 2026): seen only cited inside LookaheadKV, no primary
  page fetched
- RICH Prefetcher, MICRO-58 pp.170-183, DOI 10.1145/3725843.3756081: title,
  authors, venue and pages confirmed from the ACM listing, internals UNVERIFIED
  because ACM DL returned 403
- SliceMoE read at v1, current version is v4
- proceedings-only long tail for MICRO, ISCA, ASPLOS, HPCA, FCCM, OSDI, MLSys
  not fully closed
