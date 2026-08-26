source [file dirname [info script]]/00_common.tcl
banner 2 6 "INTEGRATED BLOCK DESIGN"
if {[current_project -quiet] eq ""} { open_project $pdir/$proj.xpr }
close_sim -quiet
# Stage 2 must be re-runnable. Without this, a second run dies with
# [BD 5-874] A design with the name already exists, and the stages after it
# silently reuse the PREVIOUS build's reports.
set old [get_files -quiet $bdname.bd]
if {[llength $old]} {
  catch { close_bd_design [get_bd_designs -quiet $bdname] }
  catch { remove_files $old }
  catch { file delete -force $pdir/$proj.srcs/sources_1/bd/$bdname }
  catch { file delete -force $pdir/$proj.gen/sources_1/bd/$bdname }
}
create_bd_design $bdname
set zynq [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ps]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $zynq
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__NUM_FABRIC_RESETS {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $FREQ] $zynq

create_bd_cell -type module -reference kv_lifecycle_guard $guard
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_ps8_0_200M

connect_bd_net [get_bd_pins zynq_ps/pl_clk0]    [get_bd_pins rst_ps8_0_200M/slowest_sync_clk]
# ext_reset_in is DELIBERATELY LEFT UNCONNECTED.
#
# zynq_ps/pl_resetn0 is NOT a reset register. AMD's PS wrapper has
#   assign pl_resetn0 = emio_gpio_o_temp[95];
# in EVERY branch of the C_NUM_FABRIC_RESETS generate, so it is EMIO GPIO bank 5
# bit 31, which powers up at 0. proc_sys_reset's EXR_OUTPUT_PROCESS then LATCHES
# lpf_exr high and never clears it, holding peripheral_aresetn low forever. That
# gated jtag_axi_0, both SmartConnects and the guard, which is why every AXI
# transaction returned TIMED OUT while the ILA (no reset input) worked fine.
# It is also why PSU__NUM_FABRIC_RESETS could not help.
#
# NOT an xlconstant: a constant driver carries no POLARITY, so proc_sys_reset's
# post_propagate can flip C_EXT_RESET_HIGH back to 1 and a constant 1 would then
# mean "permanently asserted" - straight back into this symptom. Unconnected is
# safe under both polarities because Vivado ties an unconnected reset input to
# its DEASSERTED value (proven in this design's own netlist, where the
# unconnected aux_reset_in emitted as .aux_reset_in(1'b1)).
#
# proc_sys_reset still produces a real sequenced reset: its POR SRL16 holds
# lpf_int for the first 16 pl_clk0 cycles after configuration, then releases.
# dcm_locked MUST be tied high. proc_sys_reset holds peripheral_aresetn asserted
# until dcm_locked goes high; left unconnected it reads low and the whole PL
# stays in reset forever. On hardware that shows up as every AXI transaction
# timing out, and simulation never catches it because the testbench drives reset
# directly. There is no MMCM here (pl_clk0 comes from the PS PLL), so tie it to 1.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant const_one
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] [get_bd_cells const_one]
connect_bd_net [get_bd_pins const_one/dout] [get_bd_pins rst_ps8_0_200M/dcm_locked]
# ext_reset_in MUST be tied to const_one, NOT left unconnected.
# MEASURED in the netlist: leaving it unconnected emitted .ext_reset_in(1'b0),
# while unconnected aux_reset_in emitted .aux_reset_in(1'b1). The two inputs do
# NOT share a default tie. With C_EXT_RESET_HIGH=0 (active low), 1'b0 means
# RESET PERMANENTLY ASSERTED, which held peripheral_aresetn low and made every
# AXI transaction to the guard time out while the ILA (no reset) kept working.
connect_bd_net [get_bd_pins const_one/dout] [get_bd_pins rst_ps8_0_200M/ext_reset_in]
connect_bd_net [get_bd_pins zynq_ps/pl_clk0]    [get_bd_pins $guard/aclk]
connect_bd_net [get_bd_pins rst_ps8_0_200M/peripheral_aresetn] [get_bd_pins $guard/aresetn]

