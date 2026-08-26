# SPEC v0.3: KVPM, a KV cache page manager in Zynq UltraScale+ fabric

> # STATUS: REJECTED, 54/100.
>
> This document describes **Candidate A** of the four-architecture trade study
> (`docs/architecture/TRADE_STUDY_OF_RECORD.md`), which scored **54 against a
> gate of 80** and was rejected because its core mechanism is directly
> anticipated by **SpAtten (HPCA 2021)**, which already fetches MSBs first and
> fetches LSBs on insufficient confidence in hardware, and by QuantSpec, Lynx,
> SliceMoE and PagedAttention.
>
> Retained only as an implementation reference. **It is not a cleared
> architecture and no part of it may be described as novel.** Seven of my own
> statements in this document are corrected in
> `docs/architecture/DECISION_002_no_selection.md`, including "dominates on
> every axis" (false, its best case is worse), the conflation of refinement
> fraction with miss rate, and a page table entry that does not fit in 72 bits.
>
> **Original header follows, superseded.**

> **STATUS: CANDIDATE ARCHITECTURE. NOT SELECTED. NOT CLEARED FOR RTL.**
> Gates still open, all of which must pass before Phase 4 begins:
> SAS unread; the 30-paper full-text matrix not demonstrated; the four-architecture
> weighted trade study not run; 18 of 23 BLOCKING review findings unadjudicated;
> no independent acceptance of the novelty boundary. See section 16.

**KVPM is an internal codename, not a name.** The previous label "PageGuard"
is **RETIRED**: it collides with a shipping Feroot cybersecurity product and
with a Linux kernel identifier. No public name is proposed here and none may be
used until a collision check is run and recorded.

Version 0.3, 2026-08-23. Supersedes v0.2, which failed its first architecture
review (`docs/reviews/spec_v02_review.md`, 83 findings, 23 BLOCKING).
Supersedes v0.1 (`docs/archive_SPEC_v0.1_cgpf.md`).

---

## 0. What changed from v0.2, and why

Five errors were confirmed by hand arithmetic and one design alternative was
supplied by John that dominates the v0.2 organisation outright.

| v0.2 said | v0.3 says | why |
|---|---|---|
| ceiling 1.25x | **no amplification at all, 1.000x** | v0.2's 64 B compact page violated its own 128 B burst floor; padded, the ceiling was 1.5x not 1.25x. Nesting removes the ceiling entirely |
| compact 64 B | **base 1152 B, refinement 1024 B** | 64 B is unreachable under v0.2's own INT4 format, which costs 104 B before burst padding |
| dual-representation storage, 1.25x capacity | **one stored copy, 1.000x capacity** | base and refinement partition the exact bits; nothing is duplicated |
| prefix sharing via a key containing `seq_id` | **content identity, `seq_id` removed** | two sequences never share a `seq_id`, so sharing could never fire |
| page table tag 20 b | **tag 30 b** | 44-bit key minus 14 index bits needs 30; 20 gave 1,024-way aliasing |
| no fill path | **section 8, full miss sequence** | allocator `phys_idx` had no relation to where the host wrote the page |

**The 1.25x figure is retired and must not appear in any post, deck or
artifact.** So is the 1.5x figure, which was only ever the corrected value for
the rejected organisation.

---

## 1. Scope and the honest claim

KVPM is a **KV cache page manager implemented in PL fabric** on a ZCU104. It
owns a bounded region of PS DDR and provides, in hardware: translation from a
content identity to a physical page, allocation, reference counting for shared
prefixes, eviction, a two-stage nested fetch, and counters sufficient for an
outside party to check every claim made here.

### 1.1 The claim, stated at the altitude the evidence supports

> An open FPGA implementation of a KV cache page manager on Zynq UltraScale+,
> with a nested base-plus-refinement fetch policy, whose **measured** achieved
> read traffic is reported against an exact-only baseline on real silicon with
> ILA evidence.

