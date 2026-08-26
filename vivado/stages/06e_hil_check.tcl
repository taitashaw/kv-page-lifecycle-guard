source [file dirname [info script]]/00_common.tcl
puts "\n######## G3  HIL CHECK: DRIVE THE GUARD, TRIGGER ON THE SAFETY PROPERTY ########"
#
# The control path is the JTAG-to-AXI master, not the PS. pl_clk0 still comes from
# the PS, so FSBL and the PMU isolation removal still run first
# (see docs/hil/ps_pl_isolation.md), but nothing in the STIMULUS touches the A53.
#
set XSCT /tools/Xilinx/2025.2/Vitis/bin/xsct
puts "### 1. PS clocks + isolation removal"
catch { exec $XSCT $root/vivado/hil/hil_bringup.tcl } out
puts $out

puts "### 2. program"
open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices *zu7*] 0]
current_hw_device $dev
set_property PROGRAM.FILE     [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.bit] 0] $dev
set_property PROBES.FILE      [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.ltx] 0] $dev
set_property FULL_PROBES.FILE [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.ltx] 0] $dev
program_hw_devices $dev
refresh_hw_device -update_hw_probes true $dev

set ila [lindex [get_hw_ilas -quiet] 0]
set axi [lindex [get_hw_axis -quiet] 0]
if {$ila eq ""} { error "NO ILA. see docs/hil/ps_pl_isolation.md" }
if {$axi eq ""} { error "NO JTAG-AXI MASTER. the bitstream predates jtag_axi_0" }
puts "### ILA: $ila    AXI master: $axi"

puts "### 3. arming on reuse_grant (probe bit 66)"
set p [lindex [get_hw_probes -quiet -of_objects [get_hw_ilas $ila]] 0]
set_property CONTROL.TRIGGER_POSITION 1024 [get_hw_ilas $ila]
set patt "[string repeat x 129]1[string repeat x 66]"
set armed 0
if {[catch { set_property TRIGGER_COMPARE_VALUE eq196'b$patt \
             [get_hw_probes $p -of_objects [get_hw_ilas $ila]] } e]} {
  puts "### bit-66 trigger rejected ($e); arming trigger_now instead"
} else { set armed 1 }
run_hw_ila [get_hw_ilas $ila]

puts "### 4. driving the guard over JTAG-AXI (no PS involved)"
# AXI4-Lite has no burst, so -len is invalid here. Report the actual response
# code rather than letting a generic failure hide a DECERR/SLVERR.
proc axiw {axi name addr data} {
  catch { delete_hw_axi_txn [get_hw_axi_txns -quiet $name] }
  create_hw_axi_txn $name [get_hw_axis $axi] -type write -address $addr -data $data
  if {[catch { run_hw_axi [get_hw_axi_txns $name] } e]} {
    puts "###   WRITE $addr FAILED: $e"
    catch { puts "###     resp=[get_property STATUS.RESP [get_hw_axi_txns $name]]" }
    return 0
  }
  return 1
}
proc axir {axi name addr} {
  catch { delete_hw_axi_txn [get_hw_axi_txns -quiet $name] }
  create_hw_axi_txn $name [get_hw_axis $axi] -type read -address $addr
  if {[catch { run_hw_axi [get_hw_axi_txns $name] } e]} { return "FAILED" }
  return [get_property DATA [get_hw_axi_txns $name]]
}
# CTRL: bit0 enable, bit4 sig_check_en. Omitting bit 4 silently disables the
# payload comparator, which is exactly how the top-level testbench once "passed".
puts "###   ID register reads: [axir $axi rd_id A0000000]"
axiw $axi w_ctrl  A0000008 00000011
axiw $axi w_blo   A0000014 70000000
axiw $axi w_bhi   A0000018 00000000
axiw $axi w_llo   A000001C 70010000
axiw $axi w_lhi   A0000020 00000000
# a read inside the window
axiw $axi w_desc  A0000030 00001249
axiw $axi w_alo   A0000038 70000100
axiw $axi w_ahi   A000003C 00000000
axiw $axi w_sig   A0000040 CAFEBABE
axiw $axi w_cfg   A0000034 00000020
axiw $axi w_go    A0000044 00000001
after 200
# reuse request against that slot while the transfer may still be in flight:
# this is the lifecycle interlock under test
axiw $axi w_rcfg  A0000050 00000009
axiw $axi w_rgo   A0000054 00000001
after 200

puts "### 5. counters read back over JTAG-AXI"
foreach {nm off} {reuse_refused A0000060 stale A0000064 unsafe A0000068
                  payload_mm A000006C complete A0000074 win_refused A0000078
                  dispatch A0000088 accept A000008C} {
  puts [format "###   %-14s %s" $nm [axir $axi rd_$nm $off]]
}

puts "### 6. capture"
if {[catch { wait_on_hw_ila -timeout 20 [get_hw_ilas $ila] } e]} {
  puts "### trigger did not fire in 20 s. If armed on bit 66, that means NO"
  puts "### reuse_grant occurred during the stimulus, which is the SAFE outcome."
  run_hw_ila -trigger_now [get_hw_ilas $ila]
  catch { wait_on_hw_ila -timeout 10 [get_hw_ilas $ila] }
}
set d [upload_hw_ila_data [get_hw_ilas $ila]]
display_hw_ila_data $d
write_hw_ila_data -force $vdir/hil_capture.ila $d
puts "### CAPTURE SAVED $vdir/hil_capture.ila (armed_on_property=$armed)"
puts "### HIL CHECK COMPLETE"
