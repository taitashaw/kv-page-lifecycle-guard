source [file dirname [info script]]/00_common.tcl
banner 4 6 "IMPLEMENTATION"
if {[current_project -quiet] eq ""} { open_project $pdir/$proj.xpr }
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
reset_run impl_1 -quiet
launch_runs impl_1 -jobs 12
wait_on_run impl_1
open_run impl_1
# PBLOCK VERIFY: prove the floorplan is actually in the design, never infer it
# from an unchanged slack number.
set pbs [get_pblocks -quiet]
if {[llength $pbs]} {
  foreach pb $pbs {
    puts "### PBLOCK $pb cells=[llength [get_cells -quiet -of [get_pblocks $pb]]] range=[get_property -quiet GRID_RANGES [get_pblocks $pb]]"
  }
} else {
  puts "### PBLOCK: NONE PRESENT. The floorplan constraint did NOT apply."
}
report_utilization    -file $vdir/rpt_util_impl.txt
report_timing_summary -file $vdir/rpt_timing_impl.txt
report_drc            -file $vdir/rpt_drc.txt
set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]
set pk [get_clocks -quiet clk_pl_0]
if {[llength $pk]} {
  set per [get_property PERIOD $pk]
  puts "### ACTUAL PL clock: [format %.3f $per] ns = [format %.2f [expr {1000.0/$per}]] MHz"
  puts "###   (the PLL rounds the request; 200 MHz requested previously granted 187.5)"
}
puts "### IMPL  WNS $wns   WHS $whs   TNS $tns"
if {$wns < 0 || $tns < 0} {
  puts "### TIMING NOT CLOSED. The ILA is the likely cause: the pre-ILA build"
  puts "### closed at only +0.165 ns. Reduce C_DATA_DEPTH or raise"
  puts "### C_INPUT_PIPE_STAGES in 02_bd.tcl and re-run from stage 2."
}
puts "### IMPLEMENTATION COMPLETE. Screenshot the device view / timing summary."
