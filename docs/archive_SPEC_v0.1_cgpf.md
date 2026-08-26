# SPEC: CGPF, Confidence-Gated Precision Fetch

Working name. A trademark and project-name collision check is REQUIRED before
any public use; it has not been done.

Version 0.1, 2026-08-23. Written after the trade study, the red team review and
the blocking prior-art sweep, and before any RTL exists.

---

## 1. Scope

CGPF is a PL-side engine on a ZCU104 that sits in the KV-page fetch path
between a host process in PS DDR and a consumer. For each page request it:

1. predicts which page will be needed next,
2. maintains a confidence for that prediction,
3. selects WHICH STORED REPRESENTATION of the predicted page to fetch, a
   compact INT4 copy when confident or the exact FP16 copy when not,
4. detects a wrong-page prediction and issues an exact fetch with a bounded
   worst-case cost,
5. counts everything needed to check those claims from outside.

### Explicit non-goals

- CGPF does NOT run a language model. The board replays host-generated traces.
- CGPF does NOT perform attention, GEMM or any model arithmetic.
- CGPF does NOT claim datacenter relevance. See docs/research/amd_vs_intel_platform.md:
  Agilex 7 M-Series has roughly 40 to 57 times this board's memory bandwidth.
- CGPF does NOT store the KV cache. On-chip capacity is 4.75 MB against a
  512 MB single context, a factor of 108 short.
- No claim of protocol compliance with PCIe, CXL, NVLink or UALink.
- No power measurement. Tool estimates only, labelled as estimates.

---

## 2. THE GUARANTEE, SPLIT IN TWO

This is the most important section. A single "exactness" claim would be false.

### 2.1 Delivery exactness: ENFORCED IN HARDWARE

If the predictor fetches the wrong page, the consumer's request misses, the
engine issues an exact fetch of the correct page, and the consumer always
receives the page it asked for.

Worst-case cost, derived in docs/reviews/red_team_findings.md: if every
confident fetch is wrong, total bytes are (1 + r) times exact fetch, where r is
the compact-to-exact size ratio. At INT4 against FP16, r = 0.25, so the bound
is **1.25x exact fetch**. This is a number, not an adjective, and it is
checkable from the counters.

### 2.2 Value exactness: RISK-CONTROLLED OFFLINE, NOT ENFORCED

If the predictor fetches the RIGHT page but the INT4 representation is
insufficient for the consumer's numerical needs, the hardware CANNOT detect
this. Detecting it would require already holding the exact data, which defeats
the purpose.

Therefore value exactness is not a hardware guarantee. It is controlled a
priori: the confidence threshold is selected offline by a finite-sample
risk-control procedure (Learn then Test, arXiv 2110.01052) on held-out traces,
targeting a stated violation rate epsilon, and the achieved rate is MEASURED
against the golden model rather than asserted.

**Any public statement must carry this split. Claiming exactness without it
would be false.**

---

## 3. Data model

### 3.1 KV page

The unit of prediction, storage and transfer.

| field | value | rationale |
|---|---|---|
| page size, exact | 256 B | at or above the 128 to 192 B burst sweet spot measured in docs/research/platform_envelope.md |
| page size, compact | 64 B | r = 0.25 |
| alignment | 256 B, both regions | avoids burst splitting at the DDR controller |
| page id | 24 bits | layer 6 b, head 5 b, token-block 13 b |

A page holds one (layer, kv_head, token_block) tuple. Token block size is a
build parameter chosen so the exact page is 256 B.

**Burst rule, non-negotiable:** no DDR transaction below 128 B. The measured
penalty at 16 B bursts is up to 70 percent of throughput, which would erase the
entire benefit of the design.

### 3.2 Dual-representation storage in PS DDR

Two regions, both written by the host at trace-load time:

    EXACT_BASE   + page_id * 256   -> FP16 page, 256 B
    COMPACT_BASE + page_id *  64   -> INT4 page,  64 B

