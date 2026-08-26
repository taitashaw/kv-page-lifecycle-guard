connect -url TCP:127.0.0.1:3121
after 300
targets -set -nocase -filter {name =~ "*A53*#0*"}
# XSCT reaches memory THROUGH the A53. While the core is running FSBL, debugger
# accesses are refused. Halt it first; FSBL has already done its job (psu_init).
catch { stop }
after 500
set B 0xA0000000
proc w {off val} { global B; catch { mwr -force [expr $B + $off] $val } }
proc r {name off} {
  global B
  if {[catch {mrd -force [expr $B + $off]} v]} { puts "    $name: READ FAIL" } \
  else { puts "    $name: [lindex [split [string trim $v]] end]" }
}
puts "  --- driving the guard ---"
if {[catch {mrd -force 0xA0000000} probe]} { puts "  first read error: $probe" }
r "ID (0x000)" 0x000
# CTRL: bit0 enable, bit4 sig_check_en. Bit 4 is the one whose absence made the
# top-level testbench fail; omitting it here would silently disable the comparator.
w 0x008 0x00000011
# confine to the scratch aperture the BD address editor already enforces
w 0x014 0x70000000
w 0x018 0x00000000
w 0x01c 0x70010000
w 0x020 0x00000000
# a read command inside the window
w 0x030 0x00001249
w 0x038 0x70000100
w 0x03c 0x00000000
w 0x040 0xCAFEBABE
w 0x034 0x00000020
w 0x044 0x00000001
after 200
# a reuse request while that transaction may still be inflight: this is the
# lifecycle interlock under test
w 0x050 0x00000009
w 0x054 0x00000001
after 200
puts "  --- counters ---"
r "reuse_refused (0x060)" 0x060
r "stale         (0x064)" 0x064
r "unsafe        (0x068)" 0x068
r "payload_mm    (0x06c)" 0x06c
r "complete      (0x074)" 0x074
r "win_refused   (0x078)" 0x078
r "dispatch      (0x088)" 0x088
r "accept        (0x08c)" 0x08c
exit
