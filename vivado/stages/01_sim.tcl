source [file dirname [info script]]/00_common.tcl
banner 1 6 "BEHAVIOURAL SIMULATION"
create_project $proj $pdir -part $part -force
set_property board_part $board [current_project]
add_files -norecurse [list \
  $rtl/lifecycle_pkg.sv $rtl/page_state_lut.sv $rtl/tag_tracker.sv \
  $rtl/axi_lite_regs.sv $rtl/axi_read_manager.sv $rtl/lifecycle_guard_top.sv]
set_property file_type SystemVerilog [get_files *.sv]
# Verilog-2001 boundary for IP Integrator. Added after the file_type sweep so
# it stays Verilog.
add_files -norecurse $rtl/kv_lifecycle_guard.v
add_files -fileset sim_1 -norecurse [glob $rtl/tb_*.sv]
set_property file_type SystemVerilog [get_files -of [get_filesets sim_1] *.sv]
# The gate must be the TB that instantiates lifecycle_guard_top and drives the
# real AXI boundary. tb_payload_corruption drives page_state_lut, a submodule,
# so it cannot gate a bitstream.
set_property top tb_lifecycle_guard_top [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
launch_simulation
run all
puts "### SIMULATION COMPLETE. Waveform is open. Screenshot the XSim window (gate G1)."
