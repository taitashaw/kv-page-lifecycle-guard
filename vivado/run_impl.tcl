set root [file normalize [file dirname [info script]]/..]
open_project $root/vivado/lifecycle_guard/lifecycle_guard.xpr
launch_runs impl_1 -jobs 8
wait_on_run impl_1
open_run impl_1
report_utilization -file $root/vivado/rpt_util_impl.txt
report_timing_summary -file $root/vivado/rpt_timing_impl.txt
report_drc -file $root/vivado/rpt_drc.txt
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set tns [get_property STATS.TNS [get_runs impl_1]]
puts "IMPL WNS: $wns   TNS: $tns"
if {$wns < 0 || $tns != 0} { puts "TIMING NOT CLOSED. Bitstream gate BLOCKED." }
