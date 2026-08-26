# Full venue proceedings sweep: the frontier is more occupied than believed

Roughly 2,300 papers enumerated across ISCA, MICRO, ASPLOS, HPCA, FPGA, FCCM,
FPL, DAC, MLSys, OSDI, ATC, SOSP, EuroSys, NeurIPS and ICML for 2024 to 2026.
Nothing here is inferred from a title; every mechanism quoted was read from an
abstract or an extracted PDF.

## The headline: no paper has all four, but EVERY TRIPLE IS NOW OCCUPIED

| work | venue | a predict | b confidence | c representation | d bound |
|---|---|---|---|---|---|
| **EARTH** | **ASPLOS 2026** | YES | partial | **YES** | NO |
| **Token-Picker** | **DAC 2024** | YES | **YES, provable** | **YES** | partial |
| **SpeCache** | **ICML 2025** | YES | YES | YES | partial |
| **SliceMoE** | **DAC 2026** | partial | YES | YES | partial |
| **FATE** | preprint | YES | **YES, explicit** | **YES** | NO |
| **ECHO** | **OSDI 2026** | YES | partial | NO | **YES, both halves** |
| DecDEC | OSDI 2025 | NO | NO | YES | partial |
| BitSpec | ASPLOS 2025 | NO | NO | YES for compute | YES on exactness |

The frontier splits three ways and each split is held by peer-reviewed work:
EARTH, Token-Picker, SpeCache, SliceMoE and FATE own **(a)+(b)+(c)** with no
bound. ECHO owns **(a)+(d)** with no precision axis. DecDEC owns
**(c)+(d partial)** with no prediction.

## The three that hurt most

**EARTH, ASPLOS 2026, DOI 10.1145/3779212.3790155.** A dual-entropy encoding
decomposes each expert into a high-information base and a delta component,
"enabling compact storage while preserving accuracy via adaptive precision
management", and a delta-aware speculative prefetcher "preloads base components
of predicted experts and selectively fetches deltas". That is a hardware
accelerator speculatively fetching a CHEAP REPRESENTATION of predicted experts
and escalating only where it matters. It is the closest published work to CGPF.

**Token-Picker, DAC 2024, DOI 10.1145/3649329.3655953.** K vectors stored as
three 4-bit chunks. After loading only chunk 1, hardware computes a partial
score and a PROVABLE upper bound on the attention probability. If the bound
falls below threshold the remaining chunks and the V vector are never fetched;
otherwise the next chunk is requested. This is the only paper found where a
certainty estimate literally selects HOW MANY BITS GET FETCHED, and its
certainty is stronger than ours: a one-sided proof rather than a calibrated
heuristic. It states no worst-case traffic bound; the agent grepped for "worst",
"at most", "amplif" and "guarantee" and found only accuracy claims.

**ECHO, OSDI 2026.** This is the one that takes the reframing I recommended.
Verbatim from its PDF: "Both prefetching operations in ECHO are lossless, with
guaranteed recall that preserves model accuracy", and "we set an upper bound on
the number of prefetched tokens and enforce it using a global counter... The
maximum number is proportional to context length". So exact fallback AND an
enforced cap on speculative traffic, at a top systems venue, this year.

## What genuinely remains unoccupied

1. **All four together.** No paper satisfies (a)+(b)+(c)+(d).
2. **A PROVED bandwidth amplification factor.** The agent's finding, stated
   plainly: across roughly 2,300 enumerated papers, ECHO's context-proportional
   counter is the only ENFORCED cap on speculative traffic, and even that is an
   engineering guardrail rather than a proved bound. **No paper anywhere says
   "bounded bandwidth amplification" or "at most Nx traffic".**
3. **Confidence-selects-precision in classical value prediction remains
   RFVP-only.** HPCA 2025 "Architecting Value Prediction around In-Order
   Execution" and ISCA 2024 "Constable" use confidence to gate WHETHER to
   speculate, never WHAT PRECISION to return.

## Correction to my own record

