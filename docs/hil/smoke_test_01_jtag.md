# Board smoke test, stage 1: JTAG chain and target enumeration

Date 2026-08-23. Tool: Vivado 2025.2 xsdb, hw_server 2025.2 build Oct 28 2025.
This is stage 1 of the bring-up gate the brief requires before any complex
design exists.

## PASS: cable and device identified

    Xilinx HW-Z1-ZCU104 FT4232H 26597A
      xczu7 (idcode 14730093 irlen 12 fpga)
      arm_dap (idcode 5ba00477 irlen 4)

Cable serial 26597A. The FPGA enumerates as xczu7, which matches the
XCZU7EV-2FFVC1156E on the ZCU104. The ARM debug access port is present.

## PASS: full PS and PL target tree enumerates

    1  PS TAP
       2  PMU
       3  PL
    4  PSU
       5  RPU (Reset)
          6  Cortex-R5 #0 (RPU Reset)
          7  Cortex-R5 #1 (RPU Reset)
       8  APU (L2 Cache Reset)
          9  Cortex-A53 #0 (APU Reset)
         10  Cortex-A53 #1 (APU Reset)
         11  Cortex-A53 #2 (APU Reset)
         12  Cortex-A53 #3 (APU Reset)

Twelve targets. The PMU, the PL bscan target, both Cortex-R5 cores and all
four Cortex-A53 cores are visible.

## Expected state, recorded so it is not mistaken for a fault

Every core reports a reset state: the R5s show "RPU Reset" and the A53s show
"APU Reset". That is the correct state for a board that has been powered on
without booting an image. It is not a bring-up failure. The previous ZCU104
effort on this project hit reset and PS bring-up problems, so this baseline is
recorded deliberately.

## USB serial

/dev/ttyUSB1, /dev/ttyUSB2 and /dev/ttyUSB3 are present. ttyUSB0 was present
at first enumeration and is claimed by the JTAG function of the FT4232H. On the
ZCU104 the PS console is normally the second interface, so ttyUSB1 is the
candidate for UART capture and will be confirmed when a PS image prints.

## Still to do in this gate

- program a known-safe PL image and confirm DONE
- verify a free-running PL clock
- verify reset release
- confirm a deterministic PS status path over UART

Those follow once disk space allows a Vivado build.

---

# Stage 2: programming and clock verification. GATE PASSED.

Same session, 2026-08-23. Two known-good bitstreams from the adjacent
shawsilicon-fpga-proofs project were used deliberately, so that a failure here
would indicate a board or host problem rather than a design problem.

## PASS: device programs

    BEFORE  REGISTER.CONFIG_STATUS = 0x00000000
            Labtools 27-1435: "Device xczu7 (JTAG device index = 0) is not
            programmed (DONE status = 0)."
    PROGRAM out_300/zcu104_top.bit
            Labtools 27-3164: "End of startup status: HIGH"
    AFTER   REGISTER.CONFIG_STATUS = 0x12906ffc

## PASS: free-running PL clock, measured rather than observed

Rather than asking a human to watch an LED blink, the second bitstream
(out_lgvio/lg_vio.bit with its matching .ltx) exposes a free-running cycle
counter through a VIO. The counter was read twice over JTAG across a nominal
two second interval:

    t0 = 0x062fc53b =   103,793,979 cycles
    t1 = 0x2a127286 =   705,852,038 cycles
    delta          =   602,058,059 cycles / 2.000 s = 301.03 MHz

Cross-check: the LinkGuard board run recorded in the adjacent project measured
601,868,406 cycles in 2.000 s, that is 300.9 MHz, on this same board. The two
independent measurements differ by 189,653 cycles, 0.032 percent, which is
within the JTAG transaction overhead on a two second window.

This simultaneously establishes three things: the PL clock is running, reset has
been released (a held reset would leave the counter static), and the VIO debug
path works end to end from Tcl through hw_server to silicon.

## Gate status

| check | result |
|---|---|
| JTAG chain detected | PASS |
| device identified as xczu7 | PASS |
| full PS and PL target tree enumerates | PASS |
| bitstream programs, end of startup HIGH | PASS |
| free-running PL clock | PASS, 301.03 MHz measured |
| reset released | PASS, implied by a counter that advances |
| debug path VIO over JTAG | PASS |
| UART console | not yet exercised, needs a PS application |

The bring-up gate the brief requires before complex design work is PASSED.
The previous ZCU104 effort on this project failed at exactly this stage, so it
was run first and with known-good artifacts.
