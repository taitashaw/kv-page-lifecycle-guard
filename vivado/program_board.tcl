set root [file normalize [file dirname [info script]]/..]
open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
set dev [current_hw_device]
# UG908: JTAG must be 2.5x slower than the debug hub clock
set_property PARAM.FREQUENCY 15000000 [current_hw_target]
set_property PROGRAM.FILE [lindex [glob $root/vivado/lifecycle_guard/*.runs/impl_1/*.bit] 0] $dev
set_property PROBES.FILE [lindex [glob $root/vivado/lifecycle_guard/*.runs/impl_1/*.ltx] 0] $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "PROGRAMMED. ILAs: [get_hw_ilas -of_objects $dev]"