This is an **artifact and evidence contribution**. It is explicitly NOT a claim
of mechanism novelty. Bit-sliced base-plus-refinement fetch is published:
SliceMoE does MSB-first with conditional LSB fetch, EARTH does base-plus-delta
with selective delta fetch, and Token-Picker gates chunk fetch on a provable
bound. Until the novelty boundary survives independent review (section 16),
KVPM is described as a new open implementation, not a new mechanism.

### 1.2 The bound contribution is WITHDRAWN

v0.2 made a proved worst-case traffic amplification factor the headline. Under
the nested organisation there **is no amplification**: worst case equals the
exact-only baseline exactly. There is therefore no ceiling above 1.0 left to
claim, and the "first proved bandwidth amplification bound" framing is dropped.

What remains is a weaker and true safety property, section 3.3, plus a measured
achieved ratio. That is a smaller claim than v0.2 made and it is the one the
arithmetic supports.

### 1.3 Non-goals

- KVPM runs no language model. The board replays host-generated traces. No
  attention, no GEMM, no model arithmetic.
- Not a datacenter claim. Agilex 7 M-Series has roughly 40 to 57 times this
  board's memory bandwidth.
- Not an on-chip KV cache. 4.75 MB on chip against 512 MB for one 4,096-token
  FP16 context, a factor of 108 short.
- No protocol compliance claim for PCIe, CXL, NVLink or UALink.
- No power measurement. Tool estimates only, labelled as estimates.

---

## 2. Data model: nested base plus refinement

### 2.1 The representation, exactly

The stored form is **INT8 group-quantized**, bit-sliced into two INT4 planes.

    exact value  =  (MSB_nibble << 4) | LSB_nibble        per element
    base         =  all MSB nibbles  +  all group scales
    refinement   =  all LSB nibbles

`base` and `refinement` **partition** the exact bits. Concatenating them
reconstructs the INT8 page bit for bit, with no residual and no third copy.
The base is independently interpretable because it carries the scales; the
refinement is not, and is never fetched alone.

"Exact" in this spec means **the INT8 stored form**, not FP16. Quantization
from FP16 to INT8 happens on the host at trace-load time and its error is a
*model-accuracy* question measured against the golden model, never a hardware
guarantee. This is stated so the word "exact" cannot be read as "lossless
versus the original model".

### 2.2 Page geometry, chosen for bigger pages per the ruling

One page holds one `(layer, kv_head, K-or-V)` tuple for a **16-token block**,
matching the block size used by production paged-attention allocators.

| quantity | value | derivation |
|---|---|---|
| head_dim | 128 | Llama-3-8B class |
| elements per page | 2,048 | 16 tokens x 128 |
| group size | 32 | 64 groups per page |
| scales | 128 B | 64 groups x FP16 |
| **exact page, on the wire** | **2,176 B** | 2,048 B INT8 payload + 128 B scales |
| **base fetch** | **1,152 B** | 1,024 B MSB nibbles + 128 B scales |
| **refinement fetch** | **1,024 B** | LSB nibbles |
| alignment | 256 B, both planes | avoids burst splitting |

**Burst rule, non-negotiable:** no DDR transaction below 128 B. Both the base
at 1,152 B and the refinement at 1,024 B clear it by an order of magnitude,
which is the direct benefit of the bigger-page ruling. v0.2's 64 B compact
fetch violated this rule and that is what broke it.

### 2.3 Storage layout in PS DDR

    BASE_PLANE_BASE + phys_idx * 1152   -> MSB nibbles + scales
    REFN_PLANE_BASE + phys_idx * 1024   -> LSB nibbles

**Total stored bytes per page = 2,176 B = exactly the exact page.** Capacity
overhead is **1.000x**, and write traffic overhead is **1.000x**. v0.2's 1.25x
capacity penalty is gone. Split-plane layout is what makes a base-only fetch a
single contiguous burst rather than a strided gather.

---

## 3. Traffic accounting

### 3.1 The model

Let `Bb = 1152` (base), `Br = 1024` (refinement), `Be = Bb + Br = 2176`
(exact-only baseline). Let `m` be the fraction of fetches that escalate to pull
the refinement. Expected read bytes per page:

    E  =  Bb + m * Br
    E / Be  =  (1152 + 1024 m) / 2176

