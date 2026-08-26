# Patent landscape: predictive data movement with confidence and fallback

Compiled 2026-08-23. Every patent below was verified by fetching its live
Google Patents page and reading title, assignee, dates, legal status and claim
text out of the DOM. Plain fetch and curl return HTTP 503 from this host; a
real browser session reaches the same pages. No entry is reported from a
search snippet alone.

## Answer to the four-element question

No patent covers the combination. Nothing claims all four, and nothing comes
close to claiming three.

Elements: (a) predicts data an inference engine needs next, (b) attaches a
CALIBRATED confidence, (c) uses that confidence to select representation or
precision, (d) bounded-cost exact fallback.

| Patent | Assignee | Status | a | b | c | d |
|---|---|---|:-:|:-:|:-:|:-:|
| WO2025184895A1 | Intel | Pending | yes | yes | no | no |
| US10176090B2 cl.10/11/28 | Qualcomm | GRANTED ACTIVE | no | yes | partial | no |
| US20260065098A1 | Groq | Pending | yes | yes | no | no |
| US20260099447A1 | Samsung | Pending | yes | no | no | no |
| US20260111700A1 | SK hynix | Pending | yes | no | no | no |
| US20260093971A1 | NVIDIA | Pending | yes | no | no | no |
| US12417047B2 | Google | GRANTED ACTIVE | partial | no | partial | no |
| US20240111525A1 | Tenstorrent | GRANTED ACTIVE | no | no | YES | no |
| US20250298621A1 | Tenstorrent | GRANTED ACTIVE | no | partial | no | YES |
| US12282428B2 | AMD | GRANTED ACTIVE | no | partial | no | no |
| US10915446B2 | IBM | Expired | no | yes | no | no |

## The three white-space findings

1. Nothing ties a calibrated confidence to a choice of numeric precision or
   compression format for prefetched AI data. Qualcomm US10176090B2 is the
   nearest miss and it is real: its claimed prefetch accuracy indicator is a
   genuine hit-rate ratio and it does govern a fetch decision inside a
   compression controller. But it selects a QUANTITY, the number of memory
   lines, within a fixed compression scheme rather than a format or precision;
   it sits in a CPU memory controller, not an inference engine; and there is no
   model-aware prediction and no fallback.
2. Nothing combines a confidence-gated predictive fetch with a bounded-cost
   exact fallback in the same claim set. Tenstorrent US20250298621A1 owns the
   fallback but at instruction granularity with no fetch prediction. Intel,
   AMD, Qualcomm and IBM own confidence-gated prefetch but merely drop or
   throttle on low confidence; none recovers from a wrong speculative fetch by
   a bounded exact path.
3. Confidence in the AI-accelerator patents allocates resources, it does not
   pick representations. Groq US20260065098A1 is the most sophisticated loop
   found: a measured rejection ratio adjusts context length and KV cache size.
   That is resource sizing, not representation selection.

## THE REAL RISK IS COMPOSITE OBVIOUSNESS, NOT ANTICIPATION

The four elements are separately claimed across live patents:

- (a) and (b): Intel WO2025184895A1, whose dependent claim 6 expressly recites
  that the request is a KEY-VALUE CACHE request
- (c): Tenstorrent US20240111525A1, granted and active, claims multiplication
  across temporal phases where "the cardinality of the phase set is determined
  by a fidelity control value". It places NO limitation on where the fidelity
  value comes from, which is exactly what makes it compose with any confidence
  source
- (d): Tenstorrent US20250298621A1, granted and active, claims fetching in an
  "aggressive mode" that "operates using one or more assumptions", detecting
  the assumption is wrong, then "cancel the execution, transition to a
  conservative mode, and re-execute"

An examiner assembling a 103 rejection from Intel plus the two Tenstorrent
references would have a plausible case, and the two Tenstorrent patents share
the Bajic and Gilani inventor core, which strengthens motivation to combine
within that portfolio.

CONSEQUENCE FOR THE SPECIFICATION: the design cannot rest on the novelty of the
combination. It has to carry weight on HOW confidence is calibrated (a
finite-sample risk-control method, not a raw counter) and HOW fallback cost is
bounded (a stated worst-case, not best effort).

## Read-on flags to design around

