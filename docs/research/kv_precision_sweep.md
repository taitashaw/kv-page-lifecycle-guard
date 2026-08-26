# BLOCKING sweep: KV-cache prefetch combined with precision selection

Run 2026-08-23 to close red team attack 5. This is the neighbourhood nearest to
the actual claim and the one nobody had swept. Sources fetched directly.

## Part 1: the fourteen arXiv IDs in the brief. ALL FOURTEEN RESOLVE.

| ID | real title |
|---|---|
| 2602.20515 | FAST-Prefill: FPGA Accelerated Sparse Attention for Long Context LLM Prefill |
| 2512.11920 | CXL-SpecKV: A Disaggregated FPGA Speculative KV-Cache for Datacenter LLM Serving |
| 2605.05170 | Design Conductor 2.0: An agent builds a TurboQuant inference accelerator in 80 hours |
| 2508.06526 | PiKV: KV Cache Management System for Mixture of Experts |
| 2607.26475 | DualDecoder: Accelerate Long Context LLM Inference by Predictive Prefetch |
| 2607.02574 | From Tensor Buffer to Distributed Memory Hierarchy: A Survey of KV Cache Management for LLM Serving |
| 2607.08057 | Towards Efficient Large Language Model Serving: A Survey on System-Aware KV Cache Optimization |
| 2603.20586 | MKA: Memory-Keyed Attention for Efficient Long-Context Reasoning |
| 2603.10899 | LookaheadKV: Fast and Accurate KV Cache Eviction by Glimpsing into the Future without Generation |
| 2604.10539 | IceCache: Memory-efficient KV-cache Management for Long-Sequence LLMs |
| 2602.18750 | HillInfer: Efficient Long-Context LLM Inference on the Edge with Hierarchical KV Eviction using SmartSSD |
| 2603.15589 | LEXI: Lossless Exponent Coding for Efficient Inter-Chiplet Communication in Hybrid LLMs |
| 2603.11504 | LongFlow: Efficient KV Cache Compression for Reasoning Models |
| 2502.09921 | A Cost-Effective Near-Storage Processing Solution for Offline Inference of Long-Context LLMs |

Note the brief's labels were approximate in two cases: 2605.05170 is a paper
about an agent building a TurboQuant accelerator, not a VerTQ accelerator paper;
2603.20586 is MKA, not FastMKA. Titles above are authoritative.

## Part 2: the two closest works found, and they are close

### Conf-KV, arXiv 2605.24786
"Confidence-Aware KV Cache Eviction with Mixed-Precision Storage for
Long-Horizon LLM Inference"

The title alone contains confidence plus mixed precision, which is the b-to-c
coupling by name. Read in full:

- the confidence is the MODEL'S OWN uncertainty, "converts the next-token
  distribution into a scalar confidence score"
- it uses that confidence to choose the PER-STEP CACHE BUDGET, retaining more
  context when uncertain and pruning when confident
- it separately uses "mixed FP16/INT8 storage"
- no calibration method is stated
- NO prefetching and no prediction of future data need
- no fallback path
- software, GPU

**Assessment: this is the closest published work to the claim and it does not
anticipate it.** Its confidence is about the model's next-token distribution,
not about a prediction of which data will be needed. It gates a BUDGET, not a
representation, and the mixed precision is a separate storage decision. There is
no prefetch and no recovery path. But the phrase "confidence-aware" plus
"mixed-precision" in one title is close enough that it must be cited in the
first paragraph of related work and distinguished explicitly.

### Don't Waste Bits!, arXiv 2604.04722
"Adaptive KV-Cache Quantization for Lightweight On-Device LLMs"

- a compact learned controller takes token frequency, quality score, attention
  variance and entropy-based uncertainty
- it "dynamically selects KV precision from {2-bit, 4-bit, 8-bit, FP16} during
  decoding"
- this is a RUNTIME SCORE SELECTING PRECISION, which is element (c)
- but it scores EXISTING tokens; there is no prediction of future need, so no
  element (a)
- no confidence calibration, no fallback
- target is mobile and edge, evaluated on SmolLM-135M/360M/1.7B

**Assessment: owns element (c) in the KV domain, as HOBBIT does in the MoE
domain.** Must be cited alongside HOBBIT as the pair that jointly establish
"runtime score selects precision" as known art.

## Part 3: the two prediction papers, checked for the coupling

- **DualDecoder (2607.26475)** predicts "critical KV entries required for
  decoding the next token" from a speculated token and prefetches them from host
  memory, up to 2.62x decoding throughput. NO confidence, NO representation
  selection, NO fallback. Software, GPU. **This is the strongest published
  predictive KV prefetcher and it is representation-blind.**
- **LookaheadKV (2603.10899)** predicts importance scores with parameter-
  efficient modules to improve eviction. No confidence, no precision selection,
  no fallback. Software.
- **PiKV (2508.06526)** is distributed KV serving for MoE with expert-sharded
  storage and compression modules. No prediction, no confidence-driven
  precision. Software library.

## VERDICT ON RED TEAM ATTACK 5

The sweep found no anticipating reference, but it materially changes the
novelty picture and the framing.

**What is now known art, and must be cited as such:**
1. runtime score selects KV precision: Don't Waste Bits (2604.04722), and
   HOBBIT (2411.01433) in the MoE domain
2. model confidence drives KV cache policy: Conf-KV (2605.24786)
3. predictive KV prefetch: DualDecoder (2607.26475)

**What remains unclaimed:** confidence in a PREDICTION ABOUT FUTURE DATA NEED
selecting the representation of the data that is FETCHED, with a bounded exact
recovery path. Each of the three ingredients now has a clear owner. The
combination does not.

**Novelty score revised: 25 of 30 becomes 21 of 30.** Candidate A's total falls
from 88 to 84. Still above the 80 gate, so the selection stands, but the margin
is thinner and the related-work section now has three papers it must
distinguish rather than one.

**Attack 5 is CLOSED. The boundary is accepted for RTL, with these conditions:**
- Conf-KV, Don't Waste Bits and DualDecoder are cited in the first paragraph of
  related work with explicit distinctions
- no public claim uses the phrase "first" or "nobody has done this" about
  confidence-driven precision, which is now demonstrably prior art
- the claim is narrowed in writing to the coupling plus the bound, which is
  what actually survives
