# ILA hardware check: step-by-step procedure

How to confirm the KV lifecycle guard works on silicon, what to watch, and what
each observation rules in or out. Written so the check is falsifiable rather
than a screenshot of a green light.

---

## 0. Probe map

The 196-bit probe is `kv_guard_bd_i/kv_lifecycle_guard_0_dbg_probe[195:0]`.

| bits | field | why you care |
|---|---|---|
| 7:0 | `refcount` | safe-reuse predicate term |
| 15:8 | `reservation` | safe-reuse predicate term |
| 21:16 | `inflight` | safe-reuse predicate term |
| 25:22 | `fill_pending` | safe-reuse predicate term |
| 33:26 | `generation` | actual page generation |
| 41:34 | `expected_generation` | descriptor's generation |
| 47:42 | `lifecycle_slot` | which slot |
| 53:48 | `phys_idx` | which frame |
| 57:54 | `transaction_tag` | which AXI tag |
| 58 / 59 | `arvalid` / `arready` | AR handshake |
| 60 / 61 / 62 | `rvalid` / `rready` / `rlast` | R channel |
| 65 | `reuse_req` | a reuse was requested |
| **66** | **`reuse_grant`** | **the interlock said YES** |
| **67** | **`reuse_refused`** | **the interlock said NO** |
| 69 / 70 | `stale` / `payload_mismatch` | generation and signature checks |
| **144** | **`rst_n`** | **is the guard even out of reset** |
| **160:145** | **heartbeat** | **free-running counter, NOT reset** |

---

## 1. Liveness first. Never skip this.

**Do not interpret any capture until liveness passes.** Every field above reads
zero both when the guard is working-and-idle and when it is held in reset. That
ambiguity is why bits 144 and 145 exist.

```tcl
run_hw_ila -trigger_now [get_hw_ilas hw_ila_1]
wait_on_hw_ila [get_hw_ilas hw_ila_1]
write_hw_ila_data -force -csv_file live.csv \
  [upload_hw_ila_data [get_hw_ilas hw_ila_1]]
```

Decode the probe column of the first and last sample:

| observation | meaning | action |
|---|---|---|
| heartbeat **advances**, `rst_n = 1` | clock and reset both good | proceed to step 2 |
| heartbeat advances, `rst_n = 0` | clock good, **reset stuck asserted** | fix the reset path, not the clock |
| heartbeat **frozen**, any `rst_n` | **clock is not reaching the guard** | fix clocking; nothing else matters |
| capture returns 0 samples | ILA not armed or hub unreachable | see `ps_pl_isolation.md` |

The heartbeat is the single most useful signal on the probe. It is deliberately
not reset so that a frozen value is unambiguous.

---

## 2. Capture settings

At 187.5 MHz, 2048 samples is a **10.9 microsecond** window. JTAG-driven writes
land milliseconds apart. Capturing every cycle will therefore fill the buffer
with idle and show you nothing.

| setting | value | why |
|---|---|---|
| Trigger mode | `ADVANCED` | needed to express a compound condition |
| Capture mode | `BASIC` | storage qualification: record only interesting cycles |
| Capture condition | `reuse_req == 1` | brackets every interlock decision |
| Trigger position | `1024` (mid-window) | see the approach and the aftermath |
| Data depth | 2048 | 13 BRAM tiles, fine on this part |

Use `ALWAYS` capture **only** for the step-1 liveness check, where you want raw
consecutive cycles to watch the heartbeat increment.

---

## 3. Trigger on the event that should happen

Arming on `reuse_grant` (bit 66) is a trap. If the design is correct it never
fires, and "never fired" is indistinguishable from a broken ILA. It proves
nothing on its own.

**Primary trigger: `reuse_refused` (bit 67).** This is the event that *should*
occur when a reuse is attempted against a draining page.

