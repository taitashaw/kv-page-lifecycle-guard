# ooc_200mhz.xdc
# Out-of-context timing constraints for lifecycle_guard_top.
# 200 MHz target => 5.000 ns period.

create_clock -period 5.000 -name clk [get_ports clk]

# 20 percent of the period budgeted to the outside world on every boundary
# port, so the timing summary has no unconstrained endpoints and the reported
# WNS is a real number rather than an artefact of missing I/O constraints.
set_input_delay  -clock clk 1.000 [get_ports {rst_n s_axi_* m_axi_arready m_axi_rid[*] m_axi_rdata[*] m_axi_rresp[*] m_axi_rlast m_axi_rvalid} -filter {DIRECTION == IN}]
set_output_delay -clock clk 1.000 [all_outputs]
