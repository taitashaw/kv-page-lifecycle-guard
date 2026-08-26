set d [file dirname [info script]]
foreach st {01_sim 02_bd 03_synth 04_impl 05_bitstream} { source $d/$st.tcl }
puts "\n######## FLOW COMPLETE THROUGH BITSTREAM ########"