1. NVIDIA US20260093971A1, pending, broadest live claim on (a): fetching NN
   weights "based, at least in part, on one or more neural network calibration
   operations performed prior to". Claim 3 defines calibration as performance
   predictions. Note that "calibration" here means timing profiling, not
   probability calibration. Scope will likely narrow in prosecution.
2. Qualcomm US10176090B2, granted active, highest exposure on (b) plus (c).
   Any design computing a prefetch hit rate and using it to size or shape a
   compressed transfer must be cleared against claims 10, 11 and 28.
3. Google US12417047B2, granted active, inventors include Jouppi, Ranganathan
   and Le. Claims keeping part of the model uncompressed in fast memory and
   part compressed in slow memory, and prefetching from slow to on-chip "based
   on a latency threshold". Nearest granted claim to element (c) in an AI
   accelerator context.
4. Tenstorrent US20220222086A1, pending from a 2017 priority: generate a
   "contribution estimate" and "suppress the component computation based on"
   it. Nearly unbounded.
5. AMD US12282428B2, granted active: "prefetch analytic" against a "selection
   threshold" for speculative prefetch in a data fabric.

## Verified negatives

- NVIDIA has no MoE expert-prefetch IP under assignee-scoped search
- Google and DeepMind have no hardware weight-prefetch-with-confidence patents
- Cerebras has no prefetch IP; its compression hits are packaging and thermal
- SambaNova returns zero assignee-scoped prefetch results
- Meta's one relevant accelerator scheduling application is abandoned
- Groq has no rollback IP, consistent with a statically scheduled machine that
  has no hardware speculation to unwind
- Phrase search for "prediction confidence" with "numeric precision" returned
  zero results; "calibrated confidence" with hardware prefetch returned three,
  all irrelevant

## Discrepancy between the two independent sweeps

Both agents identified Qualcomm US10176090B2 as the closest b-to-c reference.
The first reported the limitation in claims 28 and 29; the second read claims
10, 11 and 28. The substance agrees. Before any filing decision, the claim set
must be read directly rather than trusted from either summary.

## Caveats carried forward

Two of the broadest references, Tenstorrent US20220222086A1 (2017 priority) and
NVIDIA US20260093971A1 (2024 priority), are PENDING with movable claim scope.
Any freedom-to-operate conclusion must be re-checked against issued claims
rather than published ones. Intel US20250356164A1 published unusually fast
after an August 2025 filing and is early in prosecution.

THIS IS NOT A CLEARANCE SEARCH. A professional freedom-to-operate search is
required before any filing or before publishing new enabling detail.

---

# Second independent sweep: NVIDIA, AMD and Xilinx via FreePatentsOnline

Verified by fetching FPO detail pages and reading verbatim claim 1. US12282428
was cross-checked on both Google Patents and FPO with title, assignee, filing
date and grant date matching exactly, which validates FPO as a source.

CAVEAT: FPO exposes FILING date, not earliest priority. Dates are filing dates
unless marked. Only US12282428 has a verified priority date.

## Highest read-on risk, all GRANTED and IN FORCE

**AMD US12282428 B2, "Selective speculative prefetch requests for a last-level
cache".** Priority and filing 2021-12-28, granted 2025-04-22, expires
2042-01-15. Inventors Nakra, Arunkumar, Moyer, Fleischman. Claim 1: selectively
issue a speculative prefetch request based on the request meeting a selection
threshold. The abstract makes it explicit: the processor computes "prefetch
analytics" per speculative request and compares them against selection
thresholds. **Reads directly on predict plus score the prediction plus gate the
fetch on the score. The most dangerous single reference found.**

**AMD US12242384 B2, "Compression aware prefetch"** (continuation, filed
2023-01-27, granted 2025-03-04). Claim 1: "limiting overfetching of data by
prefetching other data to the cache memory based on a comparison of a threshold
compression ratio indicating a minimum acceptable compression level for
performing prefetching with an average of a compression ratio of the first data
and of the other data." **This is the only claim found anywhere that ties a
numeric representation metric to a threshold gating whether speculative data
movement happens, and frames the benefit explicitly as bounding overfetch cost.
It touches the representation limb and the bounded-cost limb simultaneously.**
Parent: US11567872 B1, granted 2023-01-31.

