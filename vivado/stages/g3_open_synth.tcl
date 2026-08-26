source [file dirname [info script]]/00_common.tcl
puts "\n######## G3  SYNTHESIS ########"
# Opens the ALREADY COMPLETED synthesis run for inspection. No rebuild, so what
# is on screen matches the bitstream currently on the board.
if {[current_project -quiet] eq ""} { open_project $pdir/$proj.xpr }
open_run synth_1 -name synth_1

puts "### run status: [get_property STATUS [get_runs synth_1]]"

puts "### debug cores that reached the netlist:"
foreach c [get_debug_cores -quiet] { puts "###   $c" }
if {![llength [get_debug_cores -quiet dbg_hub]]} {
  puts "###   WARNING: no dbg_hub. The ILA would be invisible on hardware."
}

puts "### debug hub configuration:"
if {[llength [get_debug_cores -quiet dbg_hub]]} {
  foreach pr {C_CLK_INPUT_FREQ_HZ C_ENABLE_CLK_DIVIDER C_USER_SCAN_CHAIN} {
    puts [format "###   %-22s %s" $pr [get_property -quiet $pr [get_debug_cores dbg_hub]]]
  }
}

puts "### instrumentation cost:"
set hb [get_cells -hier -quiet -filter {NAME =~ *hb_cnt*}]
puts "###   heartbeat FFs found: [llength $hb]"
set lat [get_cells -hier -quiet -filter {NAME =~ *rd_lat*}]
puts "###   latency-counter FFs: [llength $lat]"
set stk [get_cells -hier -quiet -filter {NAME =~ *sticky_q*}]
puts "###   sticky-flag FFs:     [llength $stk]"

report_utilization -file $vdir/rpt_util_synth.txt
puts "### utilization written to vivado/rpt_util_synth.txt"
puts "### SYNTHESIS OPEN. Screenshot the netlist / utilization (gate G3)."
