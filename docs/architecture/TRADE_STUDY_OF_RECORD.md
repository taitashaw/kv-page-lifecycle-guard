# Four-Architecture Trade Study

**Date:** 23 August 2026  
**Status:** **NO SELECTION. ALL FOUR CANDIDATES FAIL THE 80/100 GATE.**  
**RTL gate:** Closed. Do not start production RTL from this study.

This report reviews the supplied v0.3 account and applies the scoring and architecture-freeze rules in `CODEX_MASTER_PROMPT_ZCU104_FRONTIER_AI_HARDWARE.md`.

## Executive ruling

The v0.3 response is materially better in research discipline: it retracts premature completion language, keeps the design at candidate status, removes the unverified project name, separates proof from measurement, and blocks RTL pending open gates.

Its main engineering conclusion is still wrong. The nested MSB/LSB organization does **not** dominate on every axis. It only dominates a duplicated compact-plus-exact representation in stored capacity and in the ceiling on requested payload bytes, under restrictive assumptions. Its own table shows a worse best-case payload ratio than the corrected v0.2 organization, 0.529 versus 0.406. At full refinement it ties the baseline in payload bytes but can lose in latency, energy, command efficiency, and recomputation cost.

The four-candidate study produces no architecture that clears the required score of 80:

| Rank | Candidate | Novelty /30 | Feasibility /20 | Impact /20 | Hardware evidence /15 | Reproducibility /10 | Clarity /5 | Total /100 | Disposition |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | C. Deadline-aware multi-tenant KV manager | 12 | 17 | 16 | 15 | 10 | 5 | **75** | Reject as flagship; retain as artifact candidate |
| 2 | D. Joint KV and MoE transfer fabric | 11 | 14 | 17 | 13 | 8 | 4 | **67** | Reject; possible later integration experiment |
| 3 | B. Runtime-certified refinement attention | 5 | 14 | 9 | 14 | 9 | 4 | **55** | Reject; direct certification/refinement collisions |
| 4 | A. Nested-plane KV manager | 6 | 14 | 10 | 13 | 8 | 3 | **54** | Reject; core mechanism directly anticipated |

These are evidence-based trade-study judgments, not measured performance results. The 30-paper full-text matrix required by the master prompt remains an open novelty gate, so this report can reject candidates but cannot certify a new one.

## Evidence boundary

### Verified