Cost, recorded because the trade study missed it and the red team caught it:
**1.25x DDR capacity and 1.25x write traffic.** In decode each page is written
once and read once per subsequent token, so at 2,048 context the extra write is
0.024 percent of the benefit. The evaluation MUST report total bytes including
writes. Reporting read savings alone is forbidden.

### 3.3 Numerical format of the compact representation

Group-quantized INT4, reusing the proven scheme from kvcache-compress-engine:

- group size 32 elements
- per-group FP16 scale
- symmetric, round-half-to-even, saturating at the INT4 bounds
- outlier bitmap: up to 2 values per group retained at FP16

Rounding and saturation are bit-exact against the Python golden model. Any
mismatch is a test failure, not a tolerance.

---

## 4. Interfaces

### 4.1 AXI4-Stream

| stream | width | direction | TLAST |
|---|---|---|---|
| s_axis_req | 32 b | in | per request |
| m_axis_resp | 128 b | out | per page |

Request word: page_id 24 b, tenant_id 4 b, flags 4 b.
Response carries TID equal to the request's transaction id so simulation and
ILA captures can be reconciled transaction by transaction.

Backpressure: full TVALID/TREADY. Payload MUST remain stable while TVALID is
high and TREADY is low. Asserted as a protocol property.

### 4.2 AXI4-Lite control, 4 KB aperture

| offset | reg | access | meaning |
|---|---|---|---|
| 0x00 | CTRL | RW | bit0 start, bit1 soft reset, bit2 bypass (exact-always mode) |
| 0x04 | STATUS | RO | bit0 idle, bit1 done, bit2 error, bit3 timeout |
| 0x08 | EXACT_BASE_LO | RW | |
| 0x0C | EXACT_BASE_HI | RW | |
| 0x10 | COMPACT_BASE_LO | RW | |
| 0x14 | COMPACT_BASE_HI | RW | |
| 0x18 | CONF_THRESHOLD | RW | the offline-calibrated constant |
| 0x1C | TIMEOUT_CYCLES | RW | fallback watchdog |
| 0x40..0x7C | counters, see section 7 | RO | |

Bypass mode at CTRL bit2 is the ablation control: it forces exact-always
fetching, which is the baseline every measurement is compared against.

### 4.3 PS DDR access

Through S_AXI_HP0_FPD at 128 bits. UG1085 Table 35-1 gives HP ports as
32/64/128 bit; DS925 Table 6 gives FAXICLK max 333 MHz. Design target clock is
200 MHz initially, swept upward only after the design is functionally correct.

---

## 5. Microarchitecture

    s_axis_req
        |
    [ingress + page id decode]
        |
    [predictor table] --------> [confidence accumulator]
        |                              |
        |                       [threshold compare] <- CONF_THRESHOLD
        |                              |
    [representation selector] <--------+
        |
    [DDR request builder] -- coalesce to >=128 B --> AXI HP0
        |
    [response assembler] --+
        |                  |
    [hit/miss detect]      |
        | miss             |
    [exact refetch path]---+
        |
    m_axis_resp

Blocks: ingress, predictor table, confidence accumulator, threshold compare,
representation selector, DDR request builder with coalescing, response
assembler, miss detector, exact refetch sequencer, counter block.

No placeholder modules in the release branch.

---

## 6. Reset, clock, error semantics

- single clock domain in the PL at the design clock; the only crossing is the
  AXI-Lite aperture, handled by the standard interconnect
- synchronous active-low reset; every queue and every counter clears
- reset asserted mid-transaction: the engine drops in-flight state, returns to
  idle, and sets STATUS.error. No partial response is emitted.
- the fallback watchdog at TIMEOUT_CYCLES bounds any stall; on expiry the
  engine issues the exact fetch unconditionally and increments the timeout
  counter. This is the mechanism that makes the 1.25x bound hold even if the
  predictor path wedges.

