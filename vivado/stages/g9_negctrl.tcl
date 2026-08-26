source [file dirname [info script]]/00_common.tcl
puts "\n######## G9  NEGATIVE CONTROL: MAKE THE VIOLATION TRIGGER FIRE ########"
#
# The open objection to the whole result is this: the ILA was armed on
# "reuse_grant == 1 while inflight != 0" and never fired. A trigger that never
# fires is indistinguishable from a trigger that CANNOT fire. Until the
# instrument is shown catching a real violation, "zero violations" is not
# evidence of safety, it is an absence of evidence.
#
# page_state_lut.sv:195-208 exists for exactly this. CTRL bit 2 (unsafe_bypass)
# removes the evictable interlock and commits a reuse while leaving inflight
# set, which is precisely the condition the trigger watches for.
#
# This script runs BOTH polarities against the SAME bitstream in ONE session:
#   PHASE A  bypass OFF -> reuse in the draining state must be REFUSED
#   PHASE B  bypass ON  -> the same stimulus must GRANT, count an unsafe commit,
#                          and FIRE the violation trigger
#   PHASE C  bypass OFF again -> refusal returns, proving B was the bit and not
#                          drift, a stale capture or a wedged design
#
# SAFETY: neither unsafe mode can widen the AXI window. axi_lite_regs.sv:24-26
# and axi_read_manager.sv:12 both record that the address gate lives in
# axi_read_manager, which has no bypass input. The read master stays inside the
# 256 MB scratch aperture at 0x7000_0000 throughout.
#
set XSCT /tools/Xilinx/2025.2/Vitis/bin/xsct
catch { exec $XSCT $root/vivado/hil/hil_bringup.tcl } out
foreach l [split $out \n] { if {[string match "*PL_DONE*" $l] || [string match "*FSBL*" $l]} { puts "###   $l" } }

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
if {$lif eq ""} { error "lifecycle ILA not found" }
set axi [lindex [get_hw_axis -quiet] 0]
catch { reset_hw_axi [get_hw_axis $axi] }

proc pname {ila frag} {
  set p [get_hw_probes -quiet -of_objects [get_hw_ilas $ila] -filter "NAME =~ *$frag"]
  if {[llength $p] != 1} { error "probe '$frag' resolved to [llength $p] matches" }
  return [get_property NAME [get_hw_probes $p -of_objects [get_hw_ilas $ila]]]
}
proc w {axi n a d} { catch { delete_hw_axi_txn [get_hw_axi_txns -quiet $n] }
  create_hw_axi_txn $n [get_hw_axis $axi] -type write -address $a -data $d
  catch { run_hw_axi [get_hw_axi_txns $n] } }
proc r {axi n a} { catch { delete_hw_axi_txn [get_hw_axi_txns -quiet $n] }
  create_hw_axi_txn $n [get_hw_axis $axi] -type read -address $a
  if {[catch { run_hw_axi [get_hw_axi_txns $n] } e]} { return "FAIL" }
  return [get_property DATA [get_hw_axi_txns $n]] }

set P_GRANT [pname $lif dbg_reuse_grant]
set P_INF   [pname $lif dbg_inflight]
set P_REQ   [pname $lif dbg_reuse_req]

# ---- trigger armed on the VIOLATION ALONE. Nothing else may fire it. --------
set tsm $vdir/hil/trigger_violation.tsm
set fh [open $tsm w]
puts $fh "# Violation-only trigger. Fires if and only if a reuse is GRANTED"
puts $fh "# while a transfer is still in flight. In phase A this must not fire."
puts $fh "state st_watch:"
puts $fh "  if (${P_GRANT} == 1'b1 && ${P_INF} != 6'b000000) then"
puts $fh "    trigger;"
puts $fh "  else"
puts $fh "    goto st_watch;"
puts $fh "  endif"
close $fh

proc arm {lif tsm req} {
  set_property CONTROL.TRIGGER_MODE ADVANCED_ONLY [get_hw_ilas $lif]
  set_property CONTROL.TSM_FILE     $tsm          [get_hw_ilas $lif]
  set_property CONTROL.CAPTURE_MODE BASIC         [get_hw_ilas $lif]
  set_property CAPTURE_COMPARE_VALUE eq1'b1 \
    [get_hw_probes $req -of_objects [get_hw_ilas $lif]]
  # Storage qualification counts QUALIFIED SAMPLES, not cycles. The window
  # completes only after DATA_DEPTH *qualified* samples are stored, and
  # wait_on_hw_ila blocks on window completion, NOT on its own -timeout. So
  # DATA_DEPTH must be comfortably BELOW the number of decisions driven, or the
  # call hangs forever. MEASURED: depth 8 against 6 decisions hung for 12
  # minutes with the -timeout 20 ignored. Depth 4 against 12 decisions is safe.
  # Same trap as g7b_fire.tcl:34-37, in the opposite direction.
  set_property CONTROL.DATA_DEPTH       4 [get_hw_ilas $lif]
  set_property CONTROL.TRIGGER_POSITION 0 [get_hw_ilas $lif]
  run_hw_ila [get_hw_ilas $lif]
}