# SmartConnect on BOTH paths. apply_bd_automation defaults the control path to
# AXI Interconnect, which Vivado 2025.2 marks Discontinued on UltraScale+.
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_smc_ctrl
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_smc_ctrl]
connect_bd_net  [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins axi_smc_ctrl/aclk]
connect_bd_net  [get_bd_pins rst_ps8_0_200M/peripheral_aresetn] [get_bd_pins axi_smc_ctrl/aresetn]
connect_bd_intf_net [get_bd_intf_pins zynq_ps/M_AXI_HPM0_FPD] [get_bd_intf_pins axi_smc_ctrl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc_ctrl/M00_AXI]   [get_bd_intf_pins $guard/s_axi]
connect_bd_net  [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins zynq_ps/maxihpm0_fpd_aclk]

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_smc_mem
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] [get_bd_cells axi_smc_mem]
connect_bd_net  [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins axi_smc_mem/aclk]
connect_bd_net  [get_bd_pins rst_ps8_0_200M/peripheral_aresetn] [get_bd_pins axi_smc_mem/aresetn]
connect_bd_intf_net [get_bd_intf_pins $guard/m_axi] [get_bd_intf_pins axi_smc_mem/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc_mem/M00_AXI] [get_bd_intf_pins zynq_ps/S_AXI_HP0_FPD]
connect_bd_net  [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins zynq_ps/saxihp0_fpd_aclk]

# ---------------------------------------------------------------- NATIVE ILA
# 21 NAMED probes, one per logical field, NOT one wide bus. A single
# 196-bit probe appears in Hardware Manager as one unnamed signal and cannot be
# triggered on field by field. That is what made the earlier bring-up blind.
#
# Designed against the four things an ILA is actually for:
#   BRING-UP      dbg_rstn + dbg_heartbeat. The heartbeat is NOT reset, so a
#                 frozen value means the clock died, and a counting value with
#                 rstn low means reset is the fault. Removes the ambiguity that
#                 makes every other field read zero in both conditions.
#   SAFETY        refcount / reservation / inflight / fill_pending: the exact
#                 predicate terms, so a grant can be judged against the state
#                 it was actually made in.
#   RARE FAILURES dbg_sticky latches events between captures. Bit 7 is the
#                 violation trap: a grant while the predicate is unsatisfied.
#   PERFORMANCE   dbg_ar_wait is real interconnect backpressure and
#                 dbg_rd_latency/_max is real DDR latency, which simulation
#                 only ever modelled.
# 135 bits x 2048 deep.
create_bd_cell -type ip -vlnv xilinx.com:ip:ila ila_lifecycle
set_property -dict [list CONFIG.C_NUM_OF_PROBES {21} \
  CONFIG.C_PROBE0_WIDTH {1} \
  CONFIG.C_PROBE1_WIDTH {16} \
  CONFIG.C_PROBE2_WIDTH {8} \
  CONFIG.C_PROBE3_WIDTH {8} \
  CONFIG.C_PROBE4_WIDTH {6} \
  CONFIG.C_PROBE5_WIDTH {4} \
  CONFIG.C_PROBE6_WIDTH {8} \
  CONFIG.C_PROBE7_WIDTH {8} \
  CONFIG.C_PROBE8_WIDTH {6} \
  CONFIG.C_PROBE9_WIDTH {6} \
  CONFIG.C_PROBE10_WIDTH {1} \
  CONFIG.C_PROBE11_WIDTH {1} \
  CONFIG.C_PROBE12_WIDTH {1} \
  CONFIG.C_PROBE13_WIDTH {1} \
  CONFIG.C_PROBE14_WIDTH {1} \
  CONFIG.C_PROBE15_WIDTH {1} \
  CONFIG.C_PROBE16_WIDTH {2} \
  CONFIG.C_PROBE17_WIDTH {16} \
  CONFIG.C_PROBE18_WIDTH {16} \
  CONFIG.C_PROBE19_WIDTH {16} \
  CONFIG.C_PROBE20_WIDTH {8} \
  CONFIG.C_DATA_DEPTH {2048} CONFIG.C_INPUT_PIPE_STAGES {2} \
  CONFIG.C_ADV_TRIGGER {true} CONFIG.C_EN_STRG_QUAL {1} \
  CONFIG.C_MONITOR_TYPE {NATIVE}] [get_bd_cells ila_lifecycle]
