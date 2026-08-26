source [file dirname [info script]]/00_common.tcl
puts "\n######## G9b  PHASE B LIVE IN HARDWARE MANAGER (for screenshot) ########"
#
# Same experiment as g9_negctrl.tcl phase B, but in the GUI so the waveform is
# on screen to capture. Nothing about the design changes: this programs the
# SAME bitstream and only writes CTRL bit 2 at runtime.
#
# Deliberately does NOT exit. Vivado stays open on the triggered waveform.
#
set XSCT /tools/Xilinx/2025.2/Vitis/bin/xsct
catch { exec $XSCT $root/vivado/hil/hil_bringup.tcl } out

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

set lif ""
foreach i [get_hw_ilas -quiet] {
  if {[string match "*ila_lifecycle*" [get_property CELL_NAME [get_hw_ilas $i]]]} { set lif $i }
}
set axi [lindex [get_hw_axis -quiet] 0]
catch { reset_hw_axi [get_hw_axis $axi] }

proc pname {ila frag} {
  set p [get_hw_probes -quiet -of_objects [get_hw_ilas $ila] -filter "NAME =~ *$frag"]
  return [get_property NAME [get_hw_probes $p -of_objects [get_hw_ilas $ila]]]
}
proc w {axi n a d} { catch { delete_hw_axi_txn [get_hw_axi_txns -quiet $n] }
  create_hw_axi_txn $n [get_hw_axis $axi] -type write -address $a -data $d
  catch { run_hw_axi [get_hw_axi_txns $n] } }
proc r {axi n a} { catch { delete_hw_axi_txn [get_hw_axi_txns -quiet $n] }
  create_hw_axi_txn $n [get_hw_axis $axi] -type read -address $a
  if {[catch { run_hw_axi [get_hw_axi_txns $n] } e]} { return "FAIL" }
  return [get_property DATA [get_hw_axi_txns $n]] }

# violation-only trigger: grant while a transfer is still in flight
set tsm $vdir/hil/trigger_violation.tsm
set_property CONTROL.TRIGGER_MODE ADVANCED_ONLY [get_hw_ilas $lif]
set_property CONTROL.TSM_FILE     $tsm          [get_hw_ilas $lif]
set_property CONTROL.CAPTURE_MODE BASIC         [get_hw_ilas $lif]
set_property CAPTURE_COMPARE_VALUE eq1'b1 \
  [get_hw_probes [pname $lif dbg_reuse_req] -of_objects [get_hw_ilas $lif]]
# depth BELOW the decision count, or wait_on_hw_ila never returns
set_property CONTROL.DATA_DEPTH       4 [get_hw_ilas $lif]
set_property CONTROL.TRIGGER_POSITION 0 [get_hw_ilas $lif]
run_hw_ila [get_hw_ilas $lif]
puts "### armed on VIOLATION: reuse_grant == 1 while inflight != 0"

# CTRL 0x15 = start | unsafe_bypass | sig_check_en
w $axi c1 A0000008 00000015
w $axi c2 A0000014 70000000
w $axi c3 A000001C 70010000
puts "### CTRL = [r $axi qc A0000008]   bit2 set, interlock removed"

for {set k 0} {$k < 12} {incr k} {
  foreach ev {00000000 00000001 00000002 00000004} {
    w $axi d1 A0000030 10000905
    w $axi d2 A0000034 $ev
    w $axi d3 A0000044 00000001
  }
  w $axi u1 A0000050 00010905
  w $axi u2 A0000054 00000001
}
puts "### grants=[r $axi q1 A00000A0]  refused=[r $axi q2 A0000060]  unsafe_commits=[r $axi q3 A0000068]"

if {[catch { wait_on_hw_ila -timeout 30 [get_hw_ilas $lif] } e]} {
  puts "### trigger did not fire in 30 s"
} else {
  puts "### VIOLATION TRIGGER FIRED"
}
display_hw_ila_data [upload_hw_ila_data [get_hw_ilas $lif]]
puts "###"
puts "### SCREENSHOT NOW. On the waveform look for:"
puts "###   dbg_reuse_grant  = 1   at the trigger marker"
puts "###   dbg_inflight    != 0   at the same sample"
puts "###   dbg_evictable    = 0   the frame was NOT safe to reuse"
puts "###   dbg_sticky            goes 01 -> 81, bit 7 is the RTL violation trap"
puts "### Vivado stays open. Close it yourself when done."