**MoE-APEX, ASPLOS 2026, DOI 10.1145/3779212.3790187, IS HOBBIT published.**
Identical author list (Tang, Liu, Hou, Pu, Wang, Heng, Li, Guo) and the same
core claim about replacing less critical cache-miss experts with low-precision
variants. I had been treating HOBBIT as a preprint-only threat with 52
citations. It now has a peer-reviewed ASPLOS venue and must be treated
accordingly.

Also recorded: the ASPLOS 2026 program page summariser merged EARTH and
MoE-APEX into a chimera paper that does not exist. They have separate DOIs and
page ranges. Anyone reading that program page uncritically will cite a
non-existent paper.

## Verified to exist, mechanism not yet readable

- **STEP, ISCA 2026**, same SJTU group as EARTH: adaptive spatio-temporal expert
  prefetching. Confirmed from the time-slotted ISCA 2026 program and the
  author's homepage. No abstract publicly available yet. It is NOT the ST-MoE
  arXiv already recorded; different authors entirely.
- **ELMoE-3D** (arXiv 2604.14626, same KAIST group as SliceMoE) couples expert
  selection with bit-width via an LSB-augmented bit-sliced cache. Needs a
  dedicated check before any multi-representation claim.
- Three EuroSys papers whose abstracts were unreachable.

## Access note

dl.acm.org returns Cloudflare 403 to every request from this environment,
including for Gold open-access papers. IEEE Xplore returns empty JS bodies. For
ACM-only and IEEE-only papers, title, DOI, authors and page ranges were verified
on DBLP and abstracts read via the DOI record.

---

## STEP (ISCA 2026) RESOLVED: abstract read, and it does NOT occupy criterion (c)

**STEP: Adaptive Spatio-Temporal Expert Prefetching for Low-Latency and
Memory-Efficient MoE Inference.** ISCA 2026, Raleigh NC, pages 1336 to 1350,
DOI **10.1109/ISCA66397.2026.00101**. Thirteen authors: Fangxin Liu, Ning Yang,
Zongwu Wang, Chenyang Guan, Haomin Li, Yu Feng, Li Jiang, Haibing Guan (SJTU),
Liqiang Lu (Zhejiang), and Xiang Li, Siran Yang, Jiamang Wang, Lin Qu (Alibaba).
No arXiv copy; Unpaywall reports `oa_status: closed` with no OA copy anywhere.

Abstract obtained from the Semantic Scholar Graph API, fetched twice in separate
calls and byte-identical both times (1292 chars). Crossref, OpenAlex and
Unpaywall all carry the record but with no abstract field; IEEE Xplore is
blocked from this environment.

The three mechanisms, verbatim:
- "layer-wise expert allocation to dynamically adjust **the number of activated
  experts** based on computational importance, reducing unnecessary computation
  and memory traffic"
- "a **predictive expert prefetching** mechanism that leverages temporal locality
  and layer-specific predictability patterns to minimize access latency"
- "a **token-aware adaptive window** mechanism [that] further enhances prefetch
  accuracy"

Result: up to 3.12x speedup.

### Verdict against the four criteria

| criterion | verdict | why |
|---|---|---|
| (a) predict | **YES** | explicit predictive expert prefetching |
| (b) confidence | **PARTIAL** | "layer-specific predictability" and an adaptive window size are confidence-shaped, but nothing indicates statistical calibration |
| (c) representation | **NO** | STEP varies the NUMBER of experts, never their precision. No bit-width, quantization or precision language anywhere in the abstract |
| (d) bound | **NO** | no worst-case traffic language |

**This is the first genuinely non-threatening result of the whole sweep.** STEP
adapts prefetch aggressiveness to predictability, which is
confidence-gates-QUANTITY. CGPF is confidence-gates-PRECISION. Different axis.

But it does further wall off the quantity axis, and a reviewer will say so:
STEP now owns confidence-sized prefetch COUNT and ECHO owns a bound on prefetch
COUNT. Anything framed as "adapt how much we speculatively fetch" is now firmly
occupied at ISCA and OSDI. Only the precision axis and the proved amplification
factor remain, and the precision axis is where EARTH, Token-Picker and FATE sit.

