set d [file dirname [info script]]
foreach st {03_synth 04_impl 05_bitstream} { source $d/$st.tcl }
puts "\n######## PBLOCK BUILD COMPLETE ########"
