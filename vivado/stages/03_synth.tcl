source [file dirname [info script]]/00_common.tcl
banner 3 6 "SYNTHESIS"
if {[current_project -quiet] eq ""} { open_project $pdir/$proj.xpr }
close_sim -quiet
# Retiming lets the tool relocate registers across the 12-level FIFO-to-LUT
# path automatically. This is the no-RTL-risk attempt at the ~970 ps needed
# for a 4 ns period.
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
reset_run synth_1 -quiet
launch_runs synth_1 -jobs 12
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
  error "SYNTHESIS FAILED: [get_property STATUS [get_runs synth_1]]"
}
open_run synth_1 -name synth_1
# Debug hub divider. Required before the HIL gate or Labtools throws 27-3123
# when the JTAG clock outruns the hub. Now reachable because the BD has an ILA.
if {![llength [get_debug_cores -quiet dbg_hub]]} {
  error "NO dbg_hub AFTER SYNTHESIS. The ILA did not reach the netlist."
}
puts "### dbg_hub present in the synthesized netlist"

# BUILD-TIME GUARD. Catch a reset tied ASSERTED before spending 30 minutes on
# implementation and a board session. This exact bug cost most of a day.
set bdv [glob -nocomplain $pdir/*.gen/sources_1/bd/$bdname/synth/${bdname}.v]
if {[llength $bdv]} {
  set fh [open [lindex $bdv 0]]; set txt [read $fh]; close $fh
  if {[string match "*.ext_reset_in(1'b0)*" $txt]} {
    error "ext_reset_in is tied 1'b0 = RESET ASSERTED (C_EXT_RESET_HIGH=0). Tie it to const_one in 02_bd.tcl."
  }
  puts "### reset tie check PASSED (ext_reset_in is not tied asserted)"
}
# The divider is applied by $vdir/dbg_hub.xdc during IMPLEMENTATION. Setting it
# here on the open run would be discarded when impl_1 re-reads the checkpoint.
if {[llength [get_files -quiet dbg_hub.xdc]] == 0} {
  add_files -fileset constrs_1 -norecurse $vdir/dbg_hub.xdc
}
set_property used_in_synthesis false      [get_files dbg_hub.xdc]
set_property used_in_implementation true  [get_files dbg_hub.xdc]
# FLOORPLAN PBLOCK DISABLED. MEASURED 25 Aug 2026: constraining u_core to
# CLOCKREGION_X1Y1:X1Y2 moved WNS from +0.117 ns to +0.020 ns and the worst
# path from 4.932 ns to 5.167 ns. Route delay ROSE (3.785 -> 3.875 ns) because
# pulling the core together pushed the SmartConnects and ILA further from it.
# Routing locality is not the lever here. Do not re-enable without new evidence.
if {[llength [get_files -quiet pblock_core.xdc]]} {
  remove_files -fileset constrs_1 [get_files pblock_core.xdc]
  puts "### floorplan pblock REMOVED (measured worse, see 03_synth.tcl comment)"
}
puts "### debug hub divider constraint registered for implementation"
report_utilization -file $vdir/rpt_util_synth.txt
puts "### SYNTHESIS COMPLETE. Screenshot the synthesized design / utilization."
