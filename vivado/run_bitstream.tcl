set root [file normalize [file dirname [info script]]/..]
open_project $root/vivado/lifecycle_guard/lifecycle_guard.xpr
open_run impl_1
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set tns [get_property STATS.TNS [get_runs impl_1]]
if {$wns < 0 || $tns != 0} { error "REFUSING: WNS $wns TNS $tns. Timing must close first." }
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set bit [glob -nocomplain $root/vivado/lifecycle_guard/*.runs/impl_1/*.bit]
puts "BITSTREAM: $bit"