- The scoring weights and 80-point rejection rule are present in the local master prompt.
- The byte equations below follow from the stated element count, group size, and numeric format.
- The cited primary papers and official AMD documentation support the collision and board-boundary findings stated here.
- The ZCU104 uses the XCZU7EV device and its standard configuration includes 2 GB of PS DDR4; the PL DDR4 SODIMM is not supplied with the kit. [AMD ZCU104 board page](https://www.amd.com/en/products/adaptive-socs-and-fpgas/evaluation-boards/zcu104.html), [UG1267](https://docs.amd.com/v/u/en-US/ug1267-zcu104-eval-bd)

### Derived or predicted

- Architecture scores, projected FPGA resources, and proposed success thresholds are engineering judgments.
- Any claimed latency, bandwidth, or quality improvement remains a hypothesis until simulation and board measurement.
- Resource ranges are planning envelopes, not synthesis or implementation reports.

### Not verified

- The full v0.3 `SPEC.md` was not available in the workspace and the supplied link was not inspectable here. This review therefore covers the supplied account, not every specification line.
- No synthesis, place-and-route, XSim result, bitstream, ILA capture, or measured DDR result exists in the supplied evidence.
- The required 30-paper full-text prior-art matrix is not complete. Absence of a paper from this review is not proof of novelty.
- No claim of being first, unique, groundbreaking, or globally superior is cleared.

## v0.3 claim audit

| Supplied statement | Ruling | Required correction |
|---|---|---|
| “Nested organisation dominates on every axis” | **False** | It improves the fallback payload ceiling and eliminates duplicate representation capacity. It does not dominate best-case traffic, latency, energy, command count, metadata area, or complexity. |
| “Cannot lose on traffic at any miss rate” | **Overbroad and uses the wrong variable** | `m` is the fraction of requested pages that receive refinement, not the cache-miss rate. The design cannot exceed the baseline only in requested payload bytes under the assumptions listed below. |
| Worst case is 1.000x | **Conditionally true for payload reads** | True only when base and refinement partition the same INT8 representation, each is fetched at most once, and metadata, retries, fills, writebacks, cancellation, and alignment overhead are excluded. |
| Best case is 0.529x | **Conditionally true** | It follows from the stated symmetric INT8 format. It is worse than the 0.406 best case shown for the corrected duplicated scheme. |
| Break-even is `m < 1.0` | **True only for the payload-byte equation** | At `m = 1` payload ties. System latency or energy can break even earlier because refinement is a dependent second transfer and may require recomputation. |
| Exact page is 2,176 B | **Incomplete** | This is one K **or** one V block encoded as symmetric group-quantized INT8 plus FP16 scales. It is not an FP16 page and not a K+V pair. |
| A 64-bit hash plus verification closes collisions | **Not established** | The key widths are internally inconsistent, and a verification word helps only if independently derived or checked on every hit with defined mismatch handling. Full tenant identity must be compared or the table must be physically partitioned. |
| 4-bank, 4-to-6-cycle URAM pipeline | **Plausible target, not a result** | Confirm inferred memory shape, cascade placement, hazards, initiation interval, and post-route timing. Same-entry read-modify-write operations require forwarding or locking. |
| Tenant ID makes cross-tenant sharing impossible | **Good objective, incomplete mechanism** | It is structural only if the full tenant discriminator participates in lookup equality or tenants use physically separate tables. Hash salting alone is probabilistic. Timing non-interference is a separate property. |
| No RTL until seven gates clear | **Correct** | Keep this gate closed. This trade study adds an eighth blocker: no candidate scores 80. |

## Correct byte and storage model

For 16 tokens and `head_dim = 128`:

\[
N = 16 \times 128 = 2{,}048\text{ elements}
\]

The stated 2,176-byte geometry is obtained only with these assumptions:

- one K tensor block or one V tensor block;
- symmetric INT8 values;
- group size 32;
- one FP16 scale per 32-element group;
- no zero points, outliers, headers, CRC, ECC, or padding.

There are 64 groups, so:

\[
B_{exact}=2{,}048 + 64\times2 = 2{,}176\text{ B}
\]

\[
B_{base}=1{,}024+128=1{,}152\text{ B},\qquad
B_{refine}=1{,}024\text{ B}
\]

For refinement fraction \(m\):

\[
R(m)=\frac{1{,}152+1{,}024m}{2{,}176}
=\frac{9}{17}+\frac{8}{17}m
\]

| Refinement fraction `m` | Requested payload ratio |
|---:|---:|
| 0.00 | 0.5294 |
| 0.25 | 0.6471 |
| 0.50 | 0.7647 |
| 0.75 | 0.8824 |
| 1.00 | 1.0000 |

“Exact” here means bit-exact reconstruction of the quantized INT8 representation. Raw FP16 for the same single tensor block is 4,096 bytes. A K+V pair under the stated INT8 format is 4,352 bytes.

On a 128-bit AXI datapath, the three transfers contain 72, 64, and 136 beats. They fit within the AXI4 256-beat maximum, but bursts may not cross a 4 KiB boundary, so the address generator still needs split-burst logic. The earlier 128-byte minimum is a design policy, not an AXI requirement. [AMD AXI reference](https://docs.amd.com/api/khub/documents/VD4yB934fQOp7AX2Iwwkqg/content)

The strongest safe sentence is:

> For an identical set of INT8 page requests, with exactly one base read and at most one refinement read per page, the nested representation requests no more page-payload bytes than the exact INT8 baseline. This statement excludes metadata, fills, retries, cancellation, writeback, padding, and command or latency costs.

## Metadata and capacity audit

A 4-way table containing 65,536 entries has 16,384 sets, requiring 14 index bits. Therefore:

- a 48-bit lookup identity leaves a 34-bit tag;
- a 64-bit hash leaves a 50-bit tag before adding tenant identity;
- 64-bit hash plus tenant identity cannot simultaneously be a 48-bit identity;
- tag, physical index, refcount, validity/fill/plane state, replacement state, generation, and a 64-bit verifier cannot fit in one 72-bit UltraRAM row.

AMD defines an UltraRAM block as 4,096 by 72 bits, and the ZU7EV contains 96 blocks. Sixteen blocks can hold four ways of 16,384 entries only when each complete entry fits within 72 bits. A realistic wider entry will require roughly twice that table storage, with the exact count determined by the frozen entry format. [AMD UltraRAM architecture](https://docs.amd.com/r/en-US/ug573-ultrascale-memory-resources/UltraRAM-Summary), [AMD ZU7EV resources](https://docs.amd.com/api/khub/documents/sbPbXcMUiRSJ2O5STvuGNQ/content)

Capacity also needs correction:

\[
65{,}536\times2{,}176=142{,}606{,}336\text{ B}=136\text{ MiB}
\]

That is 136 MiB for one-K-or-one-V pages, not 16 MB. If each logical entry represents a K+V pair at the stated geometry, it is 272 MiB.

## Candidate A: nested-plane KV manager

### Central hypothesis

Store a single INT8 representation as MSB4 base plus LSB4 refinement. Fetch the base for every requested page and the refinement only when a confidence policy requires it, while a hardware page manager enforces fill, identity, sharing, reference, and eviction invariants.

### Novelty collision

The central mechanism is already very close to multiple works:

- [SpAtten, HPCA 2021](https://arxiv.org/abs/2012.09852) fetches MSBs first, evaluates attention, and fetches LSBs when confidence is insufficient in a hardware architecture.
- [QuantSpec](https://arxiv.org/html/2502.10424v1) describes hierarchical KV in which INT8 is an upper INT4 component plus a lower INT4 residual, without storing duplicate full representations.
- [Lynx](https://arxiv.org/abs/2607.01831), a July 2026 preprint, is KV-specific and splits INT8 data into a 4-bit MSB anchor and 4-bit LSB residual for progressive execution.
- [SliceMoE](https://arxiv.org/html/2512.12990v3) separately manages MSB and LSB slices and can execute on MSBs alone for selected experts.
- [PagedAttention, SOSP 2023](https://arxiv.org/abs/2309.06180) already establishes paged KV allocation, logical-to-physical mapping, sharing, reference counting, copy-on-write, and eviction mechanisms.

The remaining value is an open, rigorously verified ZCU104 artifact. It is not a cleared architecture novelty.

### Minimum disproof experiment

Before RTL, run a bit-accurate model on real K and V traces. Force refinement fractions of 0, 0.25, 0.5, 0.75, and 1, then run the actual confidence policy separately. Count physical aligned bytes, descriptor and split-burst overhead, cycles, and output error. Inject hash collisions, same-set read-modify-write hazards, eviction during fill, stale completions, and refcount saturation.

Kill the performance case if the measured controller-visible byte ratio is above 0.75 on either of two representative workloads, if P95 fetch latency fails to improve by at least 10 percent, or if quality requires refinement near 1. These are proposed thresholds, not measured results. Even if it survives, present it as an FPGA implementation contribution.

## Candidate B: runtime-certified refinement attention

### Central hypothesis

Compute conservative query-dependent score or output-error intervals from base bit planes, refine only pages whose uncertainty can change the accepted attention result, and permit output only when the declared error contract is satisfied or all data is refined.

### Novelty collision

- [BitStopper, ASP-DAC 2026](https://arxiv.org/html/2512.06457) progressively fetches key bit planes, derives query-dependent score bounds, refines surviving tokens, and implements a custom RTL accelerator.
- [Runtime-Certified Bounded-Error Quantized Attention](https://arxiv.org/abs/2605.20868) combines compressed-domain execution, per-head and per-step K+V error bounds, adaptive precision, and deterministic fallback.
- [Token-Picker, DAC 2024](https://arxiv.org/abs/2407.15131) estimates attention probabilities and performs on-demand off-chip access in hardware.
- [WitCert](https://arxiv.org/html/2607.28699v2) computes query-dependent attention-error certificates and selectively repairs blocks, with exact fallback.
- [InfiniGen, OSDI 2024](https://www.usenix.org/conference/osdi24/presentation/lee) uses partial query and key representations to select KV entries for transfer.

This candidate has the most direct mechanism collision of the four. A ZCU104 implementation could still be useful, but it would be an artifact claim.

### Minimum disproof experiment

Use at least 10,000 real head-steps from multiple open model families before RTL. Compare dense INT8, base-only INT4, progressive thresholding, and certified refinement. Measure certificate soundness and tightness, physical traffic, refinement fraction, two-pass latency, and bound-computation cost. Include nearly equal logits, diffuse attention, extreme channels, and adversarial low-nibble residuals.

Kill immediately on one certificate violation, mean refinement above 57.5 percent if the target is 20 percent traffic saving, P95 physical traffic above baseline, or projected two-pass latency that does not beat the exact path.

## Candidate C: deadline-aware multi-tenant KV manager

### Central hypothesis

Jointly admit and schedule page operations against three coupled ledgers: deadline-qualified byte demand, reservable page capacity, and temporarily non-evictable referenced or inflight state. Enforce tenant address isolation, safe lifecycle transitions, reserved service, and bounded issue-side wait in RTL.

### Novelty collision

- [PagedAttention](https://arxiv.org/abs/2309.06180) establishes the core paged KV lifecycle.
- [Cascade](https://arxiv.org/abs/2608.06557), submitted 6 August 2026, jointly coordinates scheduling and KV management under per-request latency budgets.
- [Virtual Token Counter, OSDI 2024](https://www.usenix.org/conference/osdi24/presentation/sheng) is a work-conserving multi-client scheduler with a proved service-difference bound.
- [DLPM](https://arxiv.org/html/2501.14312v1) couples KV-prefix locality with fair scheduling and formal service bounds.
- [SCORPIO](https://arxiv.org/abs/2505.23022) combines deadline ordering, admission rejection, and credit-based batching.
- [SafeKV](https://arxiv.org/html/2508.08438v2) combines tenant ownership, sharing state, reference protection, and eviction.
- [CXL-SpecKV, FPGA 2026](https://dl.acm.org/doi/10.1145/3748173.3779188) establishes FPGA-accelerated KV management as an occupied artifact lane.

The potentially defensible residue is a new three-ledger admission predicate with a proof and a counterexample showing why separately feasible bandwidth and capacity policies fail when references or inflight transactions make pages temporarily unevictable. That residue requires a targeted prior-art sweep before it can be scored as novel.

### Guarantee boundary

The PL controller can prove admission, arbitration, address isolation, lifecycle safety, service credits, and an issue-side scheduler bound. It cannot promise unconditional end-to-end PS-DDR completion under arbitrary traffic from other PS and PL masters. DDR completion latency must be either conditional on a declared downstream service envelope or reported as measured board performance. Likewise, address isolation does not prove timing non-interference.

### Minimum disproof experiment

Replay one deterministic four-tenant trace in simulation and unchanged on the ZCU104. Include an over-rate tenant, a short-deadline tenant, a long sequential tenant, and an intra-tenant sharing workload that releases references while reads remain inflight and forces near-full capacity. Compare FIFO, EDF-only, credit-only, and the joint policy.

Trigger ILA on a deadline or service-bound violation, cross-tenant hit, stale-generation completion, or eviction while `refcount`, `inflight`, or `fill_pending` is nonzero. Kill on any safety failure, any scheduler-bound failure while assumptions hold, no improvement over the strongest baseline, more than 10 percent aggregate-bandwidth loss, or failure to close timing at the declared clock.

## Candidate D: joint KV and MoE transfer fabric

### Central hypothesis

Place mandatory and speculative KV and expert transfers under one physical-byte budget. Rank speculation by expected authoritative stall cycles saved per transferred byte while reserving fallback capacity and a finite maximum wait for mandatory classes.

### Novelty collision

- [DASH](https://arxiv.org/html/2608.14333v1), submitted 14 August 2026, jointly schedules expert-weight movement and mutable KV traffic.
- [FluxMoE](https://arxiv.org/html/2604.02715v2) dynamically prioritizes KV capacity while controlling streamed expert residency.
- [PagedWeight](https://arxiv.org/html/2607.16184v1) adapts expert precision and movement in response to KV pressure.
- [Harvest](https://arxiv.org/abs/2602.00328) manages transient shared caching of model weights and KV state.
- [MoE-Infinity](https://arxiv.org/html/2401.14361v3) documents contention between offloaded KV traffic and expert prefetch.
- [AXI Budgeting Unit, ECRTS 2019](https://drops.dagstuhl.de/entities/document/10.4230/LIPIcs.ECRTS.2019.24) establishes hardware AXI bandwidth reservation and response-time analysis on Zynq.

The broad joint-management idea is occupied. A four-queue FPGA controller with calibrated cross-class utility, hard speculation budgets, reserved exact-fallback descriptors, and finite wait could be a useful systems artifact, but the conjunction is not enough for the prompt's novelty standard.

### Minimum disproof experiment

Before RTL, replay a real paired KV and MoE trace plus an adversarial trace through a queue-level model calibrated with measured ZCU104 DDR service times. Compare independent fixed quotas, tuned AXI QoS, greedy confidence, demand-only service, and the joint policy at 70 to 95 percent offered load.

Pre-register a predicted target of at least 20 percent lower P99 authoritative stall, at least 25 percent fewer wasted speculative bytes, no more than 2 percent useful-throughput loss, and zero correctness, budget, or finite-wait violations. Kill if improvement disappears against tuned AXI QoS, speculation can block exact fallback, or benefit exists only on synthetic traces.

## Claims barred by the current evidence

Do not claim any of the following:

- first nested, hierarchical, or single-copy precision KV representation;
- first progressive bit-plane fetch or uncertainty-triggered refinement;
- first runtime-certified bounded-error attention;
- first adaptive K/V precision promotion or exact fallback;
- first deadline-aware joint scheduler and KV manager;
- first joint KV and MoE memory-management fabric;
- first FPGA KV manager, compressor, address translator, or prefetcher;
- cryptographic collision freedom or timing non-interference from a finite hash and tenant salt;
- patent freedom. This study is a literature collision screen, not a freedom-to-operate opinion.

## One-page architecture decision

1. **Selected bottleneck:** None is frozen. The most credible unresolved bottleneck is predictable multi-tenant KV-page service under coupled bandwidth, capacity, and non-evictable-state constraints.
2. **Selected architecture:** **None.** Candidate C ranks first at 75/100 but fails the mandatory 80-point threshold. It is retained only as the next research branch.
3. **Closest five works to that branch:** PagedAttention, Cascade, Virtual Token Counter, DLPM, and SCORPIO.
4. **What may be new:** A hardware admission predicate over three simultaneous ledgers, with a proof that prevents eviction-induced deadline inversion under a declared downstream service envelope. This is a research hypothesis, not an established novelty.
5. **What is reused or combined:** Paged KV allocation, reference-safe eviction, tenant ownership, deadline scheduling, credits or token buckets, fairness, AXI QoS, counters, and ILA observability.
6. **Falsifiable hypothesis:** There exists an admissible traffic region where separate bandwidth and capacity admission accepts a request that later suffers deadline inversion because referenced or inflight pages become temporarily unevictable, while a joint three-ledger predicate rejects or safely schedules it. On accepted traces, RTL will preserve lifecycle and tenant invariants and issue every memory request within a derived bound, conditional on the stated downstream service envelope.
7. **Minimum hardware experiment:** Four tenant queues, one 128-bit HP path, bounded descriptors, page/ref/inflight state, joint admission, credits, EDF plus starvation protection, deterministic trace replay, XSim assertions, physical AXI counters, and ILA triggers for the safety failures listed above. No full LLM datapath is required for this disproof.
8. **Pivot if it fails:** Stop pursuing a new scheduling mechanism. Reframe the work as an open ZCU104 reference artifact for verified KV lifecycle and QoS, or return to candidate generation outside progressive precision, KV scheduling, and joint KV/MoE movement.

## Final gate

**Decision: REJECT ALL FOUR FOR ARCHITECTURE FREEZE.**

Do not promote the nested organization to the selected design. Do not write production RTL. Candidate C is the only branch close enough to justify one more bounded research pass, specifically:

1. derive the three-ledger counterexample and admission predicate;
2. search that exact predicate and guarantee against full text, not keywords;
3. compare it directly with Cascade, SCORPIO, DLPM, SafeKV, PagedAttention, and predictable SDRAM arbitration;
4. run the queue-level minimum-disproof model;
5. re-score it without novelty credit for merely moving software policies into RTL.

If Candidate C still scores below 80, generate a new candidate set. The correct outcome of a trade study can be no selection.
