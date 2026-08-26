source [file dirname [info script]]/00_common.tcl
puts "\n######## G2  BLOCK DESIGN ########"
# Opens the ALREADY BUILT block design for inspection. Does not rebuild, so what
# is on screen is exactly what is in the current bitstream.
if {[current_project -quiet] eq ""} { open_project $pdir/$proj.xpr }
open_bd_design [get_files $bdname.bd]
regenerate_bd_layout

puts "### cells on the canvas:"
foreach c [lsort [get_bd_cells -quiet]] {
  puts [format "###   %-24s %s" $c [get_property -quiet VLNV [get_bd_cells $c]]]
}

puts "### debug instrumentation:"
set ila [get_bd_cells -quiet ila_lifecycle]
if {[llength $ila]} {
  puts "###   ila_lifecycle probes: [get_property CONFIG.C_NUM_OF_PROBES [get_bd_cells ila_lifecycle]]"
}
set sila [get_bd_cells -quiet sila_axi]
if {[llength $sila]} {
  puts "###   sila_axi monitor slots: [get_property CONFIG.C_NUM_MONITOR_SLOTS [get_bd_cells sila_axi]]"
}

puts "### reset path (the bug that cost a day):"
foreach pin {ext_reset_in dcm_locked} {
  set n [get_bd_nets -quiet -of_objects [get_bd_pins -quiet rst_ps8_0_200M/$pin]]
  puts [format "###   rst_ps8_0_200M/%-13s <- %s" $pin [expr {$n eq "" ? "UNCONNECTED (would tie 1'b0 = ASSERTED)" : $n}]]
}

puts "### address map:"
foreach s [get_bd_addr_segs -quiet] {
  puts [format "###   %-52s %s +%s" $s \
    [get_property offset [get_bd_addr_segs $s]] [get_property range [get_bd_addr_segs $s]]]
}
puts "### BLOCK DESIGN OPEN. Screenshot the canvas (gate G2)."
