set root [file normalize [file dirname [info script]]/..]
open_project $root/vivado/lifecycle_guard/lifecycle_guard.xpr
launch_runs synth_1 -jobs 8
wait_on_run synth_1
open_run synth_1 -name synth_1
report_utilization -file $root/vivado/rpt_util_synth.txt
report_timing_summary -file $root/vivado/rpt_timing_synth.txt
puts "SYNTH: [get_property STATUS [get_runs synth_1]]"
puts "WNS: [get_property SLACK [get_timing_paths -delay_type max]]"
