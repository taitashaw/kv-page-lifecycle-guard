source [file dirname [info script]]/00_common.tcl
puts "\n######## G3  HIL VERIFY: does the interlock actually refuse on silicon? ########"
#
# TRIGGER CHOICE MATTERS.
#
# Arming on probe[66] = reuse_grant is a TRAP: if the design is correct it never
# fires, and "never fired" is indistinguishable from a broken ILA. It proves
# nothing on its own.
#
# So the PRIMARY trigger is probe[67] = reuse_refused, the event that SHOULD
# happen when a reuse is attempted against a page that is still draining. When
# it fires we read bits 25:0 in that same sample to show WHY it refused:
#
#   [7:0] refcount   [15:8] reservation   [21:16] inflight   [25:22] fill_pending
#
# A refusal with all four zero would mean the guard is refusing spuriously.
# A grant with any of them nonzero would falsify the safety claim outright.
#
set XSCT /tools/Xilinx/2025.2/Vitis/bin/xsct

puts "### 1. PS clocks + PS-PL isolation removal"
catch { exec $XSCT $root/vivado/hil/hil_bringup.tcl } out
foreach l [split $out \n] { if {[string match "*FSBL*" $l] || [string match "*PCAP*" $l]} { puts "    $l" } }

# Fail fast and loudly if the bitstream is missing. A bare glob throws an
# opaque Tcl error that reads like a board problem when it is actually a build
# that never finished (or was killed).
set bitf [glob -nocomplain $pdir/*.runs/impl_1/${bdname}_wrapper.bit]
if {[llength $bitf] == 0} {
  error "NO BITSTREAM at $pdir/*.runs/impl_1/${bdname}_wrapper.bit .\nThe build has not completed. Run stages 02-05 first and let them FINISH."
}
puts "### 2. program"
open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices *zu7*] 0]
current_hw_device $dev
set_property PROGRAM.FILE     [lindex $bitf 0] $dev
set_property PROBES.FILE      [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.ltx] 0] $dev
set_property FULL_PROBES.FILE [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.ltx] 0] $dev
program_hw_devices $dev
refresh_hw_device -update_hw_probes true $dev

set ila [lindex [get_hw_ilas -quiet] 0]
set axi [lindex [get_hw_axis -quiet] 0]
if {$ila eq ""} { error "NO ILA" }
if {$axi eq ""} { error "NO JTAG-AXI MASTER" }
set p [lindex [get_hw_probes -quiet -of_objects [get_hw_ilas $ila]] 0]
puts "### ILA=$ila  AXI=$axi  probe=$p"
# UG908 requires resetting the JTAG-AXI core before issuing transactions. It
# also clears a STATUS.AXI_*_BUSY that a previous timeout leaves latched.
catch { reset_hw_axi [get_hw_axis $axi] }
foreach pr {STATUS.AXI_WRITE_BUSY STATUS.AXI_READ_BUSY} {
  catch { puts "###   $pr = [get_property $pr [get_hw_axis $axi]]" }
}

# ---------------------------------------------------------------- AXI helpers
proc axiw {axi name addr data} {
  catch { delete_hw_axi_txn [get_hw_axi_txns -quiet $name] }
  create_hw_axi_txn $name [get_hw_axis $axi] -type write -address $addr -data $data
  if {[catch { run_hw_axi [get_hw_axi_txns $name] } e]} { puts "###   W $addr FAILED"; return 0 }
  return 1
}
proc axir {axi name addr} {
  catch { delete_hw_axi_txn [get_hw_axi_txns -quiet $name] }
  create_hw_axi_txn $name [get_hw_axis $axi] -type read -address $addr
  if {[catch { run_hw_axi [get_hw_axi_txns $name] } e]} { return "FAILED" }
  return [get_property DATA [get_hw_axi_txns $name]]
}

# ------------------------------------------------- sanity: is the bus alive at all?
set id [axir $axi rd_id A0000000]
puts "### 3. control path check, ID register = $id"
if {$id eq "FAILED"} {
  error "AXI is dead. If this says TIMED OUT, the PL is still in reset (check dcm_locked)."
}

# ------------------------------------------------------------- arm on REFUSAL
puts "### 4. arming on probe\[67\] = reuse_refused (the event that SHOULD fire)"
# STORAGE QUALIFICATION. At 187.5 MHz, 2048 samples in ALWAYS mode is a 10.9 us
# window, but JTAG-AXI writes land MILLISECONDS apart. Capturing every cycle
# would fill the buffer with idle. BASIC capture mode records only cycles where
# the qualifier holds, so the buffer fills with events instead of dead time.
catch { set_property CONTROL.CAPTURE_MODE BASIC [get_hw_ilas $ila] }
catch { set_property CONTROL.DATA_DEPTH 2048    [get_hw_ilas $ila] }
set_property CONTROL.TRIGGER_POSITION 512 [get_hw_ilas $ila]
set patt "[string repeat x 128]1[string repeat x 67]"
set armed 0
if {[catch { set_property TRIGGER_COMPARE_VALUE eq196'b$patt \
             [get_hw_probes $p -of_objects [get_hw_ilas $ila]] } e]} {
  puts "###   trigger rejected: $e"
} else { set armed 1 ; puts "###   armed on reuse_refused" }
# Qualifier: record a cycle if ANY of reuse_req(65) / grant(66) / refused(67) /
# arvalid(58) / rvalid(60) is high. Expressed as a don't-care compare per bit
# would need ADVANCED mode; BASIC takes one pattern, so qualify on reuse_req,
# which brackets every interlock decision.
catch {
  set_property CAPTURE_COMPARE_VALUE eq196'b[string repeat x 130]1[string repeat x 65] \
    [get_hw_probes $p -of_objects [get_hw_ilas $ila]]
}
run_hw_ila [get_hw_ilas $ila]

# ------------------------------------------------------------------ stimulus
puts "### 5. stimulus: ACQUIRE -> read -> RELEASE -> attempt reuse while draining"
# Encodings taken from the PASSING testbench, not guessed:
#   mk_desc     = {tenant, tag, gen, 2'd0, phys, 2'd0, slot}
#   mk_read_cfg = {16'd0, len, 2'd0, sigchk, 1'b1, 1'b0, 3'd0}   <- bit4 IS the enable
#   R_REUSE_CFG = {12'd0, 4'd1, 2'd0, phys, 2'd0, slot}
#   lc_op       = CMD_DESC=mk_desc(slot,9,0,0,1); CMD_CFG={29'd0,ev}; CMD_GO=1
# slot=5 phys=9 tenant=1 -> desc 0x10000905 (tag 0) / 0x11000905 (tag 1)
# lc_event_e: ACQUIRE=0 ADMIT=1 ISSUE=2 COMPLETE=3 RELEASE=4 CANCEL=5
axiw $axi w_ctrl A0000008 00000011
axiw $axi w_blo  A0000014 70000000
axiw $axi w_bhi  A0000018 00000000
axiw $axi w_llo  A000001C 70010000
axiw $axi w_lhi  A0000020 00000000

# 1. ACQUIRE slot 5  (refcount -> 1)
axiw $axi a_desc A0000030 10000905
axiw $axi a_cfg  A0000034 00000000
axiw $axi a_go   A0000044 00000001

# 2. issue a read on that page (inflight -> 1). cfg 0x30 = enable + sigchk
axiw $axi r_desc A0000030 11000905
axiw $axi r_alo  A0000038 70000100
axiw $axi r_ahi  A000003C 00000000
axiw $axi r_sig  A0000040 CAFEBABE
axiw $axi r_cfg  A0000034 00000030
axiw $axi r_go   A0000044 00000001

# 3. RELEASE slot 5 (refcount -> 0 while inflight > 0). THIS IS "DRAINING".
axiw $axi l_desc A0000030 10000905
axiw $axi l_cfg  A0000034 00000004
axiw $axi l_go   A0000044 00000001

# 4. attempt reuse of that frame. A refcount-only check would allow it.
axiw $axi u_cfg  A0000050 00010905
axiw $axi u_go   A0000054 00000001

puts "### 6. counters read back over JTAG-AXI"
set res {}
foreach {nm off} {reuse_refused A0000060 stale A0000064 unsafe A0000068
                  payload_mm A000006C complete A0000074 win_refused A0000078
                  dispatch A0000088 accept A000008C} {
  set v [axir $axi rd_$nm $off]
  dict set res $nm $v
  puts [format "###   %-14s %s" $nm $v]
}

# --------------------------------------------------------------------- verdict
puts "### 7. capture"
set fired 1
if {[catch { wait_on_hw_ila -timeout 25 [get_hw_ilas $ila] } e]} {
  set fired 0
  puts "###   reuse_refused did NOT fire in 25 s."
  run_hw_ila -trigger_now [get_hw_ilas $ila]
  catch { wait_on_hw_ila -timeout 10 [get_hw_ilas $ila] }
}
set d [upload_hw_ila_data [get_hw_ilas $ila]]
display_hw_ila_data $d
write_hw_ila_data -force $vdir/hil_capture.ila $d

puts "\n### ================ VERDICT ================"
set rr [dict get $res reuse_refused]
if {$armed && $fired} {
  puts "### TRIGGERED on reuse_refused. The interlock refused a reuse on silicon."
  puts "### Inspect bits 25:0 at the trigger sample: at least one of refcount /"
  puts "### reservation / inflight / fill_pending must be nonzero, or the guard"
  puts "### is refusing spuriously."
} elseif {$rr ne "FAILED" && $rr ne "00000000"} {
  puts "### Trigger did not fire, BUT the refuse counter reads $rr, so refusals"
  puts "### did occur. Timing of the arm vs the stimulus is the issue, not the guard."
} else {
  puts "### No refusal observed. Either the stimulus did not create a draining"
  puts "### page, or the interlock is not engaging. NOT a pass."
}
puts "### capture saved: $vdir/hil_capture.ila"
puts "### HIL VERIFY COMPLETE"
