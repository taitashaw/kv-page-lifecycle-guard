source [file dirname [info script]]/00_common.tcl
puts "\n######## G8  EXPORT FIGURES FROM THE BUILD ########"
#
# Screenshots are not reproducible: they are a photo of one moment in one GUI
# session, and nothing in the repo regenerates them. Vivado can export the same
# three views straight from the design database, so they stay in step with the
# build and stay readable at any zoom.
#
#   write_bd_layout  - the block design canvas, identical to what the GUI draws
#   write_schematic  - the netlist schematic, from synth_1 and from impl_1
#
# MEASURED: both commands need Vivado's rendering engine, which -mode batch does
# not load. Batch emits "[BD 5-349] Please run the tool in GUI mode" and writes
# nothing. So this runs under -mode gui on a virtual display. See run_g8.sh.
#
# PDF is the native output. It is rasterised to PNG afterwards because GitHub
# renders PNG inline in a README and will not render a PDF.
#
set out $root/docs/images
file mkdir $out

# -mode gui sends puts to the Tcl console, not stdout, so every diagnostic goes
# to a file. Without this the failures below are invisible.
set ::LOGF [open $vdir/g8_report.txt w]
proc say {m} { puts $m ; puts $::LOGF $m ; flush $::LOGF }

proc sized {f} {
  if {[file exists $f]} {
    say [format "### OK    %-24s %8d bytes" [file tail $f] [file size $f]] ; return 1
  }
  say "### FAIL  [file tail $f] was not written" ; return 0
}

if {[current_project -quiet] eq ""} { open_project $pdir/$proj.xpr }

# ------------------------------------------------------------- block design
set bdf [get_files -quiet $bdname.bd]
if {$bdf eq ""} { error "block design $bdname.bd not found in the project" }
open_bd_design $bdf
foreach ext {pdf svg} {
  catch { file delete $out/block-design.$ext }
  catch { write_bd_layout -force -format $ext -orientation landscape \
            $out/block-design.$ext } e
  sized $out/block-design.$ext
}
close_bd_design [current_bd_design]

# ------------------------------------------------------------- schematics
# Two runs, deliberately. The top-level cell count differs between them because
# opt_design absorbs constant drivers, and that difference is itself the point.
foreach {run tag} {synth_1 schematic-synth impl_1 schematic-impl} {
  if {[catch { get_property STATUS [get_runs $run] } st]} {
    say "### skip $run: $st" ; continue
  }
  say "### opening $run ($st) ..."
  if {[catch { open_run $run -name $run } e]} { say "###   open_run FAILED: $e" ; continue }
  catch { file delete $out/$tag.pdf }

  # SCOPE MATTERS. The wrapper level holds only 2 cells (the BD instance and
  # dbg_hub) and renders a near-empty diagram. The view worth publishing is the
  # INTERIOR of the BD instance, which is what the GUI shows after descending
  # into kv_guard_bd_i and what the figure captions describe.
  set inner [get_cells -quiet ${bdname}_i/*]
  if {[llength $inner] == 0} { set inner [get_cells -quiet */*] }
  say "###   wrapper: [llength [get_cells -quiet]] cells"
  say "###   interior of ${bdname}_i: [llength $inner] cells"

  # write_schematic renders whatever the schematic VIEWER holds, so the view has
  # to be created and populated first. Calling it on a bare open_run writes
  # nothing and reports success.
  if {[catch { show_schematic $inner } e]} { say "###   show_schematic: $e" }
  foreach attempt {a b} {
    if {$attempt eq "a"} {
      set rc [catch { write_schematic -force -format pdf -orientation landscape \
                        -cells $inner $out/$tag.pdf } e]
    } else {
      set rc [catch { write_schematic -force -format pdf $out/$tag.pdf } e]
    }
    say "###   attempt $attempt: rc=$rc [expr {$rc ? $e : {}}]"
    if {[file exists $out/$tag.pdf]} { break }
  }
  sized $out/$tag.pdf
  close_design
}

say "### G8 COMPLETE."
close $::LOGF
exit 0