connect_bd_net [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins ila_lifecycle/clk]
connect_bd_net [get_bd_pins $guard/dbg_rstn] [get_bd_pins ila_lifecycle/probe0]
connect_bd_net [get_bd_pins $guard/dbg_heartbeat] [get_bd_pins ila_lifecycle/probe1]
connect_bd_net [get_bd_pins $guard/dbg_refcount] [get_bd_pins ila_lifecycle/probe2]
connect_bd_net [get_bd_pins $guard/dbg_reservation] [get_bd_pins ila_lifecycle/probe3]
connect_bd_net [get_bd_pins $guard/dbg_inflight] [get_bd_pins ila_lifecycle/probe4]
connect_bd_net [get_bd_pins $guard/dbg_fill_pending] [get_bd_pins ila_lifecycle/probe5]
connect_bd_net [get_bd_pins $guard/dbg_generation] [get_bd_pins ila_lifecycle/probe6]
connect_bd_net [get_bd_pins $guard/dbg_exp_generation] [get_bd_pins ila_lifecycle/probe7]
connect_bd_net [get_bd_pins $guard/dbg_slot] [get_bd_pins ila_lifecycle/probe8]
connect_bd_net [get_bd_pins $guard/dbg_phys] [get_bd_pins ila_lifecycle/probe9]
connect_bd_net [get_bd_pins $guard/dbg_reuse_req] [get_bd_pins ila_lifecycle/probe10]
connect_bd_net [get_bd_pins $guard/dbg_reuse_grant] [get_bd_pins ila_lifecycle/probe11]
connect_bd_net [get_bd_pins $guard/dbg_reuse_refused] [get_bd_pins ila_lifecycle/probe12]
connect_bd_net [get_bd_pins $guard/dbg_stale] [get_bd_pins ila_lifecycle/probe13]
connect_bd_net [get_bd_pins $guard/dbg_payload_mm] [get_bd_pins ila_lifecycle/probe14]
connect_bd_net [get_bd_pins $guard/dbg_evictable] [get_bd_pins ila_lifecycle/probe15]
connect_bd_net [get_bd_pins $guard/dbg_outstanding] [get_bd_pins ila_lifecycle/probe16]
connect_bd_net [get_bd_pins $guard/dbg_ar_wait] [get_bd_pins ila_lifecycle/probe17]
connect_bd_net [get_bd_pins $guard/dbg_rd_latency] [get_bd_pins ila_lifecycle/probe18]
connect_bd_net [get_bd_pins $guard/dbg_rd_latency_max] [get_bd_pins ila_lifecycle/probe19]
connect_bd_net [get_bd_pins $guard/dbg_sticky] [get_bd_pins ila_lifecycle/probe20]

# ------------------------------------------------------------------ SYSTEM ILA
# Protocol-aware AXI monitor. It decodes transactions instead of showing raw
# handshake bits, so Hardware Manager displays reads and writes with address,
# burst and response rather than arvalid/arready toggling.
# Slot 0 = the guard's control aperture. Slot 1 = its read path to DDR.
create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila sila_axi
set_property -dict [list CONFIG.C_NUM_MONITOR_SLOTS {2} \
  CONFIG.C_SLOT_0_INTF_TYPE {xilinx.com:interface:aximm_rtl:1.0} \
  CONFIG.C_SLOT_1_INTF_TYPE {xilinx.com:interface:aximm_rtl:1.0} \
  CONFIG.C_DATA_DEPTH {1024}] [get_bd_cells sila_axi]