```tcl
set p [lindex [get_hw_probes -of_objects [get_hw_ilas hw_ila_1]] 0]
# bit 67 high, all others don't-care. 196 bits, MSB first.
set patt "[string repeat x 128]1[string repeat x 67]"
set_property TRIGGER_COMPARE_VALUE eq196'b$patt [get_hw_probes $p]
set_property CONTROL.TRIGGER_POSITION 1024 [get_hw_ilas hw_ila_1]
run_hw_ila [get_hw_ilas hw_ila_1]
```

Keep `reuse_grant` as a **violation trap** in a second run: if it ever fires
while bits 25:0 are nonzero, the safety claim is falsified.

---

## 4. Stimulus

The guard is command-driven; it does nothing until written. Drive it over the
JTAG-AXI master so the PS is not in the loop:

```tcl
reset_hw_axi [get_hw_axis hw_axi_1]        ;# UG908 requires this first
proc w {a d} {
  create_hw_axi_txn t [get_hw_axis hw_axi_1] -type write -address $a -data $d
  run_hw_axi [get_hw_axi_txns t]; delete_hw_axi_txn [get_hw_axi_txns t]
}
w A0000008 00000011   ;# CTRL: enable + sig_check_en. BIT 4 IS NOT OPTIONAL.
w A0000014 70000000   ;# window base
w A000001C 70010000   ;# window limit
w A0000030 00001249   ;# descriptor
w A0000038 70000100   ;# read address, inside the window
w A0000040 CAFEBABE   ;# expected signature
w A0000034 00000020   ;# cfg: sig check on
w A0000044 00000001   ;# GO
w A0000050 00000009   ;# reuse config, same slot
w A0000054 00000001   ;# reuse GO, racing the outstanding read
```

**`CTRL[4]` (`sig_check_en`) is the trap.** `axi_lite_regs.sv:427` computes
`o_req_sig_check = cmd_cfg_r[5] & ctrl_sigchk`. Set the per-command bit but
forget `CTRL[4]` and the payload comparator is silently disabled for the whole
run. That exact omission once made the top-level testbench "pass".

---

## 5. What a pass looks like

Read the counters back over the same AXI master:

| offset | counter | expected after the stimulus above |
|---|---|---|
| `0x060` | `reuse_refused` | **≥ 1** |
| `0x064` | `stale` | 0 unless generations were bumped |
| `0x068` | `unsafe_commit` | **0** |
| `0x06C` | `payload_mismatch` | 0 with a matching signature |
| `0x088` / `0x08C` | `dispatch` / `accept` | ≥ 1 |

Then open the trigger sample in the capture and check bits 25:0.

**PASS:** `reuse_refused` fired, and at that sample at least one of `refcount`,
`reservation`, `inflight`, `fill_pending` is nonzero. The guard refused because
the page was genuinely still in use.

**FAIL, spurious refusal:** refused with all four terms zero. The guard is
rejecting safe reuses.

**FAIL, safety violated:** `reuse_grant` fired with any of the four nonzero. A
page was released for reuse while still referenced or in flight. This is the
condition the whole design exists to make impossible.

**INCONCLUSIVE:** nothing fired and the counters are zero. The stimulus did not
create a draining page. Not a pass. Re-check that `CMD_GO` was accepted
(`dispatch` and `accept` should be nonzero) before drawing any conclusion.

---

## 6. Common failures and what they actually mean

| symptom | real cause |
|---|---|
| `[Labtools 27-3361] debug hub not detected` | PS-PL isolation not removed. See `ps_pl_isolation.md`. |
| ILA enumerates but every field reads 0 | check the heartbeat before anything else |
| `AXI TRANSACTION TIMED OUT` | no response at all: slave held in reset, or clock dead |
| `AXI TRANSACTION FAILED` with a resp code | decode/slave error: address map, not reset |
| Capture is all idle | `ALWAYS` capture mode with millisecond-spaced stimulus. Use `BASIC`. |
| Trigger never fires on `reuse_grant` | expected. That is the trap trigger, not evidence. |
