# Decision 001: Option A with the KV cache manager pivot

**Ruled by John Bagshaw, 23 August 2026.** Supersedes the open framing question
in `candidate_trade_study.md`.

## The decision

Proceed as an **evidence-and-proof contribution**, and **pivot the subject from
the MoE expert fabric to a KV cache page manager built in Zynq UltraScale+
fabric**.

## Why this is the right call on the evidence

The novelty gate failed on architecture (76 against a gate of 80) because every
triple of predict / confidence / representation / bound is published. It did
NOT fail on the two things this pivot claims:

1. **No published work builds a real KV cache manager in Zynq UltraScale+
   fabric.** TeLLMe v2 exposes only address ports. Hummingbird and the DATE'25
   work manage KV in software. The detailed KV hardware, Titanus and HiKV, is
   all ASIC and all simulated. That gap was found by the edge-FPGA survey and
   nothing in the ~2,300-paper venue sweep filled it.
2. **No paper anywhere states a proved worst-case traffic amplification
   factor.** Across the whole sweep, ECHO's context-proportional global counter
   is the only enforced cap on speculative traffic and it is an engineering
   guardrail, not a proved bound. Our invariant 8,
   `bytes_read <= 1.25 * (n_req * 256)`, derived from the representation size
   ratio and asserted in hardware every cycle, is a different kind of object.

Neither of these requires out-inventing ASPLOS. Both play to what the
FabricGuard, RetryGuard and LinkGuard work already demonstrates: a proved
property plus silicon evidence that survives inspection.

## What the pivot changes about the threat landscape

The MoE expert literature was the densest part of the sweep and it now falls
largely **off-lane**:

| paper | venue | status after pivot |
|---|---|---|
| EARTH | ASPLOS 2026 | off-lane, MoE experts |
| STEP | ISCA 2026 | off-lane, MoE experts |
| MoE-APEX / HOBBIT | ASPLOS 2026 | off-lane, MoE experts |
| ELMoE-3D | CoRR preprint | off-lane, MoE experts |
| SliceMoE | CoRR preprint | off-lane, MoE experts |
| FATE | preprint | off-lane, MoE experts |

The live competition becomes the KV lane, which is thinner:

| paper | venue | the leg it holds |
|---|---|---|
| **Token-Picker** | DAC 2024 | provable bound on attention probability selects how many K chunks are fetched |
| **ECHO** | OSDI 2026 | lossless prefetch with guaranteed recall plus a counter-enforced cap |
| **InfiniGen** | OSDI 2024 | speculative KV prefetch, 309 citations, zero production footprint |
| **SpeCache** | ICML 2025 | speculative KV with precision variation |
| **DecDEC** | OSDI 2025 | representation plus a partial bound, no prediction |

Token-Picker remains the sharpest neighbour and must be addressed head-on in
the spec, not skirted. Its certainty is a one-sided proof rather than a
calibrated estimate, which is stronger than ours on that axis; our distinction
has to rest on the bound and on being built rather than simulated.

## What carries forward unchanged

- **Invariant 8 stays the headline enforced property.**
- The page geometry: 256 B exact, 64 B compact, 256 B aligned, dual
  representation in DDR at 1.25x capacity and write traffic.
- The split guarantee from SPEC.md section 2, which remains honest: delivery
  exactness is ENFORCED IN HARDWARE; value exactness is RISK-CONTROLLED
  OFFLINE and NOT enforced. That distinction does not soften under the pivot.
- The measured ILA budget and the debug hub clock divider, both of which are
  design-independent.
- The three GUI evidence gates, which remain John's to capture.

## What must be rewritten

`SPEC.md` is currently written around the confidence-gated precision fetch of
KV pages AND MoE experts. It must be re-scoped to the KV page manager alone,
with the MoE path removed rather than left dangling, and with Token-Picker and
ECHO addressed explicitly in the related-work boundary.

## Honest statement of the residual claim

This is not a claim to have invented confidence-gated precision fetch. Parts of
that idea are published at DAC, ASPLOS, ICML and OSDI. The claim is narrower
and defensible: a KV cache page manager implemented in FPGA fabric on a class
of part where no one has built one, carrying a proved and runtime-asserted
worst-case bound on bandwidth amplification that no published work states, and
evidenced on silicon with ILA captures that no published FPGA LLM accelerator
paper provides.

---

# CORRECTIONS TO THIS DECISION, 23 Aug 2026

Recorded rather than edited in place, so the error stays visible.

1. **Every "1.25x" in this document is WRONG.** The compact page it assumed
   violated the design's own 128 B burst floor. See `docs/reviews/spec_v02_review.md`.
2. **The bound contribution is WITHDRAWN.** Under the nested base-plus-refinement
   organisation adopted in SPEC v0.3, worst-case traffic equals the exact-only
   baseline exactly. There is no amplification, therefore no ceiling above 1.0
   to claim. The "first proved bandwidth amplification bound" framing is dead.
3. **"PageGuard" is RETIRED.** It collides with a shipping Feroot product. The
   internal codename is KVPM and no public name is proposed.
4. **This decision selected a SCOPE, not an architecture.** The KV page manager
   remains a CANDIDATE. The four-architecture weighted trade study required
   before selection has not been run, and must now include the nested
   base-plus-refinement organisation, which arrived after the last study and
   dominates the option that study chose.
5. **The claim altitude drops.** Until the novelty boundary survives independent
   review, this is an artifact and evidence contribution, an open FPGA
   implementation, not a mechanism-novelty contribution.
