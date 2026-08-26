source [file dirname [info script]]/00_common.tcl
puts "\n######## G7  ADVANCED TRIGGER + STORAGE QUALIFICATION ########"
#
# Three changes, all Hardware Manager only. No rebuild.
#
# 1. TRIGGER MODE -> ADVANCED. BASIC_ONLY can express one comparison per probe
#    and cannot AND two probes together, so the violation condition
#    (grant AND inflight != 0) is inexpressible in BASIC.
#
# 2. A trigger state machine that fires on EITHER:
#      VIOLATION: dbg_reuse_grant == 1 while dbg_inflight != 0
#                 a frame handed out while a transfer is still reading it.
#                 This must NEVER fire. If it does, the safety claim is dead.
#      EXPECTED:  dbg_reuse_refused == 1
#                 the interlock doing its job. This is the positive evidence.
#    Arming on the violation alone is useless: never firing is indistinguishable
#    from a broken ILA. Arming on both makes each capture self-classifying.
#
# 3. CAPTURE MODE -> BASIC with a qualifier. At 187.5 MHz, 2048 samples in
#    ALWAYS mode is a 10.9 us window, and JTAG-driven stimulus arrives
#    milliseconds apart, so the buffer would fill with idle. Qualifying on
#    dbg_reuse_req means the window holds 2048 DECISIONS instead.
#
open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices *zu7*] 0]
current_hw_device $dev
set_property PROBES.FILE      [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.ltx] 0] $dev
set_property FULL_PROBES.FILE [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.ltx] 0] $dev
refresh_hw_device -update_hw_probes true $dev

set lif ""
foreach i [get_hw_ilas -quiet] {
  if {[string match "*ila_lifecycle*" [get_property CELL_NAME [get_hw_ilas $i]]]} { set lif $i }
}
if {$lif eq ""} { error "lifecycle ILA not found" }

# Resolve full probe names from the device rather than hard-coding them.
proc pname {ila frag} {
  set p [get_hw_probes -quiet -of_objects [get_hw_ilas $ila] -filter "NAME =~ *$frag"]
  if {[llength $p] != 1} { error "probe '$frag' resolved to [llength $p] matches" }
  return [get_property NAME [get_hw_probes $p -of_objects [get_hw_ilas $ila]]]
}
set P_GRANT [pname $lif dbg_reuse_grant]
set P_REF   [pname $lif dbg_reuse_refused]
set P_INF   [pname $lif dbg_inflight]
set P_REQ   [pname $lif dbg_reuse_req]
puts "### probes resolved:"
foreach n [list $P_GRANT $P_REF $P_INF $P_REQ] { puts "###   $n" }

# ------------------------------------------------------ trigger state machine
set tsm $vdir/hil/trigger.tsm
set fh [open $tsm w]
puts $fh "# Trigger state machine, generated. Fires on the violation OR the"
puts $fh "# expected refusal, so every capture is self-classifying."
puts $fh "state st_watch:"
puts $fh "  if (${P_GRANT} == 1'b1 && ${P_INF} != 6'b000000) then"
puts $fh "    trigger;"
puts $fh "  elseif (${P_REF} == 1'b1) then"
puts $fh "    trigger;"
puts $fh "  else"
puts $fh "    goto st_watch;"
puts $fh "  endif"
close $fh
puts "### trigger state machine written: $tsm"

set_property CONTROL.TRIGGER_MODE ADVANCED_ONLY [get_hw_ilas $lif]
set_property CONTROL.TSM_FILE     $tsm          [get_hw_ilas $lif]

# ------------------------------------------------------- storage qualification
set_property CONTROL.CAPTURE_MODE BASIC [get_hw_ilas $lif]
set_property CAPTURE_COMPARE_VALUE eq1'b1 \
  [get_hw_probes $P_REQ -of_objects [get_hw_ilas $lif]]

set_property CONTROL.TRIGGER_POSITION 512 [get_hw_ilas $lif]

puts "### configuration now:"
foreach pr {CONTROL.TRIGGER_MODE CONTROL.CAPTURE_MODE CONTROL.TRIGGER_POSITION CONTROL.DATA_DEPTH} {
  puts [format "###   %-28s %s" $pr [get_property $pr [get_hw_ilas $lif]]]
}
run_hw_ila [get_hw_ilas $lif]
puts "### ARMED. It will now fire on a refusal OR on a safety violation,"
puts "### and the capture window stores only cycles where a reuse was requested."
puts "### G7 COMPLETE. Screenshot Trigger Setup / Settings / Capture Setup."
