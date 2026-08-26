# Figure map

`figure` is the number the README gives it, in reading order. `grid #` refers to
the attachment grid, read left to right, top to bottom.

| figure | save as | grid # | what it is | why chosen |
|---|---|---|---|---|
| 1 | `architecture.svg` | 5 | Hand-drawn end-to-end architecture | Already committed; the only figure not from Vivado |
| 2 | `block-design.png` | **16** | Block design canvas, full | Cleanest full view; 21 `dbg_*` ports fanning into `probe0..probe20`, `const_one` into `ext_reset_in` |
| 3 | `schematic-synth.png` | **17** | Post-synthesis schematic, 11 cells / 1,456 nets | What synthesis produced, not what the BD asked for; shows all four debug cores survived |
| 4 | `dashboard.png` | **3** | Project Summary, Dashboard | Utilisation bars, power by rail, DRC 13, methodology 9 |
| 5 | `device-view.png` | **18** | Implemented design, Device view | Placed cells, timing closed |
| 6 | `schematic-impl.png` | **19** | Post-implementation schematic, 10 cells / 1,407 nets | Pairs with figure 3; the delta is `opt_design` folding constants |
| 7 | `sim-latency.png` | **9** | XSim, scrolled to the `dbg_*` group | `dbg_rd_latency=0012`, `dbg_rd_latency_max=0012`, `dbg_sticky=8f` |
| 8 | `ila-hardware.png` | **4** | Hardware Manager `hw_ila_1`, 21 named probes | **The result.** `refcount=00`, `inflight` stepping 01 to 08, `reuse_grant` flat at 0, `sticky=01` |
| n/a | `sim-waveform.png` | **7** | XSim, full run | `checks=25`, `errors=0`. Referenced in the Evidence table, not yet embedded |
| n/a | `project-summary.png` | **1** | Project Summary, Overview | WNS 0.242, 0 failing of 53,926, 3.628 W. Referenced in the Evidence table, not yet embedded |

Figures 3 and 6 were originally left out as "dense green spaghetti". That was a
judgement about a raster screenshot, and it was wrong for a repo: the pair is the
only place the netlist is visible, and the cell-count delta between them is the
cheapest check that optimisation removed constants and nothing else.

## Not used, and why

| grid # | what it is | why left out |
|---|---|---|
| 2 | Project Summary with Sources tree | Duplicates 1; the tree adds no evidence |
| 6, 14, 15 | Other block design views | 16 is the clearest of the four |
| 8, 10, 11, 12, 13 | Other simulation waveforms | 7 and 9 carry the checks count and the counters |

## Post attachments, ranked

LinkedIn shows four well.

1. **#4** `ila-hardware.png`: the claim proved, readable without the post
2. **#16** `block-design.png`: an integrated system, not a lone RTL block
3. **#7** `sim-waveform.png`: verified before it was built
4. **#1** `project-summary.png`: the credibility numbers
