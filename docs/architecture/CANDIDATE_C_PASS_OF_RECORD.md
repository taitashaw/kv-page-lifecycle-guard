# Candidate C Pass and Rescore

**Date:** 24 August 2026  
**Decision:** **REJECT Candidate C for architecture freeze**  
**Final score:** **67/100**  
**RTL gate:** **Closed. Do not start production RTL or ZCU104 integration from Candidate C.**

## Executive ruling

The pass found a real scheduling failure, but not a defensible new architecture.

When a page has `refcount = 0` but still carries in-flight work, separate deadline and capacity checks can both accept a request even though no legal execution can meet its deadline. The executable oracle proves that counterexample.

The proposed remedy, however, is already functionally occupied. BROS combines residual-deadline feasibility, explicit KV-block capacity, and block preemption state in its scheduling path. SuperInfer combines SLO progress, free HBM blocks, transfer budget, and running/waiting/rotary lifecycle state. OrbitFlow jointly optimizes SLOs, KV placement, transfer activity, and capacity. Real-time systems work already combines EDF-style demand, resource reservation, cache capacity, page locking, and inherited blocking.

Candidate C therefore survives only as a potentially useful implementation artifact. Moving the composition into FPGA RTL, adding counters, or observing it with ILA earns no mechanism-novelty credit.

## Evidence boundary

### Verified

- The local scoring rubric assigns 30 points to novelty and rejects every candidate below 80.
- Three independent derivations all found the lifecycle counterexample valid, but none established that a third irreducible scheduling primitive is required.
- The corrected executable model reproduces deterministically, enforces a hard descriptor bound, and passes 11 regression tests.
- The one-frame oracle explores 35 reachable states and finds the earliest legal completion at cycle 4 against deadline 3.
- The full-text sources below support the stated mechanism overlaps and publication statuses.

### Derived judgment

- The 67/100 score is an engineering judgment under the supplied rubric. It is not measured performance.
- The impact reduction reflects a synthetic admission/throughput trade and a strict-credit falsifier, not a production benchmark.
- “Mechanism occupied” means the functional conjunction is present in prior systems. It is not a patent or freedom-to-operate opinion.

### Not verified

- The linked `SPEC.md` and decision files were not available locally, so this pass reviews the supplied account and the local trade study, not every specification line.
- No XSim result, synthesis report, place-and-route result, bitstream, ZCU104 measurement, or ILA capture exists for Candidate C.
- The model does not include AXI channels, DDR bank/row behavior, refresh, PS contention, coherency, DMA descriptor latency, or a downstream service-envelope proof.
- The required 30-paper full-text matrix for a final novelty certification is not complete. This pass is sufficient to reject Candidate C, not to certify a replacement.

## The counterexample

Initial state:

- one physical frame contains page A;
- `A.refcount = 0`;
- A has two cycles of in-flight use remaining;
- request B needs the frame and two cycles of fill service;
- B has deadline 3.

The incomplete capacity test accepts because it sees `refcount == 0`. The incomplete deadline test accepts because `2 <= 3`. A legal controller must first drain A for two cycles and then fill B for two cycles:

\[
C_B^{earliest}=C_A^{drain}+C_B^{fill}=2+2=4>3.
\]

This proves that admission must include quiescence precedence. It does not prove that a new “three-ledger” primitive is necessary. A composed controller can represent the drain as predecessor work inheriting B’s deadline, reserve a frame atomically, and admit under a standard non-preemptive demand test:

\[
B_{np}(t)+\sum_{k:d_k\le d}C_k\le d-t,
\]

with page reuse permitted only when reference, fill, in-flight, and outstanding-I/O state are all quiescent.

The temporarily non-evictable count is therefore derived from page lifecycle and capacity state. The pass did not prove a universal reduction for every trace, but it also found no irreducible residue separating Candidate C from lifecycle-aware EDF plus reservation and safe reclamation.

