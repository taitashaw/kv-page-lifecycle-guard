source [file dirname [info script]]/00_common.tcl
puts "\n######## G4  IMPLEMENTATION ########"
# Opens the ALREADY COMPLETED implementation for inspection. No rebuild, so the
# device view and timing on screen match the bitstream on the board.
if {[current_project -quiet] eq ""} { open_project $pdir/$proj.xpr }
open_run impl_1

set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]
set ths [get_property STATS.THS [get_runs impl_1]]
puts "### run status: [get_property STATUS [get_runs impl_1]]"
puts "### setup: WNS $wns   TNS $tns"
puts "### hold:  WHS $whs   THS $ths"

set pk [get_clocks -quiet clk_pl_0]
if {[llength $pk]} {
  set per [get_property PERIOD $pk]
  puts "### ACTUAL PL clock: [format %.3f $per] ns = [format %.2f [expr {1000.0/$per}]] MHz"
  puts "###   (the PLL rounds the request: 200 MHz asked, 187.5 granted)"
}

if {$wns < 0 || $tns < 0} {
  puts "### TIMING NOT CLOSED. A bitstream from this run would be invalid."
} else {
  puts "### TIMING CLOSED. Margin is [format %.1f [expr {100.0*$wns/$per}]] percent of the period."
}

puts "### worst path:"
set p [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]
if {$p ne ""} {
  puts "###   from  [get_property STARTPOINT_PIN $p]"
  puts "###   to    [get_property ENDPOINT_PIN  $p]"
  puts "###   delay [get_property DATAPATH_DELAY $p] ns, [get_property LOGIC_LEVELS $p] logic levels"
}

report_utilization    -file $vdir/rpt_util_impl.txt
report_timing_summary -file $vdir/rpt_timing_impl.txt
report_drc            -file $vdir/rpt_drc.txt
puts "### reports written to vivado/rpt_*.txt"
puts "### IMPLEMENTATION OPEN. Screenshot the device view and timing summary (gate G4)."
