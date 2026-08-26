# open_sim_gui.tcl
# Opens the elaborated simulation in the Vivado XSim GUI with the wave config
# restored, runs the full sequence, and zoom-fits.
#
#   cd rtl/v1 && /tools/Xilinx/2025.2/Vivado/bin/xsim tb_snap -gui -view wave.wcfg
#
# Everything below runs automatically once the GUI is up.
run all