## Corrected executable results

These are deterministic synthetic-model results, not board measurements or production predictions.

### Four-tenant constructed overload

| Policy | Completed | On time out of 24 offered | Expired before admission | DDR utilization |
|---|---:|---:|---:|---:|
| FIFO | 11 | 3 | 13 | 76.03% |
| EDF | 14 | 4 | 10 | 90.08% |
| Credit-only | 12 | 2 | 12 | 79.34% |
| Lifecycle-aware EDF | 14 | 4 | 10 | 89.26% |
| Joint | 10 | 10 | 14 | 66.12% |

The joint rule protects six additional deadlines relative to lifecycle-aware EDF, but completes four fewer requests. Its 10 on-time completions come from conservative admission: all 10 completed requests are on time, while 14 of 24 offered requests expire before admission. That is a service-policy trade, not dominance.

### Directed falsifiers and witnesses

| Test | Result | What it establishes |
|---|---|---|
| Non-binding witness | Joint and lifecycle-aware EDF both deliver 4/4 on time | Equality on one trace only, not universal equivalence |
| Strict-credit falsifier | Lifecycle-aware EDF delivers 5/5; joint delivers 4/5 | The fixed-credit conjunction is not universally better |
| Post-fill reservation witness | Baseline admits an infeasible second request; joint rejects it | Inevitable post-fill reads must be reserved during admission |
| Coalesced-fill witness | Baseline admits urgent B and B is late; joint rejects B | A shared prerequisite fill must inherit the prospective waiter deadline before admission |
| One-frame oracle | Earliest legal B completion is 4 against deadline 3 | Separate scalar tests that ignore in-flight quiescence are unsound |

The first implementation of the model was not accepted. Hostile review found an omitted post-fill read, an unbounded hidden descriptor queue, non-global EDF ordering, and later a coalesced-fill prerequisite hole. Those defects were corrected, regression tests were added, all results were regenerated, and a final independent re-audit passed within the model’s declared abstraction.

## Prior-art collision matrix