STEP cites EARTH (Crossref ref29 = 10.1145/3779212.3790155) and shares six
authors and the same NSFC grant 62402311. Same group, adjacent papers.

### EARTH title verified in full

**EARTH: An Efficient MoE Accelerator with Entropy-Aware Speculative Prefetch and
Result Reuse.** ASPLOS '26 Volume 2, Pittsburgh, pages 633 to 646, published
2026-03-22, DOI 10.1145/3779212.3790155. Eight authors (Fangxin Liu, Ning Yang,
Jingkui Yang, Zongwu Wang, Chenyang Guan, Yu Feng, Li Jiang, Haibing Guan).
Crossref carries no abstract for this DOI.

### TWO NAME COLLISIONS, both capable of corrupting a citation

1. **There are two different papers called STEP at ISCA 2026.** The other is
   "STEP: Spatial Footprint Prefetcher with Multi-Point Temporal Triggers",
   DOI 10.1109/ISCA66397.2026.00095, Ye / Lenke / Wild / Herkersdorf (TU Munich),
   session 5D. It is a cache prefetcher with nothing to do with MoE. A keyword
   search returns it first.
2. **ST-MoE is not STEP.** "A Spatio-Temporal Expert Prefetching Framework for
   Efficient MoE-based LLM Inference", arXiv 2606.15453, Zhao / Bunescu / Louri /
   Karanth / Wang, is a different group's CoRR preprint on the same idea. It is
   genuine independent concurrent prior art and was already on record. It must
   not be merged with the ISCA paper.

### Chimera check passed

STEP is corroborated by five independent machine-readable sources agreeing on
title and authors: a resolvable IEEE DOI, the Crossref deposit with page range
and 54 references, OpenAlex, Unpaywall, and Semantic Scholar, plus the official
iscaconf.org program page listing it verbatim with its session slot. DBLP does
NOT list it, but DBLP has not indexed ISCA 2026 at all (db/conf/isca/isca2026
returns 404), so absence there is not evidence against.

---

## ELMoE-3D RESOLVED: low threat, and two corrections to my own record

**ELMoE-3D: Leveraging Intrinsic Elasticity of MoE for Hybrid-Bonding-Enabled
Self-Speculative Decoding in On-Premises Serving.** arXiv 2604.14626 v2
(2026-04-23), 11 pages. Full HTML render AND PDF both obtained; text extracted
two independent ways (pdftotext -layout, and an HTML pass preserving LaTeX
alttext so Algorithm 1 survived intact). The keyword audit was run over both
extractions and the counts were IDENTICAL, so the negative below is not an
extraction artifact.

**Verdict: (a) YES, (b) NO, (c) PARTIAL, (d) NO. LOW threat.**

### (d) is a definitive zero

Counted over the full text, twice, by two extractors:

| string | count |
|---|---|
| "at most" | 0 |
| "upper bound" | 0 |
| "amplif" | 0 |
| "guarantee" | 0 |
| "provab" / "we prove" / "theorem" / "lemma" | 0 |
| "invariant" / "assert" | 0 |

The two "worst case" hits are a latency timeline figure and a description of a
BASELINE's footprint, not a bound of their own. All nine "bound" hits are
"memory-bound", "compute-bound", a quantization-accuracy floor, or one latency
design goal. No bytes bound, no amplification factor, no runtime assertion.

### (b) is zero: no calibrated certainty of any kind

Hotness is a raw accumulated one-hot count. The speculative/autoregressive gate
is a raw batch-size threshold tau. The cache is plain LRU. The only occurrence
of "calibrated" in the paper describes an EVALUATION model, not a runtime
signal, and the sibling quantization scheme is advertised as "calibration-free".

### (c) is PARTIAL, and the two readings genuinely differ

Read literally, it is a YES: hotness sets cache membership, and membership
decides whether an expert costs 4 bits or 8 bits of external traffic
(Algorithm 1 lines 4 and 23-28).

