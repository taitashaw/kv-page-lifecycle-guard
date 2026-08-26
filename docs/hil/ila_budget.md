# ILA capacity and cost on XCZU7EV, MEASURED

Provenance: 28 out-of-context syntheses of ILA v6.2 on `xczu7ev-ffvc1156-2-e`
in Vivado 2025.2, primitives counted by REF_NAME in each post-synthesis
checkpoint. Raw data preserved at `measured/ila_measured_xczu7ev.csv` (28 rows).
Empirical models validated against 8 held-out configurations: LUT within 4%,
FF within 1.1%.

## Why this had to be measured rather than looked up

**AMD publishes no ILA resource model for this part.** PG172 v6.2 is dated
2016-10-05, is still the current revision, and Vivado 2025.2 still ships ILA
v6.2. Its v6.0 revision note reads "Moved Resource Utilization to HTML"; the
replacement page characterises **v6.0 on Vivado 2015.3 for Kintex-7 and Virtex
UltraScale only**, with configurations named mode1/2/3 that are never defined.
No UltraScale+, no Zynq. UG908 defers resource questions back to PG172. So there
is no citable number for this device and every figure below is our own.

## The three findings that change the plan

### 1. URAM is unavailable to the ILA on this part

URAM288 count was **0 in all 28 configurations**. Root cause read from the
installed IP: in `ila_v6_2/component.xml`, `C_RAM_STYLE` is a fixed model
parameter valued `SUBCORE`, not user-settable, and there is no
`C_MEMORY_TYPE`. UG908 confirms `C_MEMORY_TYPE` (0=BRAM, 1=URAM) is **Versal
only**, and the `axis_ila` IP that supports URAM declares only Versal families.

**Consequence for CGPF: the 96 URAM cannot absorb any capture depth. The ILA
competes with the design for the 312 BRAM and nothing else.** That matters
because a KV page manager wants URAM for page storage, so the two do not fight.

### 2. Cost is a function of the PRODUCT, not the split

`BRAM_tiles = ceil(N_probes x W_probe x Depth / 32768)`, exact within 0 to 12%
across all 28 configs. At 128 bits x 4096 deep, all four splits cost **14.5
tiles identically**, but LUTs grow with probe count: 1x128b costs 787 LUT while
32x4b costs 1,975 LUT for the same visibility. **Concatenate into wide probes.**

Depth is exactly linear: 1024 to 131072 deep at 32 bits goes 1, 2, 4, 7.5, 15,
30, 60, 120 tiles.

### 3. ADVANCED trigger is free in BRAM

At 8x32x4096: ADVANCED costs +1,568 LUT and +2,184 FF over BASIC, and **+0
BRAM**. That is 0.7% of the device LUTs. If the trigger state machine is wanted
for the HIL gate, it does not touch the capture budget. By contrast MU_CNT is
the most expensive knob in the IP: MU_CNT=16 costs 4.7x the LUT and 6.4x the FF
of MU_CNT=1, and buys back no BRAM. Leave it at 1, or 2 if capture control is
enabled.

Hard constraint found by build failure, not by documentation:
```
ERROR: [IP_Flow 19-3458] Validation failed for parameter
'All Probe Same Mu Cnt(ALL_PROBE_SAME_MU_CNT)'. Value '1' is out of the range (2,16)
```
Enabling `C_EN_STRG_QUAL` forces `ALL_PROBE_SAME_MU_CNT >= 2`; one comparator is
consumed by capture control, leaving 15 of 16 usable.

Input pipeline stages obey an exact law: `FF_cost = pipe_stages x W_total`, zero
LUT, zero BRAM. UG908 (not PG172) recommends raising it when the ILA itself
causes the timing failure. Each stage adds a cycle of skew, so pipeline a
related probe group together or the waveform will misalign and lie.

## THE ONE THAT WILL BITE THE HIL GATE

Our measured PL clock is **301.03 MHz** (docs/hil/smoke_test_01_jtag.md). UG908
"Debug Cores Clocking Guidelines" recommends the debug hub clock be **around 100
MHz or less**, with the JTAG clock 2.5x slower than the hub clock. Driving
`dbg_hub/clk` from the 301 MHz net without the divider is the most likely way
core discovery fails, and it presents as a message that never mentions a clock:

```
WARNING: [Labtools 27-3123] The debug hub core was not detected at User Scan Chain 1 or 3.
```

Mitigation, to be applied after `synth_design` and before implementation:
```tcl
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER true     [get_debug_cores dbg_hub]
```
Also correcting folklore: the strings "Failed to reset debug hub" and "clock is
not free running" appear nowhere in UG908. The real codes are **27-3123** (hub
clock inactive) and **27-1433** (core clock inactive). Grep for those.

## Tcl API traps verified against the installed 2025.2 binary

- The `hw_*` commands **do not exist until `open_hw_manager` runs.** Existence
  guards placed before it will always fail.
- **Singular forms do not exist**: `program_hw_device` and `get_hw_ila_data` are
  ABSENT; only `program_hw_devices` and `get_hw_ila_datas` exist. UG908's own
  command tables list the singular spellings and are wrong.
- `wait_on_hw_ila -timeout` is in **MINUTES**, not seconds.
- Magnitude operators `lt le gt ge` require `CONTROL.TRIGGER_MODE ADVANCED_ONLY`.
  The full operator token set, recovered from `libxv_labtools.so` because AMD
  documents only the GUI symbols, is `eq ne neq lt le gt ge`.
- When several debug probes share one physical probe port, only AND and NAND
  work; OR/NOR need separate ports. This is a design-time decision that cannot
  be fixed at runtime.
- PG172 Table 2-2 footnote 1 still says 1 to 4 match units and is stale;
  `component.xml` gives `minimum="1" maximum="16"`.

The full verified capture script is in `vivado/hil_capture.tcl` when Phase 7
opens. The API is stable: UG908 command tables are byte-for-byte identical
across 2021.1, 2023.1, 2024.2, 2025.2 and 2026.1.

## BUDGET DECISION for this project

Device: BRAM=312, URAM=96, LUT=230400, FF=460800, DSP=1728 (read from Vivado's
part database, not a datasheet).

Because depth must be a power of two, ILA cost quantises to 64, 128 or 256
tiles. With a functional design at ~30% of BRAM (94 tiles), 218 tiles are free,
but 256 tiles will not coexist with the design. **So 128 tiles and 218 tiles buy
the same achievable depth. The extra 90 tiles buy nothing.**

**Adopted: 8 probes x 32 bits x 8192 deep, 64 tiles, 20.5% of device BRAM.**
Total with a 30% design is ~50% BRAM, comfortable for placement. Fabric cost
~1,190 LUT and ~2,430 FF, both 0.5%. If the evidence capture needs more, the
next step is 16384 deep at 128 tiles, still viable at ~68% total BRAM (two rows
directly measured: 32b x 131072 = 120.0 tiles, 1024b x 4096 = 114.5 tiles).

## Honest limits on the above

1. These are **out-of-context synthesis** numbers. Post-implementation counts in
   a full design can differ and BRAM may pack differently under congestion.
   Confirm with `report_utilization` after `place_design`.
2. **The debug hub is NOT MEASURED.** `dbg_hub` is inserted at `opt_design` so
   it never appears in OOC IP synthesis. Its cost is in none of these figures.
3. **No hardware was touched for this characterisation.** The Tcl flow is
   verified for command and property correctness against the 2025.2 binary but
   has NOT been executed end to end on silicon. That happens at the Phase 7 gate,
   which is John's to capture.
