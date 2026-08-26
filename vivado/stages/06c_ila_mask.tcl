source [file dirname [info script]]/00_common.tcl
puts "\n######## G3  ILA (BSCAN user-mask sweep) ########"
#
# Labtools 27-3361 resolution #2: BSCAN_SWITCH_USER_MASK must match the design's
# C_USER_SCAN_CHAIN. On ZynqMP the PL BSCAN is reached THROUGH the PS TAP's
# BSCAN switch, and Hardware Manager only probes the USER chains this mask
# selects. Our design: C_USER_SCAN_CHAIN = 1, one BSCANE2 with CHAIN = 1.
#
# xsct sees the hub because it does not go through this mask. Vivado does.
#
open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices *zu7*] 0]
current_hw_device $dev

set bit [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.bit] 0]
set ltx [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.ltx] 0]
set_property PROGRAM.FILE     $bit $dev
set_property PROBES.FILE      $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
puts "### programming from inside Vivado (a chain re-scan clears PL config)"
program_hw_devices $dev

set found 0
# NOT 0x-prefixed: BSCAN_SWITCH_USER_MASK feeds a std::bitset, so hex notation
# throws bitset::_M_copy_from_ptr. Try plain integers, then binary strings.
foreach mask {1 2 4 8 3 15 0001 0010 0100 1000} {
  if {$found} break
  if {[catch { set_property BSCAN_SWITCH_USER_MASK $mask $dev } e]} {
    puts "### mask $mask rejected: $e"
    continue
  }
  if {[catch { refresh_hw_device -update_hw_probes true $dev } e]} {
    puts "### mask $mask refresh failed"
    continue
  }
  set ilas [get_hw_ilas -quiet]
  puts "### BSCAN_SWITCH_USER_MASK $mask -> ilas: '$ilas'"
  if {[llength $ilas] > 0} {
    set found 1
    puts "### >>> MASK $mask WORKS <<<"
  }
}

if {!$found} {
  error "No BSCAN_SWITCH_USER_MASK value exposed the hub."
}

set ila [lindex [get_hw_ilas] 0]
foreach i [get_hw_ilas] {
  puts "###   $i depth=[get_property CONTROL.DATA_DEPTH [get_hw_ilas $i]]"
}
# Trigger immediately: nothing drives the guard yet, so a conditional trigger
# would sit armed forever and read as a failure.
set_property CONTROL.TRIGGER_POSITION 0 [get_hw_ilas $ila]
run_hw_ila -trigger_now [get_hw_ilas $ila]
catch { wait_on_hw_ila -timeout 1 [get_hw_ilas $ila] }
display_hw_ila_data [upload_hw_ila_data [get_hw_ilas $ila]]
puts "### ILA DASHBOARD OPEN. Gate G3 reachable."
