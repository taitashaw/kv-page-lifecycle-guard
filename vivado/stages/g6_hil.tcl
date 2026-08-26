source [file dirname [info script]]/00_common.tcl
puts "\n######## G6  HIL: THE SAFETY PROPERTY ON SILICON ########"
set XSCT /tools/Xilinx/2025.2/Vitis/bin/xsct
catch { exec $XSCT $root/vivado/hil/hil_bringup.tcl } out
foreach l [split $out \n] { if {[string match "*FSBL*" $l]} { puts "###   $l" } }

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

# identify the two cores by cell name, not by index
set lif ""; set sil ""
foreach i [get_hw_ilas -quiet] {
  set cn [get_property CELL_NAME [get_hw_ilas $i]]
  if {[string match "*ila_lifecycle*" $cn]} { set lif $i }
  if {[string match "*sila_axi*"      $cn]} { set sil $i }
}
set axi [lindex [get_hw_axis -quiet] 0]
puts "### lifecycle ILA=$lif   system ILA=$sil   AXI master=$axi"
catch { reset_hw_axi [get_hw_axis $axi] }

proc pb {ila n} { return [get_hw_probes -quiet -of_objects [get_hw_ilas $ila] \
                          -filter "NAME =~ *$n"] }
proc w {axi n a d} { catch { delete_hw_axi_txn [get_hw_axi_txns -quiet $n] }
  create_hw_axi_txn $n [get_hw_axis $axi] -type write -address $a -data $d
  catch { run_hw_axi [get_hw_axi_txns $n] } }
proc r {axi n a} { catch { delete_hw_axi_txn [get_hw_axi_txns -quiet $n] }
  create_hw_axi_txn $n [get_hw_axis $axi] -type read -address $a
  if {[catch { run_hw_axi [get_hw_axi_txns $n] } e]} { return "FAIL" }
  return [get_property DATA [get_hw_axi_txns $n]] }

# ---------------------------------------------------------------- 1 LIVENESS
# Never interpret a capture before this passes. Every state field reads zero
# both when the guard is idle and when it is held in reset.
run_hw_ila -trigger_now [get_hw_ilas $lif]
catch { wait_on_hw_ila -timeout 10 [get_hw_ilas $lif] }
set d1 [upload_hw_ila_data [get_hw_ilas $lif]]
write_hw_ila_data -force -csv_file $vdir/g6_live.csv $d1
puts "### 1. LIVENESS: id=[r $axi q0 A0000000]  (4c475031 = ASCII LGP1)"

# ------------------------------------------------------- 2 ARM ON THE REFUSAL
# Trigger on the event that SHOULD happen. Arming only on reuse_grant is a trap:
# if the design is correct it never fires, which is indistinguishable from a
# broken ILA.
set p_ref [pb $lif dbg_reuse_refused]
set_property CONTROL.TRIGGER_POSITION 1024 [get_hw_ilas $lif]
set armed 0
if {[catch { set_property TRIGGER_COMPARE_VALUE eq1'b1 [get_hw_probes $p_ref -of_objects [get_hw_ilas $lif]] } e]} {
  puts "### 2. could not arm on dbg_reuse_refused: $e"
} else { set armed 1; puts "### 2. armed on dbg_reuse_refused == 1" }
run_hw_ila [get_hw_ilas $lif]

# ------------------------------------------- 3 POSITIVE CONTROL: idle -> GRANT
w $axi c1 A0000008 00000011
w $axi c2 A0000014 70000000
w $axi c3 A000001C 70010000
w $axi p1 A0000050 00010905
w $axi p2 A0000054 00000001
puts "### 3. CONTROL, reuse of an IDLE frame -> grant=[r $axi q1 A00000A0] refused=[r $axi q2 A0000060]"
puts "###    (a guard that refuses everything is useless; this must GRANT)"

# ------------------------------------ 4 THE DRAINING CASE: refcount 0, inflight 1
# inflight only increments on ISSUE, and ISSUE requires ADMIT first. Skipping
# either leaves inflight at 0 and the test proves nothing.
foreach {tag ev} {ACQUIRE 00000000 ADMIT 00000001 ISSUE 00000002} {
  w $axi d1 A0000030 10000905
  w $axi d2 A0000034 $ev
  w $axi d3 A0000044 00000001
}
w $axi d4 A0000030 10000905
w $axi d5 A0000034 00000004
w $axi d6 A0000044 00000001
puts "### 4. ACQUIRE -> ADMIT -> ISSUE -> RELEASE. Now refcount==0 AND inflight==1."
puts "###    A refcount-only check calls this frame FREE. It is not."
set g_before [r $axi q3 A00000A0]
w $axi u1 A0000050 00010905
w $axi u2 A0000054 00000001
puts "### 5. REUSE ATTEMPT while draining:"
puts "###    grant  $g_before -> [r $axi q4 A00000A0]"
puts "###    refused          -> [r $axi q5 A0000060]"
puts "###    unsafe_commit    -> [r $axi q6 A0000068]"

# --------------------------------------------------------- 6 CAPTURE + PERF
if {[catch { wait_on_hw_ila -timeout 20 [get_hw_ilas $lif] } e]} {
  puts "### 6. trigger did not fire in 20 s"
  run_hw_ila -trigger_now [get_hw_ilas $lif]
  catch { wait_on_hw_ila -timeout 10 [get_hw_ilas $lif] }
} else { puts "### 6. TRIGGERED on dbg_reuse_refused" }
set d2 [upload_hw_ila_data [get_hw_ilas $lif]]
display_hw_ila_data $d2
write_hw_ila_data -force -csv_file $vdir/g6_drain.csv $d2
if {$sil ne ""} {
  run_hw_ila -trigger_now [get_hw_ilas $sil]
  catch { wait_on_hw_ila -timeout 10 [get_hw_ilas $sil] }
  write_hw_ila_data -force -csv_file $vdir/g6_axi.csv [upload_hw_ila_data [get_hw_ilas $sil]]
  puts "### system ILA capture written (protocol-decoded AXI)"
}
puts "### G6 COMPLETE. Screenshot the ILA waveform."
