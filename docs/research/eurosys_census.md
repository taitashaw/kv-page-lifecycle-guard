# EuroSys 2025 and 2026 full census: 223 papers, 50 abstracts read, 7 mechanisms read

Enumerated from DBLP conference TOC pages, never from dl.acm.org, which returns
HTTP 403 to this environment on every request including Gold OA CC-BY articles.

- EuroSys 2025: 85 papers, DOI prefix 10.1145/3689031
- EuroSys 2026: 138 papers, DOI prefix 10.1145/3767295
- 223 total, cross-checked against the DBLP publication API (stream conf/eurosys)

Screening was on title AND abstract, not title alone. Abstracts bulk-fetched
from OpenAlex with Semantic Scholar as fallback. 8 of 223 yielded no abstract
from any source; none is LLM, KV, MoE or precision related by title, so the
screen is sound despite the gap. 50 abstracts read in full, 42 excluded for
touching zero or one criterion, 8 reported below.

## HEADLINE: no EuroSys paper combines all four. None combines even (b)+(c).

| paper | year | a | b | c | d | note |
|---|---|---|---|---|---|---|
| **FineMoE** | 2026 | YES | PARTIAL | NO | PARTIAL | confidence-shaped expert prefetch |
| **LLMFolder / TARDIS** | 2026 | PARTIAL | PARTIAL | **YES** | NO | 2-bit copy gates exact access |
| Prism | 2026 | PARTIAL | PARTIAL | NO | PARTIAL | auto-calibrated threshold + "at most N" |
| Flux | 2026 | YES | PARTIAL | PARTIAL | NO | federated fine-tuning, not inference |
| AdaServe | 2026 | PARTIAL | PARTIAL | NO | PARTIAL | Theorem 4.1 + hard node budget |
| CacheBlend | 2025 | PARTIAL | NO | PARTIAL | NO | KV reuse vs recompute |
| SAS | 2026 | PARTIAL | UNK | UNK | PARTIAL | **NOT READABLE, see below** |
| TierScape | 2026 | PARTIAL | NO | PARTIAL | NO | multi-tier lossless compression |

## The two that erode the claim

**FineMoE (EuroSys 2026, 10.1145/3767295.3769319)** already does
confidence-shaped expert prefetch with an adaptive threshold: "we assign a
higher [threshold] to low-score expert maps so that more experts are prefetched
to mitigate mispredictions and assign a lower [threshold] for high-score expert
maps to reduce the memory footprint." So predict-plus-confidence is not novel on
its own. It moves whole homogeneous experts, so it cannot reach (c) at all, and
its constraints cap GPU footprint with an explicitly unbounded miss path:
"Whenever an expert miss occurs, FineMoE pauses all expert prefetching tasks and
immediately loads missed experts from CPU to GPU memory."

**LLMFolder (EuroSys 2026, 10.1145/3767295.3769339)**, read via its preprint
TARDIS arXiv 2501.10054 with an identical author set, is the strongest (c) hit
in either year. It creates "a compressed version of the weight matrix, which
contains just enough information to make these predictions without the overhead
of full matrix operations", obtained "by GPTQ with 2-bit precision", and stores
"only the original weights of neurons that require exact computation". That is
structurally compact-first, exact-on-demand. So that move is not novel on its
own either. It operates on FFN weights rather than KV pages, has no calibrated
confidence, and states no worst-case bound anywhere.

## Useful contrast material: a published system that ADMITS its scheme costs bandwidth

**FlexiQ (EuroSys 2026, 10.1145/3767295.3769351)**, excluded because (a)(b)(d)
are all absent, is worth quoting in our own write-up. It selects representation
at runtime, but its selector is request rate rather than confidence, and it
states plainly: "Since FlexiQ stores 8-bit model parameters to support dynamic
4-bit ratios, its memory footprint is equivalent to that of 8-bit models...
Because FlexiQ performs bit extraction at runtime, it incurs **higher bandwidth
usage** than uniform 4-bit quantization."

That is a peer-reviewed system conceding exactly the failure mode our bound
exists to rule out. It is the best available motivation for stating a bound at
all, and it should be cited as such rather than as prior art.

## Element (d) remains unclaimed at this venue

No EuroSys paper in either year states a proved, runtime-asserted worst-case
bound on bytes moved derived from a representation size ratio. The bounds that
do exist are elsewhere in the stack: AdaServe caps token-tree nodes, Prism
enforces "at most two layers' weights" and "at most three chunks" resident, and
TierScape has none. Proved-plus-enforced exists; proved-plus-enforced ON BYTES
does not.

## ONE UNRESOLVED ITEM, and the pivot makes it MORE important

**SAS: Sparse Attention Synthesizer for Efficient Language Model Inference**,
EuroSys 2026, DOI 10.1145/3767295.3769364. Gold OA per Semantic Scholar, but the
only PDF URL is dl.acm.org, which 403s here, and no preprint exists under any
title. Its abstract contains the single clause in 223 papers that resembles a
derived KV size bound: "a geometric-based pattern analyzer to optimize for KV
caching by **determining minimal cache sizes** and automatically generating cache
management functions."

On the abstract this is footprint analysis, not a traffic bound. But it is a KV
paper, and the pivot to a KV page manager moves it from peripheral to on-lane.
**The novelty claim on (d) should not be published until the SAS camera-ready is
read through a route with ACM access.** Recorded as an open item rather than
resolved by assumption.

## Two exclusions flagged so they stay auditable

- **eLLM / "High Throughput and Low Latency LLM Serving via Adaptive KV
  Caching"** (10.1145/3767295.3803570) touches only (c) PARTIAL and its
  mechanism is NOT READABLE. The arXiv paper named eLLM (2506.15155) describes a
  different mechanism and was not treated as the same work. If any single
  exclusion should be revisited, it is this one, and the pivot makes it KV-lane.
- **MFS, AIMS and TailorLLM** all route between a small and a large model, but
  none gives evidence of a confidence gate or a bound in its abstract, and none
  is readable. Inference was refused rather than guessed.