| m | E | E/Be |
|---|---|---|
| 0.00 | 1,152 B | **0.529x** |
| 0.25 | 1,408 B | 0.647x |
| 0.50 | 1,664 B | 0.765x |
| 0.75 | 1,920 B | 0.882x |
| 1.00 | 2,176 B | **1.000x** |

### 3.2 KVPM cannot lose on read traffic at any miss rate

At `m = 1` the design reads exactly the exact-only baseline. There is no `m` in
`[0,1]` for which it reads more. **Break-even is `m < 1.0`**, meaning the policy
is weakly better than exact-only everywhere.

Correcting my own arithmetic from earlier in this session: I quoted a break-even
of `m < 0.471` for this organisation. That was v0.2's formula `m < 1 - r`, which
assumes a fallback re-fetches the **whole** exact page. Under nesting the
fallback fetches only the missing plane, so that formula does not apply.

### 3.3 The safety property, and its vacuity, stated up front

The property that survives is:

    bytes_read  <=  n_fetch_req * 2176

It is a **safety property**. It forbids reading more than exact-only. It does
**not** certify that anything useful happens, and it is satisfied by three
degenerate policies:

| degenerate policy | E/Be | property |
|---|---|---|
| always fetch both planes immediately | 1.000x | HOLDS |
| always fetch base, always escalate | 1.000x | HOLDS |
| bypass mode, exact-only | 1.000x | HOLDS |

**A KVPM that has been switched off satisfies its own safety property.** The
property therefore never ships alone. It ships with the MEASURED achieved ratio
`bytes_read / (n_fetch_req * 2176)`, which must come in **below 1.0**, and with
`n_base_sufficient`, which counts fetches where the base sufficed. Those are
counters, labelled MEASURED. The proof half and the measured half are both
required and neither is publishable alone.

---

## 4. Content identity, and why `seq_id` is gone

v0.2 put `seq_id` inside the lookup key and then claimed two sequences with a
shared prefix would hit the same entry. They never could. Fixed as follows.

### 4.1 Identity

    page_identity  =  { tenant_id[3:0], content_hash[31:0], layer[5:0],
                        kv_head[4:0], plane_sel[0] }        = 48 bits

`content_hash` is computed **by the host** over the exact token sequence covered
by the block, together with every parameter that affects the KV values (model
id, layer, head, position base). It is supplied in the request. KVPM does not
compute it and does not need to; it treats the hash as an opaque identity.

Two sequences sharing a prompt prefix produce identical `content_hash` for the
blocks in that prefix, so they hit the same entry and the refcount increments.
That is what makes sharing fire.

### 4.2 Tenant safety is structural, not advisory

`tenant_id` is **inside** the identity. Two tenants with byte-identical prompts
therefore occupy **separate** entries and separate physical pages. Cross-tenant
deduplication is deliberately not implemented, because content-addressed sharing
across a tenant boundary is a timing side channel: a fast hit reveals that
another tenant holds that exact content. The capacity that dedup would save is
not worth a cross-tenant oracle.

### 4.3 Collision handling

A 32-bit content hash will collide. A collision under the same `tenant_id`,
`layer`, `kv_head` and `plane_sel` returns the wrong page while reporting a hit,
which is a silent correctness failure and the worst outcome in this design.

Mitigation, both required:
- the host supplies a **64-bit** hash; the low 32 bits index and tag, the high
  32 bits are stored in a **verification word** alongside the entry and compared
  on every hit,
- a mismatch increments `n_hash_mismatch`, sets `STATUS.error`, and forces the
  request down the allocate-and-fill path rather than returning data.

`n_hash_mismatch` MUST read zero on every accepted run. A non-zero value
invalidates that run's data.

---

## 5. Page table

Set-associative, in UltraRAM. The ILA cannot use URAM on this part (MEASURED,
`docs/hil/ila_budget.md`), so the page table and debug capture never compete.