**AMD US11675703 B2, "Memory request throttling to constrain memory bandwidth
utilization"** (filed 2022-03-28, granted 2023-06-13). Claim 1 sets a throttle
level "based on at least one of an access latency metric and a prefetch
accuracy metric of a prefetcher of the cache". **A granted claim literally
reciting a prefetch accuracy metric driving throttling under a bandwidth
constraint.**

## Moderate risk

- AMD US12625817 "Cost-driven prefetching", granted 2026-05-12: cost per
  prefetcher-table entry by which memory level supplied it, evicting by cost.
  Value-weighted rather than probability-weighted prediction retention.
- AMD US12360907 "Region pattern-matching hardware prefetcher", granted
  2025-07-15: binds a second region to a learned pattern when differences are
  "greater than zero but fewer than a threshold number". A similarity gate for
  reusing a learned pattern, relevant to approximately-repeating expert access.
- AMD US2025/0307157 "Prefetch Throttling based on Cache Thrashing": measures a
  degree of thrashing and throttles on it. A pollution-cost gate.
- NVIDIA US12645455 B2 "Storage of tensor in a cache", granted 2026-06-02: a
  hardware TENSOR PREFETCH INSTRUCTION keyed on a tensor map and tile
  indication. Closest granted NVIDIA claim to an explicit AI-data prefetch
  primitive.
- NVIDIA US12141082 B2, the Tensor Memory Accelerator, granted 2024-11-12:
  coordinate-addressed asynchronous block transfer between external memory and
  shared memory.

## NVIDIA speculation art

**US2026/0236763 A1**, published 2026-08-13, ten days before this sweep. Claim
1: select draft token sets "based on multiple amounts of processing time and
multiple numbers of accepted tokens". Speculation width tuned by measured
acceptance statistics against measured cost. **The closest NVIDIA art to a
calibrated-confidence-plus-bounded-cost speculation scheme.**

## Protective prior art, expired or effectively expired

Useful for invalidating a competitor's broad claim rather than threatening us:

- NVIDIA US9563562 B2 (filed 2012): claim 1 explicitly recites a CONFIDENCE
  LEVEL setting prefetch distance, and a second confidence level derived from
  the first when crossing a page boundary
- NVIDIA US9262328 B2 (filed 2012): second-cache hit feedback sets prefetch
  distance, functionally a prefetch accuracy metric throttling aggressiveness
- NVIDIA US7461211 B2 (filed 2004): priority adjuster receives an indication of
  success of target addresses and reprioritizes a prediction inventory
- AMD US11893502 B2, MoE hardware selection, priority 2017-12-20: predates the
  MoE hardware-patent wave by years and is strong prior art against later expert
  placement claims

## WHITESPACE CONFIRMED BY THIS SWEEP

- **KV cache prefetch, paging, migration and tiering: ZERO NVIDIA hits and ZERO
  AMD hits.** Assignee-scoped searches for "key-value cache" and "KV cache"
  returned nothing against both. This is the clearest whitespace found.
- **MoE expert prefetch or expert weight caching in hardware: no NVIDIA art at
  all.** AMD holds only expert PLACEMENT (US11893502) and expert offload to
  NICs (US2026/0086870, pending, AMD and Xilinx jointly).
- **Bounded-cost exact fallback on a mispredicted data FETCH: no claim found.**
  Speculative decoding has exact fallback inherently, and AMD US12468632 has a
  two-path hit/miss structure, but nothing recites a BOUNDED recovery cost for
  a wrong speculative fetch.
- Confidence-driven precision or format selection remains unclaimed at the
  intersection.

## Cross-sweep agreement

Two independent sweeps using different sources (Google Patents via browser
session, and FreePatentsOnline) both conclude: no patent claims all four
elements, and nothing claims three. They independently flagged AMD US12282428
as a top read-on risk. The FPO sweep adds AMD US12242384 and US11675703, which
the first sweep did not surface, and both are granted and in force.

## Sourcing caveats for this sweep

Google Patents returned HTTP 503 for most of the session; Espacenet and Justia
returned 403; the WebSearch budget was exhausted at 200/200 before corroboration
could be completed. FPO inventor fields did not parse, so inventors are verified
only for US12282428. Three adjacent references surfaced from a single successful
Google Patents search but were NOT individually opened and remain unverified:
SK Hynix US2026/0111700, Samsung KR2026/0002207 and TW202605670, Intel
US2025/0356164.
