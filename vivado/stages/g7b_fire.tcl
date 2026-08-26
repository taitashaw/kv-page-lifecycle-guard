source [file dirname [info script]]/00_common.tcl
puts "\n######## G7b  ARM THE ADVANCED TRIGGER, THEN MAKE IT FIRE ########"
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
set_property CONTROL.TRIGGER_MODE ADVANCED_ONLY [get_hw_ilas $lif]
set_property CONTROL.TSM_FILE $vdir/hil/trigger.tsm [get_hw_ilas $lif]
set_property CONTROL.CAPTURE_MODE BASIC [get_hw_ilas $lif]
set_property CAPTURE_COMPARE_VALUE eq1'b1 \
  [get_hw_probes [pname $lif dbg_reuse_req] -of_objects [get_hw_ilas $lif]]
# TRIGGER POSITION 0 is mandatory with storage qualification on sparse events.
# The position counts QUALIFIED samples, not clock cycles, so position 512 waits
# for 512 reuse requests before it will arm. With one-shot stimulus that is
# never. Position 0 triggers on the first qualifying decision.
# DEPTH MUST MATCH THE EVENT COUNT when storage qualification is on. The window
# completes only when DATA_DEPTH *qualified* samples have been stored, not when
# DATA_DEPTH clock cycles pass. Depth 2048 with 12 decisions sits in Post-trigger
# forever. 16 fills from a 12-decision run with room to spare.
set_property CONTROL.DATA_DEPTH 8 [get_hw_ilas $lif]
set_property CONTROL.TRIGGER_POSITION 0 [get_hw_ilas $lif]
run_hw_ila [get_hw_ilas $lif]
puts "### ARMED: mode=[get_property CONTROL.TRIGGER_MODE [get_hw_ilas $lif]] capture=[get_property CONTROL.CAPTURE_MODE [get_hw_ilas $lif]]"
proc w {axi n a d} { catch { delete_hw_axi_txn [get_hw_axi_txns -quiet $n] }
  create_hw_axi_txn $n [get_hw_axis $axi] -type write -address $a -data $d
  catch { run_hw_axi [get_hw_axi_txns $n] } }
proc r {axi n a} { catch { delete_hw_axi_txn [get_hw_axi_txns -quiet $n] }
  create_hw_axi_txn $n [get_hw_axis $axi] -type read -address $a
  if {[catch { run_hw_axi [get_hw_axi_txns $n] } e]} { return "FAIL" }
  return [get_property DATA [get_hw_axi_txns $n]] }
w $axi c1 A0000008 00000011
w $axi c2 A0000014 70000000
w $axi c3 A000001C 70010000
foreach {tag ev} {ACQUIRE 00000000 ADMIT 00000001 ISSUE 00000002 RELEASE 00000004} {
  w $axi d1 A0000030 10000905
  w $axi d2 A0000034 $ev
  w $axi d3 A0000044 00000001
}
puts "### draining state built: refcount==0, inflight==1"
# Repeat so the qualified window holds a run of DECISIONS rather than one.
for {set k 0} {$k < 24} {incr k} {
  w $axi u1 A0000050 00010905
  w $axi u2 A0000054 00000001
  foreach ev {00000000 00000001 00000002 00000004} {
    w $axi d1 A0000030 10000905
    w $axi d2 A0000034 $ev
    w $axi d3 A0000044 00000001
  }
}
puts "### 24 reuse decisions driven. grant=[r $axi q1 A00000A0] refused=[r $axi q2 A0000060]"
if {[catch { wait_on_hw_ila -timeout 30 [get_hw_ilas $lif] } e]} {
  puts "### wait returned: $e  (uploading whatever the window holds)"
} else { puts "### TRIGGERED and window complete." }
set d [upload_hw_ila_data [get_hw_ilas $lif]]
display_hw_ila_data $d
write_hw_ila_data -force -csv_file $vdir/g7_fired.csv $d
puts "### G7b COMPLETE. Screenshot the triggered waveform."