| Work | Status | Candidate C overlap | Boundary |
|---|---|---|---|
| [BROS](https://arxiv.org/html/2504.09590v1) | [IEEE INFOCOM 2026](https://infocom2026.ieee-infocom.org/accepted-paper-list-main-conference), peer-reviewed | Equation 6 constrains residual TTFT/TPOT time, Equation 8 constrains new KV blocks by empty blocks, and Algorithm 1 consults preemptible blocks before admitting urgent work | Estimator-based SLO feasibility, not a hard real-time theorem |
| [SuperInfer](https://proceedings.mlsys.org/paper_files/paper/2026/file/07fd64f9316f40193c6a4d87d8afa011-Paper-Conference.pdf) | MLSys 2026, peer-reviewed | VLT tracks SLO progress; `B_HBM` and `B_xfer` bound free blocks and transfer work; running, waiting, and rotary states control reclamation | Heuristic SLO control measured on GH200 |
| [OrbitFlow](https://www.vldb.org/pvldb/vol19/p1046-ma.pdf) | PVLDB 2026, peer-reviewed | Jointly chooses KV placement under memory capacity, transfer activity, in-use buffers, and SLO constraints; may defer in-flight requests | Model- and profile-dependent SLO control |
| [PagedAttention](https://arxiv.org/pdf/2309.06180) | SOSP 2023, peer-reviewed | Owns fixed-block KV allocation, block tables, reference counting, sharing, copy-on-write, and safe freeing | No deadline-admission predicate |
| [Kim and Rajkumar](https://www.sciencedirect.com/science/article/pii/S1383762113001240) | Journal of Systems Architecture 2014, peer-reviewed | Shows that shared-page eviction can create unexpected timing penalties and uses page conservation and eviction locking | General real-time pages, not KV-specific |
| [AXI Budgeting Unit](https://drops.dagstuhl.de/entities/document/10.4230/LIPIcs.ECRTS.2019.24) | ECRTS 2019, peer-reviewed | FPGA hardware enforces AXI bandwidth reservations and derives timing bounds | Bandwidth/service ledger, not KV lifecycle |
| [Joint cache and bandwidth allocation](https://drops.dagstuhl.de/entities/document/10.4230/LIPIcs.ECRTS.2025.2) | ECRTS 2025, peer-reviewed | Co-allocates cache capacity and memory bandwidth for real-time tasks under scheduling constraints | General multicore memory system |
| [MPORA](https://drops.dagstuhl.de/entities/document/10.4230/LIPIcs.ECRTS.2026.17) | ECRTS 2026, peer-reviewed | Dynamically reallocates cache and bandwidth while tracking deadline-sensitive task progress | Broader resource allocation, not page-refcount admission |
| [CXL-SpecKV](https://dl.acm.org/doi/10.1145/3748173.3779188) | ACM FPGA 2026, peer-reviewed | Occupies the FPGA KV-manager artifact lane with allocation, migration, prefetch, DMA, and compression | No matching deadline/refcount predicate |
| [Cascade](https://arxiv.org/abs/2608.06557) | Preprint submitted 6 August 2026 | Coordinates request latency budgets, scheduling, KV placement, restore traffic, capacity, and preemption | Profile-driven simulation, not a physical deployment |

BROS is the decisive mechanism collision. SuperInfer and OrbitFlow independently prevent a claim that the conjunction is merely an accidental detail of one design. The real-time literature removes the broader claim that deadline demand, capacity, and temporarily unavailable resources form a new scheduling concept.

## Rescore

| Criterion | Previous | Rescored | Reason |
|---|---:|---:|---|
| Defensible novelty gap | 12/30 | **8/30** | The residue is occupied. The predeclared 4-point disproof cap is not invoked because the literal existence counterexample survives. |
| ZCU104 feasibility | 17/20 | **17/20** | A bounded controller remains plausible, but no synthesis, timing, or DDR service proof exists. |
| Likely systems impact | 16/20 | **12/20** | The synthetic SLO gain requires rejecting more offered work, and the strict-credit falsifier loses to lifecycle-aware EDF. Direct systems already implement the functional conjunction. |
| Ability to measure on hardware | 15/15 | **15/15** | Deterministic replay, counters, assertions, and ILA could measure it convincingly if it were selected. This is measurability, not existing board evidence. |
| Reproducibility and open-source value | 10/10 | **10/10** | Deterministic traces, complete result files, an independent oracle, and 11 regression tests are supplied. |
| Clarity of central insight | 5/5 | **5/5** | The lifecycle dependency and its limits are now stated precisely. |
| **Total** | **75/100** | **67/100** | **Below the mandatory 80-point gate.** |

## Final decision

Candidate C is rejected as a novel flagship architecture. The counterexample is valid, but the functional remedy is occupied and the model shows a policy trade rather than dominance. No production RTL, Vivado block design, bitstream, or ILA gate should begin from this branch.

If retained at all, it should be framed later as an open, verified ZCU104 reference artifact for KV lifecycle safety and QoS, not as a new scheduling mechanism.

## Three replacement bottlenecks to screen next

These are research seeds, not selected candidates and not novelty claims:

1. **Atomic live model-update consistency:** prevent mixed weight epochs across DMA, on-chip buffers, and in-flight kernels while supporting bounded rollback.
2. **Low-overhead silent-error containment for quantized AI datapaths:** detect and localize arithmetic corruption without full duplicate execution, while separating safety guarantees from measured detection coverage.
3. **Cross-tenant accelerator-state erasure and timing isolation:** prove that scratchpads, DMA descriptors, and reused compute contexts cannot leak prior-tenant state or create a measurable reuse oracle.

Each must receive the same full-text collision screen and executable kill test before it can enter a ZCU104 specification.
