source [file dirname [info script]]/00_common.tcl
banner 5 6 "BITSTREAM"
if {[current_project -quiet] eq ""} { open_project $pdir/$proj.xpr }
set wns [get_property STATS.WNS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]
if {$wns < 0 || $tns < 0} {
  error "REFUSING BITSTREAM: timing not closed. WNS $wns TNS $tns"
}
launch_runs impl_1 -to_step write_bitstream -jobs 12
wait_on_run impl_1
set bit [glob -nocomplain $pdir/*.runs/impl_1/*.bit]
set ltx [glob -nocomplain $pdir/*.runs/impl_1/*.ltx]
if {$bit eq ""} { error "NO BITSTREAM PRODUCED" }
if {$ltx eq ""} { error "NO .ltx PROBE FILE. Hardware Manager cannot see the ILA." }
puts "### BITSTREAM $bit"
puts "### PROBES    $ltx"
write_hw_platform -fixed -include_bit -force $vdir/$proj.xsa
puts "### BITSTREAM COMPLETE. Screenshot the completion dialog / reports."