| quantity | value |
|---|---|
| URAM288 geometry | 4,096 entries x 72 b |
| sets | 16,384 |
| associativity | 4-way |
| tracked resident pages | 65,536 |
| exact KV under management | 65,536 x 2,176 B = **136 MB** |

### 5.1 Entry layout

48-bit identity, 14 index bits, so the tag is **34 bits**.

| field | bits |
|---|---|
| valid | 1 |
| tag | 34 |
| phys_idx | 20 |
| state | 3 |
| refcount | 8 |
| lru | 4 |
| **total** | **70 of 72** |

A second URAM plane holds the 32-bit verification word per entry.

State encoding: `INVALID`, `ALLOCATED_EMPTY`, `BASE_RESIDENT`,
`FULL_RESIDENT`, `FILL_IN_FLIGHT`, `EVICTING`. `ALLOCATED_EMPTY` is the state
v0.2 lacked and it is what makes the fill path expressible.

### 5.2 URAM banking and port budget

This is stated as a REQUIREMENT to be proved by synthesis, not as an achieved
result. v0.2 asserted a single-cycle combined access and the review reported it
unbuildable.

URAM288 has two ports but they are **not** two independent read/write ports at
full rate for arbitrary access; cascade adds latency. The 4 ways are therefore
placed in **4 separate URAM banks**, one way per bank, so a lookup is 4
concurrent single-port reads rather than one 4-wide read.

Access classes and their cycles, to be confirmed:

| operation | banks touched | when |
|---|---|---|
| tag read, 4 ways | 4 banks, 1 read each | lookup stage |
| refcount update | 1 bank, read-modify-write | 2 cycles after hit, pipelined |
| LRU update | same bank as refcount | merged into the same RMW |

**Refcount and LRU are merged into one read-modify-write** so a hit costs one
read plus one RMW on a single bank, never two writes. A same-set back-to-back
hit is resolved by a forwarding path, not by stalling.

**Throughput target is one lookup per cycle at a pipelined latency of 4 to 6
cycles, NOT one lookup per cycle at fixed single-cycle latency.** The v0.2
claim of fixed single-cycle latency is withdrawn. Post-route Fmax must be
measured; a preliminary review estimate of 207 to 211 MHz is above the 200 MHz
target but is not yet our own measurement and is labelled NOT VERIFIED.

---

## 6. Allocation and the free list

Physical pages come from a free list in BRAM as an index FIFO, initialised by
the host at reset to `MANAGED_PAGES` entries. Allocation pops, free pushes.

Conservation, invariant 12, with the ledger sides defined so the equation is
actually true:

    pages_in_free_list  +  pages_with_valid_pte  ==  MANAGED_PAGES

A page with `refcount > 1` sits on the `pages_with_valid_pte` side **once**,
not once per reference. `refcount` counts references to a page; it does not
count pages. v0.2 never said this and the equation was false at reset.

The review noted this invariant is satisfiable by a design that leaks every
page. It is, so it is paired with `n_alloc - n_free == pages_with_valid_pte`,
which a leaking design fails.

---

## 7. Reference counting and eviction

### 7.1 Refcount semantics, stated once

- allocation for a new identity sets `refcount = 1`
- a lookup hit from a sequence not already holding the page increments
- `RELEASE` decrements
- at `refcount == 0` the page becomes **evictable** but is NOT freed
  immediately; it stays resident so a later hit can revive it
- eviction of a `refcount == 0` page returns `phys_idx` to the free list

This resolves the review's finding that invariant 11 either made eviction
unreachable or licensed evicting a live page. Eviction is reachable precisely
because zero-refcount pages remain resident.

Saturation at 255 is an **error**, not a clamp: it sets `STATUS.error` and
increments `n_refcount_sat`, because a wrapped refcount frees a page another
sequence is still reading.

### 7.2 Eviction

On allocation failure, evict the highest-LRU way in the target set with
`refcount == 0`. If all 4 ways have `refcount > 0`, the allocation **fails
cleanly**: `STATUS.error` is set and `n_evict_fail` increments. **A referenced
page is never evicted.** No silent eviction, no forced eviction.

