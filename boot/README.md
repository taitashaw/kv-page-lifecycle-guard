# Boot image

`BOOT.BIN`, `fsbl_a53.elf` and `pmufw.elf` are **not committed**. They are built
by the AMD toolchain from AMD `embeddedsw` sources, so they are not this
project's work to redistribute or to relicense under the terms in `LICENSE`.

Regenerate them from the exported hardware:

1. Build the design (`vivado/stages/01_sim.tcl` through `05_bitstream.tcl`).
   Stage 5 writes `vivado/kv_guard.xsa`.
2. In Vitis 2025.2, create a platform from that XSA.
3. Generate the **Zynq MP FSBL** and **PMU firmware** applications.
4. Package with bootgen into `BOOT.BIN`, FSBL first, then PMUFW, then the
   bitstream.

None of this is needed for the JTAG flow, which is how every hardware result in
the README was produced. `vivado/hil/hil_bringup.tcl` side-loads over JTAG and
performs the PS-PL isolation removal itself, precisely because `psu_init()`
never calls `psu_ps_pl_isolation_removal_data()`. See `docs/hil/ps_pl_isolation.md`.
