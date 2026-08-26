source [file dirname [info script]]/00_common.tcl
puts "\n######## G3  ILA ON HARDWARE ########"
#
# ORDER IS LOAD-BEARING. Established by register read, not by guessing:
#
#   PL0_REF_CTRL   0x01010800  CLKACT=1, IOPLL/8 = 187.5 MHz   (clock fine)
#   REQ_ISO_STATUS 0x00000000                                   (isolation fine)
#   PCAP_STATUS    0x80000FD2  PL_DONE=0                        (FABRIC NOT CONFIGURED)
#
# Programming from XSCT and then attaching Vivado does NOT work: Vivado's
# open_hw_target re-scans the JTAG chain, which clears the PL configuration on
# ZynqMP. Hardware Manager still reports "Programmed" while PL_DONE reads 0.
#
# So: FSBL is loaded FIRST over XSCT (brings up pl_clk0), then Vivado connects,
# and only THEN is the PL programmed, from inside this session.
#
open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
current_hw_device [lindex [get_hw_devices *zu7*] 0]

set bit [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.bit] 0]
set ltx [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.ltx] 0]
puts "### bit: $bit"
puts "### ltx: $ltx"

set_property PROGRAM.FILE      $bit [current_hw_device]
set_property PROBES.FILE       $ltx [current_hw_device]
set_property FULL_PROBES.FILE  $ltx [current_hw_device]

puts "### programming from inside the Vivado session (after the chain scan)"
program_hw_devices [current_hw_device]
refresh_hw_device -update_hw_probes true [current_hw_device]

set ilas [get_hw_ilas -quiet]
if {[llength $ilas] == 0} {
  puts "### STILL NO ILA. devices: [get_hw_devices]"
  error "NO ILA ENUMERATED after programming from within Vivado."
}
puts "### ILA CORES: $ilas"
foreach i $ilas {
  puts "###   $i depth=[get_property CONTROL.DATA_DEPTH [get_hw_ilas $i]]"
}

set ila [lindex $ilas 0]
# Trigger immediately. Nothing is driving the guard yet, so a conditional
# trigger would sit armed forever and read as a failure.
set_property CONTROL.TRIGGER_POSITION 0 [get_hw_ilas $ila]
run_hw_ila -trigger_now [get_hw_ilas $ila]
catch { wait_on_hw_ila -timeout 1 [get_hw_ilas $ila] }
display_hw_ila_data [upload_hw_ila_data [get_hw_ilas $ila]]
puts "### ILA DASHBOARD OPEN. Gate G3 reachable."
