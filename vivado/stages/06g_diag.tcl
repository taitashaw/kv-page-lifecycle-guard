source [file dirname [info script]]/00_common.tcl
puts "\n######## G3  DIAGNOSTIC CAPTURE ########"
#
# The probe now carries two fields that make the fault visible instead of
# inferable:
#   bit 144      rst_n as the guard actually sees it
#   bits 160:145 free-running heartbeat, NOT reset
#
# Two captures separated in time. If the heartbeat advances, the guard's clock
# is live. If rst_n reads 1, it is out of reset. Between them these settle
# every hypothesis that has cost the last several build cycles.
#
set XSCT /tools/Xilinx/2025.2/Vitis/bin/xsct
catch { exec $XSCT $root/vivado/hil/hil_bringup.tcl } out
foreach l [split $out \n] { if {[string match "*FSBL*" $l]} { puts "    $l" } }

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices *zu7*] 0]
current_hw_device $dev
set bitf [glob -nocomplain $pdir/*.runs/impl_1/${bdname}_wrapper.bit]
if {[llength $bitf] == 0} { error "NO BITSTREAM" }
set_property PROGRAM.FILE     [lindex $bitf 0] $dev
set_property PROBES.FILE      [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.ltx] 0] $dev
set_property FULL_PROBES.FILE [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.ltx] 0] $dev
program_hw_devices $dev
refresh_hw_device -update_hw_probes true $dev

set ila [lindex [get_hw_ilas -quiet] 0]
set axi [lindex [get_hw_axis -quiet] 0]
puts "### ILA=$ila  AXI=$axi"
catch { reset_hw_axi [get_hw_axis $axi] }

# capture ALWAYS: we want raw cycles, not qualified events, for this diagnostic
catch { set_property CONTROL.CAPTURE_MODE ALWAYS [get_hw_ilas $ila] }
set_property CONTROL.TRIGGER_POSITION 0 [get_hw_ilas $ila]

proc grab {ila vdir tag} {
  run_hw_ila -trigger_now [get_hw_ilas $ila]
  catch { wait_on_hw_ila -timeout 10 [get_hw_ilas $ila] }
  set d [upload_hw_ila_data [get_hw_ilas $ila]]
  write_hw_ila_data -force -csv_file $vdir/diag_$tag.csv $d
  puts "### capture $tag written"
}

grab $ila $vdir a
after 2000
grab $ila $vdir b

# drive one AXI write between captures so a third capture can show bus activity
puts "### attempting one AXI write (A0000008 = 0x11)"
catch { delete_hw_axi_txn [get_hw_axi_txns -quiet wtest] }
create_hw_axi_txn wtest [get_hw_axis $axi] -type write -address A0000008 -data 00000011
if {[catch { run_hw_axi [get_hw_axi_txns wtest] } e]} {
  puts "### AXI WRITE STILL FAILS: $e"
} else {
  puts "### AXI WRITE SUCCEEDED"
}
grab $ila $vdir c
puts "### DIAG COMPLETE"
