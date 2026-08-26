# Debug hub clocking.
#
# MUST be a constraint, not a set_property on an in-memory netlist from
# open_run: implementation re-reads the checkpoint and discards those.
#
# C_ENABLE_CLK_DIVIDER is deliberately FALSE. MEASURED 25 Aug 2026: with it
# TRUE the hub appeared on the JTAG chain (xsct showed "Legacy Debug Hub") but
# Vivado enumerated ZERO debug cores, even though get_debug_cores on the
# implemented design returned both dbg_hub and ila_lifecycle. The divider is
# only for when the hub clock is TOO SLOW relative to JTAG, which is what
# throws Labtools 27-3123. Here the hub runs at 187.5 MHz against a ~15 MHz
# JTAG clock, a 12.5x ratio, so the divider is unnecessary and it stops the
# hub answering. Telling the hub its true input frequency is the part that
# matters.
set_property C_CLK_INPUT_FREQ_HZ 187500000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false    [get_debug_cores dbg_hub]
