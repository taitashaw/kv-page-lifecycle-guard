source [file dirname [info script]]/00_common.tcl
puts "\n######## G1  SIMULATION WAVEFORMS ########"
if {[current_project -quiet] eq ""} { open_project $pdir/$proj.xpr }

# Keep the block design available on its own tab alongside the simulation.
catch { open_bd_design [get_files $bdname.bd] }

# The gate must be the TB that instantiates lifecycle_guard_top and drives the
# real AXI boundary, not a submodule TB.
set_property top tb_lifecycle_guard_top [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation

# launch_simulation already adds the TB top-level signals. Add the DUT boundary
# on top of that. No -group: XSim's add_wave has no such option, and grouping is
# cosmetic. Each add is guarded so one bad selector cannot abort the run.
# The SAME fields the ILA probes on hardware, so the simulation waveform and
# the Hardware Manager view line up field for field.
foreach sel {
  /tb_lifecycle_guard_top/dut/dbg_rstn
  /tb_lifecycle_guard_top/dut/dbg_heartbeat
  /tb_lifecycle_guard_top/dut/dbg_refcount
  /tb_lifecycle_guard_top/dut/dbg_reservation
  /tb_lifecycle_guard_top/dut/dbg_inflight
  /tb_lifecycle_guard_top/dut/dbg_fill_pending
  /tb_lifecycle_guard_top/dut/dbg_generation
  /tb_lifecycle_guard_top/dut/dbg_exp_generation
  /tb_lifecycle_guard_top/dut/dbg_reuse_req
  /tb_lifecycle_guard_top/dut/dbg_reuse_grant
  /tb_lifecycle_guard_top/dut/dbg_reuse_refused
  /tb_lifecycle_guard_top/dut/dbg_stale
  /tb_lifecycle_guard_top/dut/dbg_payload_mm
  /tb_lifecycle_guard_top/dut/dbg_evictable
  /tb_lifecycle_guard_top/dut/dbg_outstanding
  /tb_lifecycle_guard_top/dut/dbg_ar_wait
  /tb_lifecycle_guard_top/dut/dbg_rd_latency
  /tb_lifecycle_guard_top/dut/dbg_rd_latency_max
  /tb_lifecycle_guard_top/dut/dbg_sticky
  /tb_lifecycle_guard_top/dut/s_axi_*
  /tb_lifecycle_guard_top/dut/m_axi_*
} {
  set objs [get_objects -quiet $sel]
  if {[llength $objs]} {
    if {[catch { add_wave $objs } e]} { puts "### add_wave $sel skipped: $e" }
  } else {
    puts "### no objects matched $sel"
  }
}

# run all, NOT the default 1000 ns, or the scoreboard never reaches 25 checks.
run all
catch { wave zoom fit }
puts "### WAVEFORMS READY. tb_lifecycle_guard_top ran to completion. Gate G1."
