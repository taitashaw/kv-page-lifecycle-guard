source [file dirname [info script]]/00_common.tcl
puts "\n######## G5  BITSTREAM ########"
if {[current_project -quiet] eq ""} { open_project $pdir/$proj.xpr }

# Refuse to present a bitstream from a run that did not close timing.
set wns [get_property STATS.WNS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]
if {$wns < 0 || $tns < 0} {
  error "REFUSING: timing not closed. WNS $wns TNS $tns"
}
puts "### timing gate passed: WNS $wns  TNS $tns"

set bit [glob -nocomplain $pdir/*.runs/impl_1/${bdname}_wrapper.bit]
set ltx [glob -nocomplain $pdir/*.runs/impl_1/${bdname}_wrapper.ltx]
if {[llength $bit] == 0} { error "NO BITSTREAM" }
if {[llength $ltx] == 0} { error "NO .ltx PROBE FILE. Hardware Manager could not name any probe." }

puts "### artifacts:"
foreach f [list [lindex $bit 0] [lindex $ltx 0]] {
  puts [format "###   %-46s %d bytes" [file tail $f] [file size $f]]
}

# The .ltx is what carries the probe NAMES to Hardware Manager. Prove the named
# fields are in it, since a single wide bus was the earlier failure mode.
set fh [open [lindex $ltx 0]]; set j [read $fh]; close $fh
set named 0
foreach f {dbg_rstn dbg_heartbeat dbg_refcount dbg_reservation dbg_inflight \
           dbg_reuse_grant dbg_reuse_refused dbg_rd_latency dbg_sticky} {
  if {[string match "*$f*" $j]} { incr named }
}
puts "### probe names carried in the .ltx: $named of 9 key fields"
puts "### system ILA present in .ltx: [expr {[string match "*sila_axi*" $j] ? "yes" : "no"}]"

write_hw_platform -fixed -include_bit -force $vdir/$proj.xsa
puts "### XSA exported: vivado/$proj.xsa"
puts "### BITSTREAM VERIFIED. Screenshot the Project Summary (gate G5)."