---

## 7. Performance counters, all 32 bit, all RO

| counter | proves |
|---|---|
| n_req | denominator for every rate |
| n_compact_fetch | how often the cheap path was taken |
| n_exact_fetch | includes both a priori exact and fallback |
| n_fallback | wrong-page detections |
| n_timeout | watchdog firings |
| bytes_read | THE headline number, total DDR read bytes |
| bytes_written | so total bytes can be reported, not read-only |
| n_stall_cycles | backpressure accounting |
| n_burst_lt_128 | must stay ZERO; a non-zero value invalidates the burst rule |
| n_cycles | free-running, for rate derivation |

---

## 8. Invariants, to be asserted in RTL and checked on hardware

1. every accepted request produces exactly one response, no drops, no duplicates
2. response TID equals request TID
3. no response without a prior request
4. queue occupancy never exceeds its declared depth
5. TVALID payload stable under backpressure
6. n_compact_fetch + n_exact_fetch >= n_req
7. n_burst_lt_128 == 0
8. bytes_read <= 1.25 * (n_req * 256) at all times, the bound made checkable
9. in bypass mode, bytes_read == n_req * 256 exactly

Invariant 8 is the design's central claim expressed as a runtime assertion. If
it ever fails, the headline claim is false and the ILA must catch it.

---

## 9. Analytical model, and where the design LOSES

From the red team derivation, expected bytes relative to exact fetch:

    E/Bf = p*r + (1 - p + p*m)

with p the confident fraction, m the miss rate among confident fetches, r the
size ratio. The design beats exact fetch iff **m < 1 - r**, that is m < 0.75 at
INT4.

**Regimes where CGPF loses, preserved in the final report as required:**

- m >= 0.75: the fallback traffic exceeds the saving. Predictor quality below
  this floor kills the design.
- page size forced below 128 B: the burst penalty erases the benefit
  regardless of prediction quality.
- very short contexts, where the 1.25x write overhead is not amortised over
  enough reads. Below roughly 64 tokens of context the write cost is material.
- bypass-mode comparison on a workload with no reuse: nothing to predict.
- **sub-1B ternary scale.** Published work at that scale reaches only 19 to 21
  percent of the DDR bandwidth ceiling, so the part is logic-bound rather than
  bandwidth-bound and reducing bytes moved buys nothing. CGPF has nothing to
  prove in that regime and must not be evaluated there.

---

## 10. Evidence required for each claim

| claim | evidence |
|---|---|
| bytes reduced versus exact | bytes_read and bytes_written in bypass versus enabled, same trace |
| worst case bounded at 1.25x | invariant 8 asserted in RTL, never violated across all HIL runs |
| delivery always exact | scoreboard bit-compare against golden model, zero mismatches |
| value exactness at epsilon | measured violation rate against golden model on held-out traces, reported as a curve not a point |
| burst rule held | n_burst_lt_128 == 0 on every run |
| timing closed | post-route WNS, TNS, WHS, THS, failing endpoint count, before and after ILA |
| clock is real | measured from a free-running counter over JTAG, as already done at 301.03 MHz |

---

## 11. Parameter limits

| parameter | range | default |
|---|---|---|
| PAGE_BYTES | 128, 256, 512 | 256 |
| RATIO_R | 0.25, 0.5 | 0.25 |
| PRED_TABLE_ENTRIES | 256 to 4096 | 1024 |
| QUEUE_DEPTH | 8 to 64 | 16 |
| CONF_BITS | 2 to 8 | 4 |

On-chip budget check: at 1024 entries the predictor table plus confidence
accumulator is well under 100 KB, against 4.75 MB available, leaving ample room
for ILA capture storage.

---

## 12. Open items before RTL

1. project name collision check, not yet done
2. trace source selection and licensing, not yet done
3. the four wide-coverage research agents are still running; if any returns an
   anticipating reference, this spec is revised before implementation
