# LENS 2 out-of-context synth (+ optional implementation) driver.
# Env: TOPMOD PERIOD RUNTAG RTLDIR OUTDIR DOIMPL [GENERICS]
set part   xczu7ev-ffvc1156-2-e
set top    $::env(TOPMOD)
set period $::env(PERIOD)
set tag    $::env(RUNTAG)
set rtld   $::env(RTLDIR)
set outd   $::env(OUTDIR)
set doimpl $::env(DOIMPL)
set gener  ""
if {[info exists ::env(GENERICS)]} { set gener $::env(GENERICS) }

file mkdir $outd

foreach f [glob -nocomplain $rtld/*.sv] { read_verilog -sv $f }

set xdc $outd/${tag}.xdc
set fh [open $xdc w]
puts $fh "create_clock -period $period -name clk \[get_ports clk\]"
close $fh
read_xdc $xdc

set cmd "synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy rebuilt"
if {$gener ne ""} { append cmd " -generic $gener" }
eval $cmd

write_checkpoint -force $outd/${tag}_synth.dcp
report_utilization -hierarchical -file $outd/${tag}_synth_util.rpt
report_timing_summary -delay_type max -max_paths 5 -file $outd/${tag}_synth_timing.rpt

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set fmax [expr {1000.0 / ($period - $wns)}]

# scrape primitive counts straight from the netlist, not from report text
proc nprim {pat} { return [llength [get_cells -hier -filter "REF_NAME =~ $pat"]] }
set n_lut  [nprim "LUT*"]
set n_ff   [llength [get_cells -hier -filter {PRIMITIVE_SUBGROUP == SDR || PRIMITIVE_SUBGROUP == flop}]]
set n_b36  [nprim "RAMB36*"]
set n_b18  [nprim "RAMB18*"]
set n_uram [nprim "URAM288*"]
set n_dsp  [nprim "DSP*"]
set n_carry [nprim "CARRY8*"]

set sh [open $outd/${tag}_synth.csv w]
puts $sh "stage,top,period_ns,wns_ns,fmax_mhz,lut,ff,ramb36,ramb18,uram288,dsp,carry8"
puts $sh "synth,$top,$period,$wns,[format %.2f $fmax],$n_lut,$n_ff,$n_b36,$n_b18,$n_uram,$n_dsp,$n_carry"
close $sh
puts "LENS2_SYNTH,$tag,$top,$period,$wns,[format %.2f $fmax],$n_lut,$n_ff,$n_b36,$n_b18,$n_uram,$n_dsp,$n_carry"

if {$doimpl == "1"} {
  opt_design
  place_design
  phys_opt_design
  route_design
  write_checkpoint -force $outd/${tag}_route.dcp
  report_utilization -file $outd/${tag}_route_util.rpt
  report_timing_summary -delay_type max -max_paths 10 -file $outd/${tag}_route_timing.rpt
  set rwns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
  set rfmax [expr {1000.0 / ($period - $rwns)}]
  set n_lut  [nprim "LUT*"]
  set n_ff   [llength [get_cells -hier -filter {PRIMITIVE_SUBGROUP == SDR || PRIMITIVE_SUBGROUP == flop}]]
  set n_b36  [nprim "RAMB36*"]
  set n_b18  [nprim "RAMB18*"]
  set n_uram [nprim "URAM288*"]
  set rh [open $outd/${tag}_route.csv w]
  puts $rh "stage,top,period_ns,wns_ns,fmax_mhz,lut,ff,ramb36,ramb18,uram288"
  puts $rh "route,$top,$period,$rwns,[format %.2f $rfmax],$n_lut,$n_ff,$n_b36,$n_b18,$n_uram"
  close $rh
  puts "LENS2_ROUTE,$tag,$top,$period,$rwns,[format %.2f $rfmax],$n_lut,$n_ff,$n_b36,$n_b18,$n_uram"
}
