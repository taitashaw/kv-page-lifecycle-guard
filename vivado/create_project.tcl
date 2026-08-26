set root [file normalize [file dirname [info script]]/..]
set proj lifecycle_guard
create_project $proj $root/vivado/$proj -part xczu7ev-ffvc1156-2-e -force
set_property board_part xilinx.com:zcu104:part0:1.1 [current_project]
add_files -norecurse [glob $root/rtl/v1/lifecycle_pkg.sv $root/rtl/v1/page_state_lut.sv \
  $root/rtl/v1/tag_tracker.sv $root/rtl/v1/axi_lite_regs.sv \
  $root/rtl/v1/axi_read_manager.sv $root/rtl/v1/lifecycle_guard_top.sv]
set_property file_type SystemVerilog [get_files *.sv]
add_files -fileset sim_1 -norecurse [glob $root/rtl/v1/tb_*.sv]
set_property top lifecycle_guard_top [current_fileset]
set_property top tb_payload_corruption [get_filesets sim_1]
update_compile_order -fileset sources_1
puts "PROJECT CREATED: [current_project]  PART: [get_property PART [current_project]]"
