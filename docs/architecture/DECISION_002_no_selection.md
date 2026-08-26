# Decision 002: NO SELECTION. All four candidates fail the 80 gate.

23 August 2026. Supersedes Decision 001, which selected a scope on the
assumption that a KV page manager with a traffic bound was a defensible
contribution. The four-architecture trade study
(`docs/architecture/TRADE_STUDY_OF_RECORD.md`) rejects all four.

| candidate | score | disposition |
|---|---:|---|
| C. deadline-aware multi-tenant KV manager | **75** | closest, still below the gate |
| D. joint KV and MoE transfer fabric | 67 | reject |
| B. runtime-certified refinement attention | 55 | reject |
| **A. nested-plane KV manager (SPEC v0.3)** | **54** | **reject, core mechanism directly anticipated** |

**Candidate A is the architecture SPEC v0.3 describes. It is rejected.**

## Why A fell to 54

The nested MSB-plus-LSB organisation is directly anticipated in hardware:

- **SpAtten, HPCA 2021** (arXiv 2012.09852) fetches MSBs first, evaluates
  attention, and fetches LSBs when confidence is insufficient, in a hardware
  architecture. This is the mechanism, in hardware, five years ago.
- **QuantSpec** (arXiv 2502.10424) makes INT8 an upper INT4 component plus a
  lower INT4 residual with no duplicate full representation.
- **Lynx** (arXiv 2607.01831) is KV-specific and splits INT8 into a 4-bit MSB
  anchor and a 4-bit LSB residual for progressive execution.
- **SliceMoE** manages MSB and LSB slices separately and executes on MSB alone.
- **PagedAttention, SOSP 2023** already establishes paged KV allocation,
  logical-to-physical mapping, sharing, reference counting, copy-on-write and
  eviction.

The residual value in A is an open, rigorously verified ZCU104 artifact. That is
an implementation contribution, not an architecture novelty.

## CORRECTIONS TO MY OWN v0.3 STATEMENTS

Recorded because a disproven claim is a result.

1. **"Nested dominates on every axis" is FALSE, and my own table said so.** Its
   best case is 0.529x against the corrected duplicated scheme's 0.406x. It is
   WORSE on best-case payload. It improves only the fallback ceiling and stored
   capacity. I printed both numbers and drew the opposite conclusion.
2. **`m` is the REFINEMENT FRACTION, not the cache-miss rate.** I used the two
   interchangeably. They are different quantities and the substitution is not
   valid.
3. **"Cannot lose on traffic at any miss rate" is overbroad.** It cannot exceed
   the baseline in requested PAYLOAD BYTES, given exactly one base read and at
   most one refinement read per page, excluding metadata, fills, retries,
   cancellation, writeback, padding, command count, latency and energy. At
   `m = 1` payload ties but a dependent second transfer can still lose on
   latency and energy.
4. **The 2,176 B page is one K block OR one V block**, symmetric group-quantized
   INT8 plus FP16 scales. It is not FP16 and not a K+V pair. Raw FP16 for the
   same block is 4,096 B and a K+V pair under this format is **4,352 B**.
5. **The entry does not fit.** A 64-bit hash, tenant identity, a 48-bit
   identity, a 34-bit tag and a 64-bit verifier cannot coexist in one 72-bit
   UltraRAM row. Sixteen URAMs hold 4 ways of 16,384 entries only if every
   entry fits in 72 bits; realistic metadata needs roughly twice that.
6. **Capacity units wrong.** 65,536 x 2,176 B = 142,606,336 B = **136 MiB**,
   which is 142.6 MB, not "136 MB". For K+V pairs it is 272 MiB.
7. **The 128 B minimum burst is our design policy, not an AXI requirement.** AXI4
   caps a burst at 256 beats and forbids crossing a 4 KiB boundary, so the
   address generator still needs split-burst logic regardless.

## The safe sentence, replacing every traffic claim made so far

> For an identical set of INT8 page requests, with exactly one base read and at
> most one refinement read per page, the nested representation requests no more
> page-payload bytes than the exact INT8 baseline. This excludes metadata,
> fills, retries, cancellation, writeback, padding, and command or latency costs.

## What happens next

Candidate C is the only branch justifying one more bounded pass, and it must
clear five steps before rescoring:

1. derive the three-ledger counterexample and admission predicate
2. search that exact predicate and guarantee against FULL TEXT, not keywords
3. compare directly with Cascade, SCORPIO, DLPM, SafeKV, PagedAttention, Virtual
   Token Counter and predictable SDRAM arbitration
4. run the queue-level minimum-disproof model
5. re-score with **no novelty credit for moving a software policy into RTL**

If C still scores below 80, generate a new candidate set. **The correct outcome
of a trade study can be no selection, and this is that outcome.**

## Claims now barred

First nested or single-copy precision KV representation. First progressive
bit-plane fetch. First uncertainty-triggered refinement. First runtime-certified
bounded-error attention. First adaptive K/V precision promotion or exact
fallback. First deadline-aware joint scheduler and KV manager. First joint
KV/MoE fabric. First FPGA KV manager, compressor, translator or prefetcher.
Collision freedom or timing non-interference from a finite hash plus tenant
salt. Patent freedom: this is a literature collision screen, not an FTO opinion.
