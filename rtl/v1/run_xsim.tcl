# run_xsim.tcl  -- batch elaboration and run. Produces the waveform database
# that the GUI gate opens.
exec /tools/Xilinx/2025.2/Vivado/bin/xvlog -sv lifecycle_pkg.sv page_state_lut.sv tag_tracker.sv tb_page_state_lut.sv
exec /tools/Xilinx/2025.2/Vivado/bin/xelab -debug typical -top tb_page_state_lut -snapshot tb_snap
exec /tools/Xilinx/2025.2/Vivado/bin/xsim tb_snap -runall
