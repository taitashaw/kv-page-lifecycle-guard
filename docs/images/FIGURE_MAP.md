# Figure map

Numbers refer to the attachment grid, read left to right, top to bottom.

| save as | grid # | what it is | why chosen |
|---|---|---|---|
| `ila-hardware.png` | **4** | Hardware Manager `hw_ila_1`, 21 named probes | **The result.** `refcount=00`, `inflight` stepping 01 to 08, `reuse_grant` flat at 0, `sticky=01` |
| `block-design.png` | **16** | Block design canvas, full | Cleanest full view; 21 `dbg_*` ports fanning into `probe0..probe20`, `const_one` into both reset pins |
| `sim-waveform.png` | **7** | XSim, full run | `checks=25`, `errors=0`; the gate that drives the real AXI boundary |
| `sim-latency.png` | **9** | XSim, scrolled to the `dbg_*` group | `dbg_rd_latency=0012`, `dbg_rd_latency_max=0012`, `dbg_sticky=8f` |
| `device-view.png` | **18** | Implemented design, Device view | Placed cells, timing closed |
| `dashboard.png` | **3** | Project Summary, Dashboard | Utilisation bars, power by rail, DRC 13, methodology 9 |
| `project-summary.png` | **1** | Project Summary, Overview | WNS 0.242, 0 failing of 53,926, 3.628 W in one frame |

## Not used, and why

| grid # | what it is | why left out |
|---|---|---|
| 2 | Project Summary with Sources tree | Duplicates 1; the tree adds no evidence |
| 5 | Architecture diagram | Already committed as `architecture.svg` |
| 6, 14, 15 | Other block design views | 16 is the clearest of the four |
| 8, 10, 11, 12, 13 | Other simulation waveforms | 7 and 9 carry the checks count and the counters |
| 17, 19 | Elaborated and synthesised schematics | Dense green spaghetti. Reads as decoration, not evidence |

## Post attachments, ranked

LinkedIn shows four well.

1. **#4** `ila-hardware.png` — the claim proved, readable without the post
2. **#16** `block-design.png` — an integrated system, not a lone RTL block
3. **#7** `sim-waveform.png` — verified before it was built
4. **#1** `project-summary.png` — the credibility numbers
