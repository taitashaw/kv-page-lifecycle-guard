set d [file dirname [info script]]
foreach st {02_bd 03_synth 04_impl} { source $d/$st.tcl }
