# Decision 003: Candidate C REJECTED at 67/100. No candidate remains.

24 August 2026. Full pass at `docs/architecture/CANDIDATE_C_PASS_OF_RECORD.md`.

| criterion | prev | rescored | why |
|---|---:|---:|---|
| novelty | 12/30 | **8/30** | residue OCCUPIED; the 4-point disproof cap does NOT apply |
| feasibility | 17/20 | 17/20 | plausible, but no synthesis, timing or DDR service proof |
| systems impact | 16/20 | **12/20** | the SLO gain requires rejecting more offered work |
| hardware measurability | 15/15 | 15/15 | measurability, not existing board evidence |
| reproducibility | 10/10 | 10/10 | deterministic traces, oracle, 11 regression tests |
| clarity | 5/5 | 5/5 | the lifecycle dependency and its limits are stated precisely |
| **total** | **75** | **67** | **below the 80 gate** |

## The scoring correction that matters

**The model does NOT disprove the counterexample.** It confirms it. When a page
has `refcount = 0` but still carries in-flight work, separate deadline and
capacity checks can both accept a request for which no legal execution meets the
deadline. The one-frame oracle explored 35 reachable states and found the
earliest legal completion at **cycle 4 against a deadline of 3**:

    C_B_earliest = C_A_drain + C_B_fill = 2 + 2 = 4 > 3

So novelty takes the **occupied-residue cap of 8**, not the conditional
4-point disproof cap. The failure is real; the remedy is taken.

## Why the remedy is occupied

Three peer-reviewed 2026 systems independently implement the functional
conjunction, which rules out the defence that it is an accidental detail of one
design:

- **BROS, INFOCOM 2026** (arXiv 2504.09590), the decisive collision. Equation 6
  constrains residual TTFT/TPOT time, Equation 8 constrains new KV blocks by
  empty blocks, and Algorithm 1 consults **preemptible block state** before
  admitting urgent work. That is all three ledgers in one scheduling path.
- **SuperInfer, MLSys 2026.** VLT tracks SLO progress; `B_HBM` and `B_xfer`
  bound free blocks and transfer work; running, waiting and rotary states
  control reclamation.
- **OrbitFlow, PVLDB 2026.** Jointly chooses KV placement under memory capacity,
  transfer activity, in-use buffers and SLO constraints.

The real-time literature removes the broader claim that deadline demand,
capacity and temporarily unavailable resources form a new scheduling concept:
Kim and Rajkumar (JSA 2014) on eviction-induced timing penalties with page
locking, the ECRTS 2019 AXI Budgeting Unit, ECRTS 2025 joint cache and bandwidth
allocation, and ECRTS 2026 MPORA.

Composed alternative, which the pass shows suffices: represent the drain as
predecessor work inheriting B's deadline, reserve a frame atomically, and admit
under a standard non-preemptive demand test, permitting page reuse only when
reference, fill, in-flight and outstanding-I/O state are all quiescent. **No
third irreducible primitive was established.**

## The joint policy is a trade, not a win

Four-tenant constructed overload, 24 offered requests, SYNTHETIC:

| policy | completed | on time | expired before admission | DDR util |
|---|---:|---:|---:|---:|
| lifecycle-aware EDF | 14 | 4 | 10 | 89.26% |
| **joint** | **10** | **10** | **14** | 66.12% |

Joint protects six more deadlines and completes four fewer requests. All ten of
its completions are on time because it admits far less. That is a service-policy
choice, not dominance. The **strict-credit falsifier settles it**:
lifecycle-aware EDF achieves 5/5 on time, joint achieves 4/5. The fixed-credit
conjunction is not universally better.

The first model was rejected. Hostile review found an omitted post-fill read, an
unbounded hidden descriptor queue, non-global EDF ordering, and a coalesced-fill
prerequisite hole. All four were corrected, regression tests added, results
regenerated, and a final independent audit passed. **These remain SYNTHETIC.
There is no AXI, DDR, ZCU104 or ILA measurement behind any of them.**

## My own duplicate pass was stopped, and would have missed the answer

I had a workflow running the same five steps. It was stopped as redundant. Worth
recording that its collision target list was Cascade, SCORPIO, DLPM, Virtual
Token Counter, SafeKV, PagedAttention and the predictable-SDRAM literature.
**It did not include BROS, SuperInfer or OrbitFlow, which are the three decisive
collisions.** It would have returned OPEN on the residue and scored C too high.

## Standing

Four candidates scored. None clears 80.

| candidate | score |
|---|---:|
| C. deadline-aware multi-tenant KV manager | 67 (was 75) |
| D. joint KV and MoE transfer fabric | 67 |
| B. runtime-certified refinement attention | 55 |
| A. nested-plane KV manager | 54 |

**No architecture is selected. The RTL gate stays closed.** Progressive
precision, KV scheduling and joint KV/MoE movement are all now demonstrably
occupied lanes and a new candidate set is required from outside them.

## Three replacement bottlenecks to screen

Research seeds only. None is cleared as novel and none is selected.

1. **Atomic live model-update consistency.** Prevent mixed weight epochs across
   DMA, on-chip buffers and in-flight kernels, with bounded rollback.
2. **Low-overhead silent-error containment for quantized AI datapaths.** Detect
   and localise arithmetic corruption without full duplicate execution, keeping
   the safety guarantee separate from measured detection coverage.
3. **Cross-tenant accelerator-state erasure and timing isolation.** Prove that
   scratchpads, DMA descriptors and reused compute contexts cannot leak
   prior-tenant state or create a measurable reuse oracle.

Each needs the same full-text collision screen and executable kill test before
it may enter a ZCU104 specification.

## Carried forward regardless of which candidate eventually wins

These are platform facts, not architecture:

- MEASURED ILA cost on this exact part, and the finding that the ILA cannot use
  URAM here (`docs/hil/ila_budget.md`)
- the debug hub clock divider, without which the ILA gate fails as Labtools
  27-3123 at our measured 301.03 MHz
- the passed JTAG bring-up gate (`docs/hil/smoke_test_01_jtag.md`)
- the three GUI evidence gates, which remain John's to capture
