connect -url TCP:127.0.0.1:3121
after 500
# Full PS reset to clear the wedged A53, then psu_init via FSBL, then the PMU
# isolation removal. Order matters: see docs/hil/ps_pl_isolation.md
targets -set -nocase -filter {name =~ "*PSU*"}
catch { rst -system }
after 5000
targets -set -nocase -filter {name =~ "*PSU*"}
catch { mwr -force 0xFFFF0000 0x14000000 }
targets -set -nocase -filter {name =~ "*A53*#0*"}
catch { rst -processor }
after 3000
if {[catch { dow [file normalize [file join [file dirname [info script]] .. .. boot fsbl_a53.elf]] } e]} {
  puts "  FSBL download FAILED: $e"
} else {
  con
  after 4000
  # HALT AFTER psu_init. BOOT_MODE_USER=0xE is XFSBL_SD1_LS_BOOT_MODE; with no
  # boot image FSBL falls into XFsbl_ErrorLockDown -> XFsbl_FallBack ->
  # XFsbl_UpdateMultiBoot, which writes CRL_APB_RESET_CTRL(0xFF5E0218) |= 0x10
  # (system soft reset) and then spins. That soft reset returns the LPD IOU GPIO
  # to reset values, clearing bank5[31] and dropping pl_resetn0. Letting it run
  # free undoes the PL reset release on a loop. psu_init has already done its job
  # by this point, so stop the core.
  catch { stop }
  after 6000
  puts "  FSBL running"
}
targets -set -nocase -filter {name =~ "*PSU*"}
catch { mwr -force 0xFFD80118 0x00800000 }
catch { mwr -force 0xFFD80120 0x00800000 }
after 1000
# ---------------------------------------------------- PL RESET RELEASE
# pl_resetn0 is driven through EMIO GPIO bank 5 bit 31 (0x80000000), NOT by a
# CRL_APB reset register. psu_ps_pl_reset_config_data() in the XSA does exactly
# these four writes. psu_init() never calls it, so without this pl_resetn0 stays
# low, proc_sys_reset never deasserts peripheral_aresetn, and every AXI
# transaction to the guard times out with no response at all.
proc mask_write {addr mask val} {
  if {[catch {mrd -force $addr} r]} { return }
  set cur [expr 0x[lindex [split [string trim $r]] end]]
  set new [expr {($cur & ~$mask) | ($val & $mask)}]
  catch { mwr -force $addr $new }
}
mask_write 0xFF0A002C 0xFFFF0000 0x80000000
catch { mwr -force 0xFF0A0344 0x80000000 }
catch { mwr -force 0xFF0A0348 0x80000000 }
catch { mwr -force 0xFF0A0054 0x80000000 }
after 500
catch {mrd -force 0xFF0A0054} g; puts "  GPIO_DATA_5 (pl_resetn0 in bit31): $g"

catch {mrd -force 0xFFCA3010} p; puts "  PCAP_STATUS after isolation removal: $p"
catch {mrd -force 0xFFD80110} q; puts "  REQ_PWRUP_STATUS: $q"
exit