---

## 8. THE MISS SEQUENCE, which v0.2 did not have

This is the path whose absence made v0.2 unbuildable: an allocator `phys_idx`
had no relation to where the host wrote the page.

Resolution: **the host does not choose physical addresses.** It writes page
content through KVPM, which returns the `phys_idx` it allocated. DDR is written
only at addresses KVPM assigned.

On a lookup miss for identity `I`:

1. **allocate.** Pop `phys_idx`. Install the PTE for `I` in state
   `ALLOCATED_EMPTY`, `refcount = 1`. Write the verification word.
2. **signal.** Emit a response with `status = MISS_NEED_FILL` carrying `I` and
   the allocated `phys_idx`. **No data is returned and no DDR read is issued.**
   A read of `ALLOCATED_EMPTY` would return another page's stale bytes, which is
   the exact bug v0.2 had.
3. **host fills.** The host issues `FILL_BASE` and `FILL_REFN` writes for that
   `phys_idx`. KVPM moves the state `ALLOCATED_EMPTY` to `FILL_IN_FLIGHT` to
   `FULL_RESIDENT` and asserts that both planes were written before any read.
4. **retry.** The host reissues the original request. It now hits.

Requests for a page in `ALLOCATED_EMPTY` or `FILL_IN_FLIGHT` do not read DDR.
They return `MISS_NEED_FILL` or stall behind the fill, selected by a build
parameter. Invariant 15 asserts that **no DDR read is ever issued against a page
not in `BASE_RESIDENT` or `FULL_RESIDENT`.**

### 8.1 Failure sequence

| condition | action | counter |
|---|---|---|
| free list empty and no evictable way | reject, `STATUS.error` | `n_evict_fail` |
| verification word mismatch on hit | reject, force allocate path | `n_hash_mismatch` |
| refcount saturate | reject, `STATUS.error` | `n_refcount_sat` |
| `RELEASE` for an absent or already-evicted page | ignore, no state change | `n_release_stale` |
| fill watchdog expiry | invalidate the PTE, return `phys_idx` to the free list | `n_fill_timeout` |
| escalation watchdog expiry | fetch the refinement **once**, then stop | `n_timeout` |

`n_release_stale` is counted rather than treated as an error because a host
racing teardown against eviction is legitimate.

---

## 9. Interfaces

### 9.1 AXI4-Stream

| stream | width | direction |
|---|---|---|
| s_axis_req | 128 b | in |
| m_axis_resp | 128 b | out |

Request: `identity` 48 b, `hash_hi` 32 b, `op` 4 b, `flags` 4 b, `txn_id` 8 b,
reserved. Ops: `LOOKUP_FETCH`, `FILL_BASE`, `FILL_REFN`, `RELEASE`, `PIN`.

Response carries `txn_id` and a `status` field: `OK_BASE`, `OK_FULL`,
`MISS_NEED_FILL`, `REJECT`.

**Only `LOOKUP_FETCH` increments `n_fetch_req`.** v0.2 counted all four op types
in one `n_req` and then divided by it, which falsified three invariants. Op
counts are separate: `n_op_fill`, `n_op_release`, `n_op_pin`.

Full TVALID/TREADY backpressure; payload stable while TVALID is high and TREADY
is low, asserted as a protocol property.

### 9.2 AXI4-Lite control, 4 KB aperture

| offset | reg | meaning |
|---|---|---|
| 0x00 | CTRL | b0 start, b1 soft reset, b2 bypass (always fetch both planes), b3 sharing disable, b4 stall-on-fill |
| 0x04 | STATUS | b0 idle, b1 done, b2 error, b3 timeout, b4 evict_fail, b5 refcount_sat, b6 hash_mismatch |
| 0x08..0x14 | BASE_PLANE_BASE, REFN_PLANE_BASE | 64 b each |
| 0x18 | CONF_THRESHOLD | offline-calibrated constant |
| 0x1C | TIMEOUT_CYCLES | escalation watchdog |
| 0x20 | FILL_TIMEOUT_CYCLES | fill watchdog |
| 0x24 | MANAGED_PAGES | free list init size |
| 0x40..0xAC | counters | RO |

