# synth_ooc.tcl
# Out-of-context synthesis of lifecycle_guard_top for the ZCU104 part.
#   /tools/Xilinx/2025.2/Vivado/bin/vivado -mode batch -source synth_ooc.tcl

set part  xczu7ev-ffvc1156-2-e
set board xilinx.com:zcu104:part0:1.1
set outdir [file normalize [file dirname [info script]]/synth_ooc]
file mkdir $outdir

create_project -in_memory -part $part
set_property board_part $board [current_project]

read_verilog -sv [list \
  lifecycle_pkg.sv \
  page_state_lut.sv \
  tag_tracker.sv \
  axi_lite_regs.sv \
  axi_read_manager.sv \
  lifecycle_guard_top.sv \
]
read_xdc ooc_200mhz.xdc

synth_design -mode out_of_context -top lifecycle_guard_top -part $part

report_utilization        -file $outdir/utilization.rpt
report_utilization -hierarchical -file $outdir/utilization_hier.rpt
report_timing_summary     -file $outdir/timing_summary.rpt
report_timing -delay_type max -max_paths 10 -nworst 10 -sort_by group \
              -input_pins -file $outdir/timing_worst.rpt
report_timing -from [all_registers] -to [all_registers] -delay_type max \
              -max_paths 5 -input_pins -file $outdir/timing_reg2reg.rpt
report_clock_interaction  -file $outdir/clock_interaction.rpt
write_checkpoint -force $outdir/lifecycle_guard_top_synth.dcp

# ---- machine-readable summary, so no number in the report is retyped by hand
set wns  [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs  [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
set fmax [expr {1000.0 / (5.000 - $wns)}]

set fh [open $outdir/summary.txt w]
puts $fh "PART            $part"
puts $fh "BOARD           $board"
puts $fh "CLK_PERIOD_NS   5.000"
puts $fh "CLK_TARGET_MHZ  200.0"
# get_utilization returns "NAME:USED:AVAILABLE ..." as a flat string
foreach item [split [get_utilization -quiet]] {
  set p [split $item ":"]
  if {[llength $p] >= 2} {
    puts $fh "[format {%-15s} [lindex $p 0]] [lindex $p 1]"
  }
}
puts $fh "WNS_NS          $wns"
puts $fh "WHS_NS          $whs"
puts $fh "FMAX_EST_MHZ    [format {%.1f} $fmax]"
close $fh

puts "OOC SYNTH DONE. WNS = $wns  WHS = $whs  FMAX_EST = $fmax MHz"
