# Figures

`architecture.svg` is committed. Everything else is a Vivado capture. Save each
at the filename given and it renders in the top-level README automatically.

| filename | pane to capture | how to know it is the right one |
|---|---|---|
| `sim-waveform.png` | XSim, `tb_lifecycle_guard_top` | title reads `tb_lifecycle_guard_top`; `checks=25`, `errors=0`; the 19 `dbg_*` fields visible; run ends 4,452,500 ns |
| `sim-latency.png` | XSim, scrolled to the `dbg_*` group | `dbg_rd_latency = 0012`, `dbg_rd_latency_max = 0012`, `dbg_sticky = 8f`. This is the counter working in simulation |
| `block-design.png` | IP Integrator canvas, Reduced Jogs | 9 cells; the 21 `dbg_*` ports fanning into `probe0..probe20`; `const_one` into both `ext_reset_in` and `dcm_locked` |
| `elaborated-schematic.png` | RTL elaborated schematic | 11 Cells, 1456 Nets |
| `synthesis.png` | Synthesized design, Netlist pane | `dbg_hub` beside `kv_guard_bd_i`; schematic 10 Cells, 1407 Nets |
| `implementation.png` | Implemented design, Device view | placed cells clustered in X1Y0..X1Y4 and X2Y2..X3Y3 |
| `project-summary.png` | Project Summary, Overview | Synthesis Complete, Implementation Complete, WNS 0.242, 0 failing of 53,926, power 3.628 W |
| `project-dashboard.png` | Project Summary, Dashboard | power by rail, utilisation bars, DRC 13, methodology 9 |
| `sources-tree.png` | Sources, Hierarchy expanded | all 9 BD cells, `dbg_hub.xdc` under Constraints, 9 simulation sources |
| `ila-hardware.png` | Hardware Manager, `hw_ila_1` waveform | 21 probes **by name**; `dbg_refcount=00`, `dbg_inflight` stepping 01..08, `dbg_reuse_grant=0` throughout, `dbg_sticky=01` |
| `ila-trigger-setup.png` | Trigger Setup tab | the `.tsm` state machine text, both trigger branches visible |

## The one figure that carries the result

`ila-hardware.png`. Everything else is supporting. It shows `refcount == 00`
with `inflight` climbing 01 through 08 while `reuse_grant` stays flat at zero for
all eight requests. That is the safety property on silicon: eight chances to make
the mistake, taken zero times.
