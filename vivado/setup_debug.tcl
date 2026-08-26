# setup_debug.tcl -- MUST run after synth_design and BEFORE implementation.
# The PL clock is 200 MHz here; UG908 wants the debug hub at ~100 MHz or less.
# Without the divider, ILA core discovery fails as
#   WARNING: [Labtools 27-3123] The debug hub core was not detected
# which never mentions a clock, so it would be diagnosed at the bench instead.
set root [file normalize [file dirname [info script]]/..]
open_project $root/vivado/lifecycle_guard/lifecycle_guard.xpr
open_run synth_1 -name synth_1
if {[llength [get_debug_cores -quiet dbg_hub]]} {
  set_property C_CLK_INPUT_FREQ_HZ 200000000 [get_debug_cores dbg_hub]
  set_property C_ENABLE_CLK_DIVIDER true      [get_debug_cores dbg_hub]
  puts "DEBUG HUB: divider enabled, input 200 MHz"
} else {
  puts "DEBUG HUB: not present in this run"
}
write_checkpoint -force $root/vivado/post_synth_dbg.dcp
