# create_bd.tcl -- integrated block design, 200 MHz PL clock.
# Read-only PS-DDR path for the first HIL version. No writes.
set root [file normalize [file dirname [info script]]/..]
open_project $root/vivado/lifecycle_guard/lifecycle_guard.xpr
create_bd_design "lg_bd"

set zynq [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ps]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $zynq
# one AXI-Lite master for control, one HP slave for the read path
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
  CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {200} \
] $zynq

create_bd_cell -type module -reference lifecycle_guard_top lg
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_ctrl
set_property CONFIG.NUM_SI {1} [get_bd_cells sc_ctrl]
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_mem
set_property CONFIG.NUM_SI {1} [get_bd_cells sc_mem]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_200

# clocks and resets
connect_bd_net [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins rst_200/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ps/pl_resetn0] [get_bd_pins rst_200/ext_reset_in]
foreach p {lg/clk sc_ctrl/aclk sc_mem/aclk zynq_ps/maxihpm0_fpd_aclk zynq_ps/saxihp0_fpd_aclk} {
  connect_bd_net [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins $p] }
foreach p {lg/rst_n sc_ctrl/aresetn sc_mem/aresetn} {
  connect_bd_net [get_bd_pins rst_200/peripheral_aresetn] [get_bd_pins $p] }

# PS -> AXI-Lite control
connect_bd_intf_net [get_bd_intf_pins zynq_ps/M_AXI_HPM0_FPD] [get_bd_intf_pins sc_ctrl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_ctrl/M00_AXI] [get_bd_intf_pins lg/s_axil]
# PL -> PS DDR, read only
connect_bd_intf_net [get_bd_intf_pins lg/m_axi] [get_bd_intf_pins sc_mem/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_mem/M00_AXI] [get_bd_intf_pins zynq_ps/S_AXI_HP0_FPD]

# VIO for board-only stimulus before any DDR traffic, ILA on the probe bus
create_bd_cell -type ip -vlnv xilinx.com:ip:vio vio_0
create_bd_cell -type ip -vlnv xilinx.com:ip:ila ila_0
connect_bd_net [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins vio_0/clk]
connect_bd_net [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins ila_0/clk]

assign_bd_address
regenerate_bd_layout
validate_bd_design
save_bd_design
make_wrapper -files [get_files lg_bd.bd] -top
add_files -norecurse [file dirname [get_files lg_bd.bd]]/hdl/lg_bd_wrapper.v
set_property top lg_bd_wrapper [current_fileset]
puts "BD VALIDATED. address map:"
foreach s [get_bd_addr_segs] { puts "  $s" }
