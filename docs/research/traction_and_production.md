# Traction: verified citations and what actually ships

Citation data from the Semantic Scholar Graph API, fetched 2026-08-23. Peer
review status independently corroborated via the arXiv API.

## Verified citation counts

| paper | venue | peer reviewed | citations | influential |
|---|---|---|---|---|
| KVQuant 2401.18079 | NeurIPS | yes | **644** | 66 |
| InfiniGen 2406.19707 | USENIX OSDI | yes | **309** | 37 |
| Pre-gated MoE 2308.12066 | ISCA | yes | 145 | 13 |
| No Token Left Behind 2402.18096 | none | **preprint only** | 100 | 2 |
| AdapMoE 2408.10284 | ICCAD | yes | 60 | 8 |
| **HOBBIT 2411.01433** | none | **PREPRINT ONLY** | 52 | 8 |
| KVTuner 2502.04420 | ICML | yes | 37 | 3 |
| Klotski 2502.06888 | ASPLOS | yes | 31 | 2 |
| SpeCache 2503.16163 | ICML | yes | 9 | 1 |
| MoE-SpeQ 2511.14102 | none | preprint only | 9 | 0 |
| BuddyMoE 2511.10054 | none | preprint only | 4 | 0 |
| MoBiLE 2510.12357 | ASP-DAC | yes | 2 | 0 |

Note on HOBBIT, which the red team treated as a primary threat: it is
**preprint only, 52 citations**. It remains prior art and must still be
distinguished, but it is not a peer-reviewed anchor.

## THE PRODUCTION FINDING THAT CHANGES THE FRAMING

### Mixed-precision KV storage: SHIPPED, broadly, and we must not claim it

- **vLLM** `CacheDType` accepts 17 values including `turboquant_k8v4`, which is
  literally **asymmetric K/V precision** with K at FP8-E4M3 and V at 4-bit, plus
  `turboquant_k3v4_nc`, `int4_per_token_head`, `nvfp4`. Merged via PR 38479 on
  2026-04-15 with 13 merged TurboQuant PRs since and live user bug reports. It
  also ships `kv_cache_dtype_skip_layers`, which is per-layer mixed precision,
  the KVTuner idea.
- **SGLang** `--kv-cache-dtype` accepts fp8_e5m2, fp8_e4m3, mxfp8, bf16, nvfp4,
  fp4_mx_block16.
- **TensorRT-LLM** ships KvCacheConfig dtype fp8 and nvfp4.
- **llama.cpp** has had `-ctk` and `-ctv` settable INDEPENDENTLY since long
  before any of these papers, which is mixed-precision KV in production.

Element (c) is therefore not merely published, it is DEPLOYED. Any novelty
claim on representation selection alone is dead on arrival.

Attribution note worth knowing: vLLM PR 40194 credits HIGGS (2411.17525) and
"Cache Me If You Must" (2501.19392) as prior art, NOT KVQuant, and states that
the TurboQuant paper's JL improvements "were not found to be practically
impactful."

### Predictive KV prefetch: ZERO production footprint. This is the gap.

- **vLLM** has a kv_offload module, but the only InfiniGen reference is an
  OPEN, UNMERGED RFC (issue 33980) where a contributor asks maintainers whether
  they would accept a PR.
- **SGLang** HiCache prefetch is NOT predictive. `prefetch_from_storage()`
  builds a RadixKey from tokens ALREADY IN THE REQUEST and does an exact
  prefix-hash lookup. Its policies control only when to stop waiting, never
  what to guess.
- InfiniGen: 0 hits in SGLang, TensorRT-LLM or llama.cpp. HOBBIT: 0 real hits
  anywhere.

**InfiniGen has 309 citations at OSDI and zero deployments.** That is a
research-to-practice gap, and it is the strongest available framing for this
project.

### Expert prefetching: shipped, but fixed-schedule, not confidence-gated

vLLM PR 29941 merged 2026-02-26 adds `OffloadConfig(offload_backend="prefetch")`
with `offload_prefetch_step`, targeting MoE weights. It is a **fixed
layer-lookahead schedule**, and its stated lineage is an SGLang blog post, not
the academic MoE literature. TensorRT-LLM PR 6272 for MoE weight prefetching was
closed unmerged. llama.cpp's `--n-cpu-moe` is static placement; every dynamic
variant is unmerged.

So the production world prefetches on a FIXED SCHEDULE. Nobody gates it on
confidence, which is precisely what CGPF adds.

### NVIDIA ships its own research, not this literature

TriAttention merged 2026-08-04, described in-PR as "NVIDIA work at ICML 2026".
Their tiered mixed-precision KV work follows TriAttention, not HOBBIT or
Cocktail.

## Consequences for our claim

1. **Drop any novelty on representation selection.** It is in production in four
   frameworks. Cite vLLM's `turboquant_k8v4` explicitly as deployed prior art.
2. **The reframing is stronger than the original claim.** Predictive prefetch has
   309 citations at a top venue and zero production deployments. Production
   prefetch is fixed-schedule. The contribution becomes: a hardware mechanism
   that makes predictive prefetch deployable by bounding its worst case, which
   is exactly the property a production maintainer would demand before merging
   an unbounded speculative mechanism.
3. **That reframing is testable on our board.** The bound is invariant 8 in
   SPEC.md, asserted in RTL and checkable from counters.

## Method caveat, stated plainly

Industry citation analysis is largely UNVERIFIABLE by the method attempted. The
S2 citations endpoint rejects nested author fields; a workaround via the batch
endpoint pulled 3,759 citing-author records across 10 papers, but **only 71,
that is 1.9 percent, carry any affiliation string at all**. Two hits surfaced:
Apple citing InfiniGen, and Microsoft Research Asia citing KVTuner. At 1.9
percent coverage, absence of hits is NOT evidence of absence, and the zeros must
not be read as absence of industry interest.

One clean fully verified industry link: Google's TurboQuant (2504.19874, authors
include Vahab Mirrokni, 95 citations) cites both KVQuant and No Token Left
Behind in its reference list, confirmed by pulling all 69 references. Its venue
is UNVERIFIED; a web result claimed ICLR 2026 but arXiv does not confirm it.
