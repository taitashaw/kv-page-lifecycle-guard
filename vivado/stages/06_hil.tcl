source [file dirname [info script]]/00_common.tcl
banner 6 6 "PROGRAM ZCU104 AND OPEN ILA"
open_project $pdir/$proj.xpr
open_hw_manager
connect_hw_server
if {[llength [get_hw_targets -quiet]] == 0} {
  error "NO JTAG TARGET. Power the ZCU104 and connect the USB-JTAG cable."
}
open_hw_target
current_hw_device [lindex [get_hw_devices *zu7*] 0]
# glob returns BOTH kv_guard_bd_wrapper.ltx and debug_nets.ltx (identical
# copies). Passing the list as one path gives [Common 17-48] File not found.
set bit [lindex [glob $pdir/*.runs/impl_1/*.bit] 0]
set ltx [lindex [lsort [glob $pdir/*.runs/impl_1/${bdname}_wrapper.ltx]] 0]
puts "### bit: $bit"
puts "### ltx: $ltx"
set_property PROGRAM.FILE  $bit [current_hw_device]
set_property PROBES.FILE   $ltx [current_hw_device]
set_property FULL_PROBES.FILE $ltx [current_hw_device]
program_hw_devices [current_hw_device]
refresh_hw_device  [current_hw_device]
if {[llength [get_hw_ilas -quiet]] == 0} {
  error "DEVICE PROGRAMMED BUT NO ILA ENUMERATED. Check the debug hub clock."
}
display_hw_ila_data [get_hw_ila_data -quiet]
puts "### BOARD PROGRAMMED. ILA dashboard open. Screenshot the waveform (gate G3)."
