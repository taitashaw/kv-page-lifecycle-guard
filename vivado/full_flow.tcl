set root [file normalize [file dirname [info script]]/..]
set proj lifecycle_guard
set pdir $root/vivado/$proj

puts "\n######## 1/7  PROJECT ########"
create_project $proj $pdir -part xczu7ev-ffvc1156-2-e -force
set_property board_part xilinx.com:zcu104:part0:1.1 [current_project]
add_files -norecurse [list \
  $root/rtl/v1/lifecycle_pkg.sv $root/rtl/v1/page_state_lut.sv \
  $root/rtl/v1/tag_tracker.sv   $root/rtl/v1/axi_lite_regs.sv \
  $root/rtl/v1/axi_read_manager.sv $root/rtl/v1/lifecycle_guard_top.sv]
# Verilog wrapper: IP Integrator rejects a .sv file as a BD module reference
# (ERROR [filemgmt 56-195]). Added AFTER the file_type sweep below so it stays
# Verilog, not SystemVerilog.
set_property file_type SystemVerilog [get_files *.sv]
add_files -norecurse $root/rtl/v1/lifecycle_guard_top_wrap.v
add_files -fileset sim_1 -norecurse [glob $root/rtl/v1/tb_*.sv]
set_property file_type SystemVerilog [get_files -of [get_filesets sim_1] *.sv]
set_property top tb_payload_corruption [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "\n######## 2/7  BEHAVIOURAL SIMULATION ########"
launch_simulation
run all
puts "### simulation finished, 31 checks reported above"
close_sim -quiet

puts "\n######## 3/7  BLOCK DESIGN ########"
create_bd_design "lg_bd"
set zynq [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ps]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
  -config {apply_board_preset "1"} $zynq
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {200}] $zynq

create_bd_cell -type module -reference lifecycle_guard_top_wrap lg
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_200

connect_bd_net [get_bd_pins zynq_ps/pl_clk0]    [get_bd_pins rst_200/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ps/pl_resetn0] [get_bd_pins rst_200/ext_reset_in]
connect_bd_net [get_bd_pins zynq_ps/pl_clk0]    [get_bd_pins lg/clk]
connect_bd_net [get_bd_pins rst_200/peripheral_aresetn] [get_bd_pins lg/rst_n]

apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
  -config { Master {/zynq_ps/M_AXI_HPM0_FPD} Clk "Auto" } \
  [get_bd_intf_pins lg/s_axi]

apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
  -config { Master {/lg/m_axi} Slave {/zynq_ps/S_AXI_HP0_FPD} \
            intc_ip {New AXI SmartConnect} Clk_master "Auto" \
            Clk_slave "Auto" Clk_xbar "Auto" } \
  [get_bd_intf_pins zynq_ps/S_AXI_HP0_FPD]

assign_bd_address
regenerate_bd_layout
validate_bd_design
save_bd_design
puts "### BD VALIDATED. address map:"
foreach s [get_bd_addr_segs -quiet] { puts "    $s" }

make_wrapper -files [get_files lg_bd.bd] -top
add_files -norecurse [glob $pdir/*.gen/sources_1/bd/lg_bd/hdl/lg_bd_wrapper.v]
set_property top lg_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1
open_bd_design [get_files lg_bd.bd]

puts "\n######## 4/7  SYNTHESIS ########"
launch_runs synth_1 -jobs 12
wait_on_run synth_1
puts "### synth: [get_property STATUS [get_runs synth_1]]"

puts "\n######## 5/7  DEBUG HUB DIVIDER ########"
open_run synth_1 -name synth_1
if {[llength [get_debug_cores -quiet dbg_hub]]} {
  set_property C_CLK_INPUT_FREQ_HZ 200000000 [get_debug_cores dbg_hub]
  set_property C_ENABLE_CLK_DIVIDER true [get_debug_cores dbg_hub]
  puts "### debug hub divider ENABLED"
} else {
  puts "### no dbg_hub in this build (ILA added in a later step)"
}
report_utilization -file $root/vivado/rpt_util_synth.txt

puts "\n######## 6/7  IMPLEMENTATION ########"
launch_runs impl_1 -jobs 12
wait_on_run impl_1
open_run impl_1
report_utilization    -file $root/vivado/rpt_util_impl.txt
report_timing_summary -file $root/vivado/rpt_timing_impl.txt
report_drc            -file $root/vivado/rpt_drc.txt
set wns [get_property STATS.WNS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]
puts "### IMPL WNS $wns   TNS $tns"

puts "\n######## 7/7  BITSTREAM ########"
if {$wns < 0 || $tns < 0} {
  puts "### REFUSING BITSTREAM: timing not closed. WNS $wns TNS $tns"
} else {
  launch_runs impl_1 -to_step write_bitstream -jobs 12
  wait_on_run impl_1
  puts "### BITSTREAM: [glob -nocomplain $pdir/*.runs/impl_1/*.bit]"
}
open_bd_design [get_files lg_bd.bd]
puts "\n######## FLOW COMPLETE. Block design is on the canvas. ########"
