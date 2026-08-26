# Shared settings for every stage. Sourced, never run alone.
set root  [file normalize [file dirname [info script]]/../..]
set rtl   $root/rtl/v1
set vdir  $root/vivado
set proj  kv_guard
set pdir  $vdir/$proj
set part  xczu7ev-ffvc1156-2-e
set board xilinx.com:zcu104:part0:1.1
set FREQ 200          ;# requested. The PLL grants 187.5 MHz (5.333 ns).
set bdname kv_guard_bd
set guard  kv_lifecycle_guard_0
# Scratch aperture for the guard's read master. See 02_bd.tcl for why.
set SCRATCH_BASE 0x0000000070000000
set SCRATCH_SIZE 256M
proc banner {n of msg} { puts "\n######## $n/$of  $msg ########" }