Read as CGPF criterion (c) is actually defined, it is closer to a NO. **The
verify phase unconditionally reassembles the exact 8-bit weight for every
activated expert.** The compact 4-bit representation is only ever read from
hybrid-bonded memory and never from DRAM, and precision is selected by PHASE
(draft versus verify), not by any score. No score is ever permitted to skip the
exact fetch.

**So there is no compact-versus-exact fetch decision in ELMoE-3D for a
confidence to gate.** The popularity-to-bit-count link is real but is a side
effect of bit-sliced tiered caching, not a precision-fetch policy. CGPF's
(b)+(d) pairing is untouched by this paper.

### CORRECTION 1: SliceMoE is NOT a DAC 2026 paper

My record listed "SliceMoE (DAC 2026)" among the works occupying
(a)+(b)+(c). **DBLP shows it as CoRR 2025 only, arXiv 2512.12990, with no
conference venue attached.** ELMoE-3D is likewise CoRR 2026 with no venue.
Both must be weighed as **preprints**, not as peer-reviewed occupancy. That
materially weakens the claim that the (a)+(b)+(c) triple is peer-reviewed:
EARTH (ASPLOS 2026), Token-Picker (DAC 2024) and SpeCache (ICML 2025) still
hold it, but SliceMoE and FATE do not add peer-reviewed weight.

### CORRECTION 2: two unrelated papers are called SliceMoE

1. **SliceMoE: Routing Embedding Slices Instead of Tokens**, EMNLP 2025, DOI
   10.18653/V1/2025.EMNLP-MAIN.807, arXiv 2510.04286. An ML architecture paper.
   NOT relevant and not the KAIST work.
2. **SliceMoE: Bit-Sliced Expert Caching under Miss-Rate Constraints**, arXiv
   2512.12990, Choi / Kim / Oh / Park / Kim / Yoo (KAIST). The relevant one.

Do not conflate them in any later sweep.

### Same-work check: NEGATIVE, this is not another HOBBIT/MoE-APEX

ELMoE-3D **cites SliceMoE as reference [7] and criticises it** in section 4.3
for the zero-point metadata overhead of asymmetric quantization. A paper cannot
cite and critique itself as prior work. Same KAIST group, two distinct papers.

### OPEN: SliceMoE full text was never read, and it is the stronger threat

Its abstract says **"caches experts at slice-level granularity and assigns
precision on demand"**, which is a more direct hit on criterion (c) than
anything in ELMoE-3D, plus "Predictive Cache Warmup" for (a). Against that, it
says "Calibration-Free" in the name of its own quantization scheme, and
"miss-rate constraints" constrains a MISS RATE rather than bytes moved, so (b)
and (d) look unlikely even on a full read. All four criteria stay UNKNOWN until
the mechanism is read. Promoted to a dedicated read.

---

## SliceMoE RESOLVED: closest encroachment on leg (c), and it retires one of my framings

**SliceMoE: Bit-Sliced Expert Caching under Miss-Rate Constraints for Efficient
MoE Inference.** arXiv 2512.12990, current version **v4** (2 Apr 2026), 9 pages,
Choi / Kim / Oh / Park / Kim / Yoo (KAIST).

Read exhaustively: PDF extracted three ways (pdftotext, pdftotext -layout, mutool
draw -F txt) plus HTML v1 through v4 through an independent regex path. Version
deltas are cosmetic; the section 4.1 DBSC mechanism paragraph is byte-identical
across v3 and v4. Figures read as images because the fetch semantics are only
fully settled there.

**Verdict: (a) PARTIAL weak, (b) NO, (c) PARTIAL and the closest leg by far,
(d) NO.**

### The finding that matters: SliceMoE IS permitted to skip the exact fetch

Verbatim from section 4.1:

> "critical experts request both MSB and LSB slices, while non-critical experts
> require only the MSB slice; each slice produces separate hit/miss outcomes.
> Full precision is reconstructed when both slices are cached, and **MSB-only
> computation is used otherwise**."

> "we employ a mixed-precision strategy where experts use either high-bit or
> low-bit representations depending on their **gating scores**."

