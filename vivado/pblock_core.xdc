# Floorplan constraint for the guard core.
#
# WHY: worst path is u_req_fifo/rptr_reg -> u_lut/ram_reg[..]/CE, 4.932 ns, of
# which only 1.147 ns is logic and 3.785 ns (76.7%) is ROUTE. The placer spread
# the FIFO and the LUT across the die. Constraining the core to adjacent clock
# regions attacks the dominant term.
#
# Sized at TWO clock regions (~19k LUTs) for a core measured at 4,980 LUTs
# out-of-context. Deliberately loose: a tight pblock trades route delay for
# congestion and can come out worse.
#
# NO Tcl `if` guard here. Vivado's XDC parser runs in a restricted context and
# silently skipped a previous guarded version, producing a build that looked
# constrained and was not. Bare commands fail loudly on a bad path, which is
# what we want.
create_pblock pblk_core
add_cells_to_pblock [get_pblocks pblk_core] \
  [get_cells kv_guard_bd_i/kv_lifecycle_guard_0/inst/u_core]
resize_pblock [get_pblocks pblk_core] -add {CLOCKREGION_X1Y1:X1Y2}