# rebuild ACQUIRE -> ADMIT -> ISSUE -> RELEASE. Leaves refcount 0, inflight > 0.
proc drain {axi} {
  foreach ev {00000000 00000001 00000002 00000004} {
    w $axi d1 A0000030 10000905
    w $axi d2 A0000034 $ev
    w $axi d3 A0000044 00000001
  }
}
proc reuse {axi} { w $axi u1 A0000050 00010905 ; w $axi u2 A0000054 00000001 }

proc counters {axi} {
  return [list [r $axi qg A00000A0] [r $axi qr A0000060] [r $axi qu A0000068]]
}
proc show {tag c} {
  lassign $c g rf u
  puts [format "###   %-10s grant=%s  refused=%s  unsafe_commit=%s" $tag $g $rf $u]
}

set results {}
foreach {phase ctrl expect} {A 00000011 REFUSE B 00000015 GRANT C 00000011 REFUSE} {
  puts "\n### ---------------- PHASE $phase   CTRL=0x$ctrl   expect $expect ----------------"
  arm $lif $tsm $P_REQ
  w $axi c0 A0000008 00000002        ;# soft_reset, one-shot
  w $axi c1 A0000008 $ctrl
  w $axi c2 A0000014 70000000
  w $axi c3 A000001C 70010000
  puts "###   CTRL readback = [r $axi qc A0000008]   (bit2 = unsafe_bypass)"
  set before [counters $axi]
  show "before" $before
  for {set k 0} {$k < 12} {incr k} { drain $axi ; reuse $axi }
  set after [counters $axi]
  show "after " $after
  lassign $before g0 r0 u0
  lassign $after  g1 r1 u1
  set dg [expr {"0x$g1" - "0x$g0"}]
  set dr [expr {"0x$r1" - "0x$r0"}]
  set du [expr {"0x$u1" - "0x$u0"}]
  puts [format "###   delta      grants=%d  refusals=%d  unsafe_commits=%d" $dg $dr $du]

  # NEVER block waiting on a trigger that is supposed to stay silent. In phases
  # A and C the violation must not fire, so wait_on_hw_ila would sit on an
  # incomplete window forever. The COUNTERS are the authority for those phases:
  # grants 0 and unsafe_commits 0 is what proves no violation happened. The
  # forced capture is only there to show grant flat at 0 on a waveform.
  set fired 0
  if {$expect eq "GRANT"} {
    if {[catch { wait_on_hw_ila -timeout 30 [get_hw_ilas $lif] } e]} {
      puts "###   VIOLATION TRIGGER: did NOT fire within 30 s"
    } else {
      set fired 1
      puts "###   VIOLATION TRIGGER: FIRED"
    }
  } else {
    puts "###   VIOLATION TRIGGER: must stay silent here; forcing a capture instead"
    catch { run_hw_ila -trigger_now [get_hw_ilas $lif] }
    catch { wait_on_hw_ila -timeout 15 [get_hw_ilas $lif] }
  }
  if {[catch {
        set d [upload_hw_ila_data [get_hw_ilas $lif]]
        write_hw_ila_data -force -csv_file $vdir/g9_phase${phase}.csv $d
      } e]} { puts "###   capture upload failed: $e" }
  lappend results [list $phase $dg $dr $du $fired]
}

puts "\n######## G9 VERDICT ########"
puts [format "### %-6s %-8s %-9s %-15s %s" phase grants refusals unsafe_commits trigger_fired]
foreach row $results {
  lassign $row p dg dr du f
  puts [format "###   %-4s %-8d %-9d %-15d %s" $p $dg $dr $du [expr {$f ? "FIRED" : "silent"}]]
}
lassign [lindex $results 0] . Ag Ar Au Af
lassign [lindex $results 1] . Bg Br Bu Bf
lassign [lindex $results 2] . Cg Cr Cu Cf
set ok 1
if {$Ag != 0 || $Au != 0 || $Ar == 0 || $Af != 0} { set ok 0 ; puts "### PHASE A FAILED: safe mode did not refuse cleanly, or the trigger fired when it must not" }
if {$Bg == 0 || $Bu == 0 || $Bf != 1}             { set ok 0 ; puts "### PHASE B FAILED: bypass did not produce a counted, captured violation" }
if {$Cg != 0 || $Cu != 0 || $Cr == 0 || $Cf != 0} { set ok 0 ; puts "### PHASE C FAILED: refusal did not return after clearing the bit" }
if {$ok} {
  puts "### PASS. The violation trigger is demonstrably capable of firing."
  puts "### Zero violations in safe mode is now evidence, not an absence of evidence."
} else {
  puts "### NOT A PASS. Do not report this as a result."
}