Three ablation controls, all required: bypass pins the denominator, sharing
disable separates the sharing benefit from the precision benefit, stall-on-fill
selects the miss discipline.

### 9.3 PS DDR access

S_AXI_HP0_FPD at 128 bits. UG1085 Table 35-1 gives HP ports as 32/64/128 bit;
DS925 Table 6 gives FAXICLK max 333 MHz. Target 200 MHz, swept upward only
after functional correctness.

The measured PL clock on this board is 301.03 MHz and the debug hub clock MUST
be divided at synthesis or ILA core discovery fails as Labtools 27-3123.

---

## 10. Counters

| counter | proves |
|---|---|
| n_fetch_req | denominator. `LOOKUP_FETCH` only |
| n_base_fetch | base plane reads |
| **n_base_sufficient** | **base fetched, refinement never needed. The non-vacuousness witness** |
| n_refn_fetch | escalations |
| bytes_read | the headline measured number |
| bytes_written | so total bytes can be reported |
| n_pt_hit, n_pt_miss | translation behaviour |
| n_alloc, n_free, n_evict | allocator behaviour |
| n_evict_fail | should be zero on a sized trace |
| n_share_hit | the prefix-sharing benefit |
| n_refcount_sat | MUST be zero |
| n_hash_mismatch | MUST be zero |
| n_release_stale | informational |
| n_fill_timeout, n_timeout | watchdog firings |
| n_burst_lt_128 | MUST be zero |
| n_stall_cycles, n_cycles | rate derivation |

---

## 11. Invariants

1. every accepted request produces exactly one response
2. response `txn_id` equals request `txn_id`
3. no response without a prior request
4. queue occupancy never exceeds declared depth
5. TVALID payload stable under backpressure
6. `n_base_fetch + n_refn_fetch >= n_fetch_req`
7. `n_burst_lt_128 == 0`
8. `bytes_read <= n_fetch_req * 2176`, the safety property of section 3.3
9. in bypass mode, `bytes_read == n_fetch_req * 2176` exactly
10. **at most one refinement fetch per request**, watchdog included. The
    watchdog is one-shot per request, which v0.2 did not state and which was
    what let it breach the bound it was supposed to enforce
11. a page with `refcount > 0` is never evicted and never freed
12. `pages_in_free_list + pages_with_valid_pte == MANAGED_PAGES`, every cycle
13. `n_alloc - n_free == pages_with_valid_pte`, defeating a leaking design
14. `n_refcount_sat == 0` and `n_hash_mismatch == 0`
15. **no DDR read is issued against a page not in `BASE_RESIDENT` or
    `FULL_RESIDENT`**
16. every PTE in `FILL_IN_FLIGHT` has exactly one outstanding fill

Invariants 11 to 16 are the manager's correctness core. Invariant 8 is the
headline number **and is vacuously satisfiable per section 3.3**, so it is never
reported without the measured achieved ratio.

---

## 12. Where KVPM loses

- **`m` near 1.0**: the policy degenerates to exact-only. It does not lose, but
  it wins nothing, and `n_base_sufficient` near zero is the signal.
- **working set above 136 MB**: the page table thrashes. Hard structural limit
  of the 16-URAM table, not a tuning issue.
- **no shared prefixes**: the refcount path contributes zero and `n_share_hit`
  stays at zero. Trace selection must include real shared prefixes or this is
  untested rather than disproved.
- **fill-dominated workloads**: every miss costs a host round trip. A trace
  that is mostly cold misses measures the fill path, not the fetch policy.
- **INT8 is too coarse for the model**: accuracy fails at the golden-model
  comparison and no traffic result matters.
- **sub-1B ternary scale**: published work reaches only 19 to 21 percent of the
  DDR bandwidth ceiling, so the part is logic-bound not bandwidth-bound. KVPM
  must not be evaluated there.

---

## 13. Evidence required