A non-critical expert never issues an LSB request, so it never produces an LSB
miss, and misses are what trigger transfers ("cache misses trigger Flash-to-DRAM
transfers"). So the score genuinely gates traffic, and the system genuinely
proceeds on the compact form alone.

**This retires the framing I used in the ELMoE-3D entry.** I wrote there that
prior work "always eventually reassembles the exact weight" and that no
compact-versus-exact fetch decision existed for a confidence to gate. That is
true of ELMoE-3D and FALSE of SliceMoE. It must not be repeated.

### What SliceMoE still does not do

- **The tier is wrong.** Its interface is **Flash to DRAM**: DRAM (8 GB LPDDR4)
  is the cache and UFS 3.1 Flash is the backing store. CGPF's leg (c) is at the
  DRAM-to-on-chip boundary. Analogous tier, not the same one.
- **(b) is untouched.** The deciding variable is a bare gating score against a
  fixed threshold of about 0.1 (Fig. 4 marker reads "threshold (e.g. 0.1)").
  Cross-checked absences over both extractions: `confidence` 0, `uncertain` 0,
  `temperature scaling` 0, `Platt` 0, `isotonic` 0, `conformal` 0,
  `expected calibration` 0, `posterior` 0, `Bayes` 0. "Calibration-free" refers
  only to the absence of a quantization calibration dataset, exactly as
  anticipated.
- **(a) is not merely unclaimed, it is DISCLAIMED.** Predictive Cache Warmup is a
  one-shot prefill-time eviction-and-reordering keyed on accumulated past access
  counts. The paper argues against prediction: "Predictive schemes such as
  prefetching and speculative caching ... become increasingly unreliable in
  modern MoE."
- **(d) is empty.** Counts agree exactly across five extractions: "at most" 0,
  "upper bound" 0, "worst case" 0, "worst-case" 0, "amplif" 0, "guarantee" 0,
  "provab" 0, "theorem" 0, "lemma" 0, "invariant" 0, "assert" 0. The whole paper
  contains **one** instance of "bound", and it is "truncated **boundaries**" in a
  quantization-clipping sentence. No pseudocode anywhere. The nearest thing to a
  bound is explicitly average-case: "the resulting ratio of experts that retain
  their MSB slices remains below one **on average**".

### VENUE: correcting my own correction

I previously recorded the DAC 2026 attribution as unconfirmed. More precisely:
**it is author-supplied and unadjudicable.** The arXiv abstract page Comments
field reads verbatim "Design Automation Conference (DAC) 2026", so it was not
invented by a summariser. DBLP lists the paper as CoRR 2025 only and has **no
dac2026 entry at all**, its most recent DAC proceedings being 2025, so DBLP's
silence is not evidence of rejection. Status: neither confirmed nor refuted.
Treat as a preprint with an author-claimed venue.

### EVALUATION METHODOLOGY: the paper never states one

This matters for our own positioning. Verified zero in both extractions: `fpga`
0, `asic` 0, `gpu` 0, `simulat` 0, `measur` 0, `estimat` 0, `rtl` 0, `verilog`
0, `synthes` 0, `cacti` 0, `gem5` 0, `ramulator` 0, `dramsim` 0, `tapeout` 0.

The "XPU" is a parameter sheet (1 GHz, 8,192 INT8 PEs, 16.4 TOPS). Energy figures
trace to a Micron DRAM Power Calculator and a Kingston UFS datasheet. Accuracy
numbers on DeepSeek-V2-Lite and Qwen1.5-MoE-A2.7B are genuine model evaluation;
**energy and latency are analytically modelled, not measured, and the paper does
not say so.** There is also an internal inconsistency: section 5 says UFS 128 GB
at 10 Gbps and DRAM at 104 Gbps, while Fig. 7 says UFS 256 GB at 1.75 GB/s and
16 GB/s for DRAM.

This is direct support for the artifact-and-evidence positioning in
DECISION_001: the closest work on our sharpest leg reports no hardware, no
simulator, and no methodology statement at all.