connect_bd_net [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins sila_axi/clk]
connect_bd_net [get_bd_pins rst_ps8_0_200M/peripheral_aresetn] [get_bd_pins sila_axi/resetn]
connect_bd_intf_net [get_bd_intf_pins axi_smc_ctrl/M00_AXI] [get_bd_intf_pins sila_axi/SLOT_0_AXI]
connect_bd_intf_net [get_bd_intf_pins $guard/m_axi]          [get_bd_intf_pins sila_axi/SLOT_1_AXI]


# ---------------------------------------------- JTAG-to-AXI master (HIL control)
# Driving the guard through the PS proved fragile: xsct reaches memory via the
# A53, which repeatedly wedged ("EDITR not ready"), and it needs FSBL, psu_init
# and the PS-PL isolation removal all holding. This IP gives Vivado a native AXI
# master over JTAG (create_hw_axi_txn), independent of the PS entirely.
create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi jtag_axi_0
set_property -dict [list CONFIG.PROTOCOL {2} CONFIG.M_HAS_BURST {0}] [get_bd_cells jtag_axi_0]
connect_bd_net [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins jtag_axi_0/aclk]
connect_bd_net [get_bd_pins rst_ps8_0_200M/peripheral_aresetn] [get_bd_pins jtag_axi_0/aresetn]
set_property -dict [list CONFIG.NUM_SI {2}] [get_bd_cells axi_smc_ctrl]
connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] [get_bd_intf_pins axi_smc_ctrl/S01_AXI]
# NOT axi_smc_ctrl/aclk1: SmartConnect exposes aclk1 only when configured for
# multiple clock domains. Both masters share pl_clk0, so the single aclk covers
# S00 and S01.

assign_bd_address

# ------------------------------------------------- CONFINE THE READ MASTER
# assign_bd_address grants the master 2G of DDR at 0x0 plus 512M QSPI and 16M
# OCM. The standing rule is that unsafe mode reaches a dedicated scratch buffer
# and never uncontrolled DDR. Read-only cannot corrupt, but it can still read
# kernel memory, so the aperture is narrowed here.
# NOTE: this bounds what the hardware can ADDRESS. It does not by itself stop
# Linux using that range. The matching reserved-memory node is in
# docs/hil/scratch_reservation.md and is required before the HIL gate.
exclude_bd_addr_seg [get_bd_addr_segs zynq_ps/SAXIGP2/HP0_QSPI] \
  -target_address_space [get_bd_addr_spaces $guard/m_axi]
exclude_bd_addr_seg [get_bd_addr_segs zynq_ps/SAXIGP2/HP0_LPS_OCM] \
  -target_address_space [get_bd_addr_spaces $guard/m_axi]
set seg [get_bd_addr_segs $guard/m_axi/SEG_zynq_ps_HP0_DDR_LOW]
# Range BEFORE offset. While the range is still 2G, Vivado requires 2G
# alignment and rejects 0x7000_0000 (BD 41-70). Narrowing first makes the
# 256M-aligned base legal.
set_property range  $SCRATCH_SIZE $seg
set_property offset $SCRATCH_BASE $seg

regenerate_bd_layout
validate_bd_design
save_bd_design
puts "### BD VALIDATED. address map:"
foreach s [get_bd_addr_segs -quiet] {
  puts [format "    %-52s %s +%s" $s \
    [get_property offset [get_bd_addr_segs $s]] [get_property range [get_bd_addr_segs $s]]]
}
make_wrapper -files [get_files $bdname.bd] -top
add_files -norecurse [glob $pdir/*.gen/sources_1/bd/$bdname/hdl/${bdname}_wrapper.v]
set_property top ${bdname}_wrapper [current_fileset]
update_compile_order -fileset sources_1
open_bd_design [get_files $bdname.bd]
puts "### BLOCK DESIGN COMPLETE. Screenshot the canvas (gate G2)."
