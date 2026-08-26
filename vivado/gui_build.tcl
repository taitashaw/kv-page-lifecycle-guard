# gui_build.tcl -- runs inside the Vivado GUI so progress is visible on screen.
set root [file normalize [file dirname [info script]]/..]
set proj lifecycle_guard
puts "\n### STEP 1/4  creating project"
create_project $proj $root/vivado/$proj -part xczu7ev-ffvc1156-2-e -force
set_property board_part xilinx.com:zcu104:part0:1.1 [current_project]
add_files -norecurse [list \
  $root/rtl/v1/lifecycle_pkg.sv $root/rtl/v1/page_state_lut.sv \
  $root/rtl/v1/tag_tracker.sv   $root/rtl/v1/axi_lite_regs.sv \
  $root/rtl/v1/axi_read_manager.sv $root/rtl/v1/lifecycle_guard_top.sv]
set_property file_type SystemVerilog [get_files *.sv]
add_files -fileset sim_1 -norecurse [glob $root/rtl/v1/tb_*.sv]
set_property top lifecycle_guard_top [current_fileset]
set_property top tb_payload_corruption [get_filesets sim_1]
update_compile_order -fileset sources_1
puts "### project ready: [get_property PART [current_project]]"

puts "\n### STEP 2/4  timing constraint, 200 MHz"
set xdc $root/vivado/timing.xdc
set fh [open $xdc w]
puts $fh "create_clock -period 5.000 -name clk \[get_ports clk\]"
close $fh
add_files -fileset constrs_1 -norecurse $xdc

puts "\n### STEP 3/4  out-of-context synthesis, watch the Design Runs tab"
synth_design -mode out_of_context -top lifecycle_guard_top \
             -part xczu7ev-ffvc1156-2-e -flatten_hierarchy rebuilt
puts "\n### STEP 4/4  reports"
report_utilization -file $root/vivado/rpt_util_ooc.txt
report_timing_summary -file $root/vivado/rpt_timing_ooc.txt
set wns [get_property SLACK [get_timing_paths -delay_type max]]
puts "\n=============================================="
puts "  OOC SYNTHESIS COMPLETE"
puts "  WNS at 200 MHz : $wns ns"
puts "  LUT  : [get_property SLICE_LUTS  [report_utilization -return_string -quiet]]"
puts "=============================================="
foreach {n} {CLB\ LUTs CLB\ Registers Block\ RAM\ Tile URAM DSPs} { }
set u [report_utilization -return_string]
foreach line [split $u "\n"] {
  if {[regexp {\|\s*(CLB LUTs|CLB Registers|Block RAM Tile|URAM|DSPs)\s*\|\s*(\d+)} $line -> nm val]} {
    puts "  $nm : $val"
  }
}
puts "=============================================="
