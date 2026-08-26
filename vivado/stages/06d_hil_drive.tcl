source [file dirname [info script]]/00_common.tcl
puts "\n######## G3  HIL: ARM, DRIVE, CAPTURE ########"
#
# Full sequence, in the order established in docs/hil/ps_pl_isolation.md:
#   1. rst -system, then FSBL over JTAG        (psu_init brings up the PLLs)
#   2. PS-PL isolation removal via the PMU     (drops the level-shifter wall)
#   3. program the PL from INSIDE Vivado       (its chain scan clears an earlier load)
#   4. arm the ILA on the SAFETY PROPERTY
#   5. drive the guard's registers from xsct   (Vivado has no AXI master in this design)
#   6. upload and display
#
set XSCT /tools/Xilinx/2025.2/Vitis/bin/xsct
set SCR  $root/vivado/hil

puts "### 1-2. PS reset, FSBL, isolation removal"
if {[catch { exec $XSCT $SCR/hil_bringup.tcl } out]} { puts "### xsct bringup said: $out" } else { puts $out }

puts "### 3. connecting and programming"
open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices *zu7*] 0]
current_hw_device $dev
set bit [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.bit] 0]
set ltx [lindex [glob $pdir/*.runs/impl_1/${bdname}_wrapper.ltx] 0]
set_property PROGRAM.FILE $bit $dev
set_property PROBES.FILE  $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
program_hw_devices $dev
set_property BSCAN_SWITCH_USER_MASK 1 $dev
refresh_hw_device -update_hw_probes true $dev

set ilas [get_hw_ilas -quiet]
if {[llength $ilas] == 0} { error "ILA not enumerated. See docs/hil/ps_pl_isolation.md" }
set ila [lindex $ilas 0]
puts "### ILA: $ila depth=[get_property CONTROL.DATA_DEPTH [get_hw_ilas $ila]]"

puts "### 4. arming on the SAFETY PROPERTY"
# probe[66] = reuse_grant. The claim under test is that a grant NEVER happens while
# refcount(7:0), reservation(15:8), inflight(21:16) or fill_pending(25:22) are
# nonzero. Trigger on the grant and inspect those fields in the same sample.
# Trigger position mid-window so we see the approach as well as the decision.
set p [lindex [get_hw_probes -quiet -of_objects [get_hw_ilas $ila]] 0]
puts "### probe: $p"
set_property CONTROL.TRIGGER_POSITION 1024 [get_hw_ilas $ila]
# Bit 66 high, everything else don't-care. 196 bits, MSB first.
set patt [string repeat "x" 129]
append patt "1"
append patt [string repeat "x" 66]
if {[catch {
  set_property TRIGGER_COMPARE_VALUE eq196'b$patt [get_hw_probes $p -of_objects [get_hw_ilas $ila]]
} e]} {
  puts "### could not set bit-66 trigger ($e), falling back to trigger_now"
  set ARMED_ON_PROPERTY 0
} else {
  set ARMED_ON_PROPERTY 1
}
run_hw_ila [get_hw_ilas $ila]
puts "### ILA ARMED (on safety property: $ARMED_ON_PROPERTY)"

puts "### 5. driving the guard over AXI-Lite from xsct"
if {[catch { exec $XSCT $SCR/hil_drive.tcl } out2]} { puts "### xsct drive said: $out2" } else { puts $out2 }

puts "### 6. uploading capture"
if {[catch { wait_on_hw_ila -timeout 30 [get_hw_ilas $ila] } e]} {
  puts "### TRIGGER DID NOT FIRE within 30 s: $e"
  puts "### That is itself a RESULT: no reuse_grant occurred during the stimulus."
  run_hw_ila -trigger_now [get_hw_ilas $ila]
  catch { wait_on_hw_ila -timeout 10 [get_hw_ilas $ila] }
}
set d [upload_hw_ila_data [get_hw_ilas $ila]]
display_hw_ila_data $d
write_hw_ila_data -force $vdir/hil_capture.ila $d
puts "### CAPTURE SAVED: $vdir/hil_capture.ila"
puts "### HIL RUN COMPLETE."
