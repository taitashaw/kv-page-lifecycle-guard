source [file dirname [info script]]/00_common.tcl
puts "\n######## G10  ARM, THEN FIRE ON CAMERA ########"
#
# Produces the video: the ILA sitting armed and waiting, then catching a real
# safety violation live. Nothing about the design changes. Same bitstream, one
# runtime control-register bit.
#
# Handshake, because the recorder has to be rolling BEFORE the trigger fires:
#   1. program, arm the violation trigger, then write ARMED_FILE
#   2. the shell sees ARMED_FILE, starts ffmpeg, then writes GO_FILE
#   3. this script sees GO_FILE and drives the stimulus, so the transition from
#      "Waiting for Trigger" to a populated waveform happens on camera
#
set ARMED $vdir/.g10_armed
set GO    $vdir/.g10_go
catch { file delete $ARMED $GO }

# GUI mode sends puts to the Tcl console, so diagnostics go to a file too.
set ::LOGF [open $vdir/g10_report.txt w]
proc say {m} { puts $m ; puts $::LOGF $m ; flush $::LOGF }

set XSCT /tools/Xilinx/2025.2/Vitis/bin/xsct

# Drops the PS-PL isolation wall. MUST NOT be wrapped in a bare catch: a silent
# failure here shows up much later as "set_property expects at least one object",
# because no debug cores ever appear and the ILA lookup returns empty.
# It also needs the JTAG cable free, so no Vivado may hold the target.
proc bringup {tag} {
  set rc [catch { exec $::XSCT $::root/vivado/hil/hil_bringup.tcl } out]
  set done [expr {[string match "*PL_DONE*1*" $out] || [string match "*isolation*" $out]}]
  say "### bringup ($tag): rc=$rc  PL evidence=[expr {$done ? {yes} : {no}}]"
  foreach l [split $out \n] {
    if {[string match -nocase "*PL_DONE*" $l] || [string match -nocase "*isolation*" $l]} { say "###     $l" }
  }
  return $rc
}

# ORDER IS NOT NEGOTIABLE, and getting it wrong is self-defeating:
#   hil_bringup.tcl runs psu_init, which resets the PS and WIPES the PL
#   configuration. MEASURED: running it after program_hw_devices left the device
#   at DONE=0, "not programmed" ([Labtools 27-1435]), so retrying the bring-up
#   to recover the debug hub destroyed the very bitstream that contains it.
# So: bring up FIRST, then program. Any later bring-up must be followed by a
# fresh program, never a bare refresh.
proc find_ila {} {
  foreach i [get_hw_ilas -quiet] {
    if {[string match "*ila_lifecycle*" [get_property CELL_NAME [get_hw_ilas $i]]]} { return $i }
  }
  return ""
}

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121

set lif ""
for {set try 1} {$try <= 3 && $lif eq ""} {incr try} {
  # the JTAG cable must be free for xsct, so no target may be open here
  catch { close_hw_target }
  if {[bringup "attempt $try"] != 0} {
    say "### bring-up failed on attempt $try (cable busy?), retrying"
    after 3000
    continue
  }
  open_hw_target
  set dev [lindex [get_hw_devices *zu7*] 0]
  current_hw_device $dev
  set_property PROGRAM.FILE     [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.bit] 0] $dev
  set_property PROBES.FILE      [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.ltx] 0] $dev
  set_property FULL_PROBES.FILE [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.ltx] 0] $dev
  program_hw_devices $dev
  refresh_hw_device -update_hw_probes true $dev
  # Do NOT read REGISTER.IR.BIT5_DONE here. MEASURED: hw_device has no such
  # property and the error aborts the script AFTER the cores are already up,
  # leaving an unconfigured trigger. Same trap as CORE_STATUS on hw_ila.
  # The core count is the thing that actually matters, and it is queryable.
  say "### attempt $try: ilas=[llength [get_hw_ilas -quiet]]  axi=[llength [get_hw_axis -quiet]]"
  set lif [find_ila]
}
if {$lif eq ""} {
  close $::LOGF
  error "NO DEBUG CORES after 3 attempts. See docs/hil/ps_pl_isolation.md"
}
say "### lifecycle ILA found: $lif"
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

# Capture ALWAYS, not storage-qualified. Qualifying on dbg_reuse_req filters out
# the very cycle the grant asserts, which is why the earlier screenshots showed
# dbg_reuse_grant flat at 0 even on a run that did violate. With ALWAYS and the
# trigger mid-window, the grant pulse and its surrounding context are both in
# frame.
set_property CONTROL.TRIGGER_MODE ADVANCED_ONLY [get_hw_ilas $lif]
set_property CONTROL.TSM_FILE     $vdir/hil/trigger_violation.tsm [get_hw_ilas $lif]
set_property CONTROL.CAPTURE_MODE ALWAYS  [get_hw_ilas $lif]
set_property CONTROL.DATA_DEPTH        1024 [get_hw_ilas $lif]
set_property CONTROL.TRIGGER_POSITION   512 [get_hw_ilas $lif]

# safe mode first, so the armed state on camera is a genuine safe design
w $axi c1 A0000008 00000011
w $axi c2 A0000014 70000000
w $axi c3 A000001C 70010000
run_hw_ila [get_hw_ilas $lif]
puts "### ARMED and waiting. Violation trigger only. Safe mode, so it will not fire."

set fh [open $ARMED w] ; puts $fh ready ; close $fh
puts "### waiting for the recorder ..."
for {set i 0} {$i < 300} {incr i} {
  if {[file exists $GO]} break
  after 500
}
say "### GO received, recorder rolling"
after 6000

say "### PHASE 1 safe traffic: reuse on a draining page must be REFUSED"
for {set k 0} {$k < 4} {incr k} {
  foreach ev {00000000 00000001 00000002 00000004} {
    w $axi d1 A0000030 10000905 ; w $axi d2 A0000034 $ev ; w $axi d3 A0000044 00000001
  }
  w $axi u1 A0000050 00010905 ; w $axi u2 A0000054 00000001
}
say "###   grants=[r $axi q1 A00000A0]  refused=[r $axi q2 A0000060]  trigger still silent"
after 4000

say "### PHASE 2 removing the interlock: CTRL bit 2"
w $axi c9 A0000008 00000015
after 2000
for {set k 0} {$k < 4} {incr k} {
  foreach ev {00000000 00000001 00000002 00000004} {
    w $axi d1 A0000030 10000905 ; w $axi d2 A0000034 $ev ; w $axi d3 A0000044 00000001
  }
  w $axi u1 A0000050 00010905 ; w $axi u2 A0000054 00000001
}
say "###   grants=[r $axi q3 A00000A0]  unsafe_commits=[r $axi q4 A0000068]  CTRL=[r $axi qc A0000008]"

if {[catch { wait_on_hw_ila -timeout 30 [get_hw_ilas $lif] } e]} {
  say "### trigger did NOT fire"
} else {
  say "### VIOLATION TRIGGER FIRED"
}
display_hw_ila_data [upload_hw_ila_data [get_hw_ilas $lif]]
write_hw_ila_data -force -csv_file $vdir/g10_violation.csv [upload_hw_ila_data [get_hw_ilas $lif]]
after 10000
say "### G10 done."
close $::LOGF