| claim | evidence | label |
|---|---|---|
| never exceeds exact-only | invariant 8 asserted in RTL, unviolated across every HIL run | proved + asserted |
| **the policy does useful work** | **`bytes_read / (n_fetch_req * 2176)` below 1.0, and `n_base_sufficient > 0`, read from the aperture on hardware** | **MEASURED** |
| bytes reduced | bypass versus enabled, same trace | MEASURED |
| prefix sharing works | `n_share_hit`, CTRL b3 clear versus set | MEASURED |
| delivery correct | scoreboard bit-compare against golden model, zero mismatches | checked |
| page conservation | invariants 12 and 13 unviolated | proved + asserted |
| no shared page evicted | invariant 11 unviolated | proved + asserted |
| no read of unfilled page | invariant 15 unviolated | proved + asserted |
| quantization error | measured against golden model, reported as a curve | MEASURED |
| burst rule | `n_burst_lt_128 == 0` | MEASURED |
| timing closed | post-route WNS, TNS, WHS, THS, failing endpoints, before and after ILA | MEASURED |
| clock is real | free-running counter over JTAG, as done at 301.03 MHz | MEASURED |

---

## 14. Parameters

| parameter | range | default |
|---|---|---|
| TOKENS_PER_BLOCK | 8, 16, 32 | 16 |
| HEAD_DIM | 64, 128 | 128 |
| GROUP_SIZE | 16, 32, 64 | 32 |
| PT_URAMS | 8 to 32 | 16 |
| PT_WAYS | 2, 4, 8 | 4 |
| MANAGED_PAGES | 4096 to 65536 | 65536 |
| QUEUE_DEPTH | 8 to 64 | 16 |
| CONF_BITS | 2 to 8 | 4 |
| HASH_BITS | 48, 64 | 64 |

Budget at defaults: page table 16 URAM plus a verification plane, of 96; free
list and queues under 100 KB BRAM; ILA 64 BRAM tiles of 312 (MEASURED). No
resource class oversubscribed, and ILA and page table cannot contend because the
ILA cannot use URAM on this part.

---

## 15. Corrections to my own earlier statements

Recorded because the project rule is that a disproven claim is a result.

1. **1.25x ceiling: WRONG.** v0.2's compact page violated its own burst floor.
2. **1.5x ceiling: superseded.** Correct only for the rejected organisation.
3. **Break-even `m < 0.471` for the nested design: WRONG.** I applied the
   non-nested formula. The correct answer is `m < 1.0`; it cannot lose.
4. **"The workflow finished": WRONG.** A research sub-workflow finished. The
   project has completed no golden model, no RTL, no verification, no
   implementation, no software, no HIL and no claims ledger.
5. **"Definitively low threat" for ELMoE-3D: TOO STRONG.** Keyword counts prove
   words absent, not concepts absent. Correct wording is "low collision against
   the current claim".
6. **"PageGuard": RETIRED.** Collides with a shipping product.

---

## 16. Gates that must pass before Phase 4

1. **Read SAS** (EuroSys 2026, 10.1145/3767295.3769364) or explicitly suspend
   every affected novelty claim. Needs ACM access.
2. **30-paper full-text matrix** with page or section citations. Screening 223
   abstracts does not satisfy this.
3. **Four-architecture weighted trade study**, scoring below 80 rejects, one-page
   decision carrying the five closest works, a falsifiable hypothesis, its
   disproof experiment and the pivot. **Must include the nested
   base-plus-refinement organisation as a scored candidate**, since it arrived
   after the last study and dominates the option that study selected.
4. **Name collision check**, or keep an internal codename.
5. **Adjudicate all 23 BLOCKING review findings.** Five are fixed here; 18 are
   unadjudicated, including a claim that two published designs already achieve
   1.0x with no capacity overhead. If that holds it attacks this contribution
   directly, because 1.0x is now exactly what KVPM achieves.
6. **Prove the URAM banking and port budget by synthesis**, not by assertion.
7. **Independent acceptance of the novelty and architecture boundary.**

KVPM is a candidate. It is not the selected design.
