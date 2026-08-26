# GUI gates: where John drives Vivado directly

Standing constraint for this project. Screenshots that go into public
evidence must come out of the Vivado GUI on this machine, not from anything
I render. My job is to make every gate open cleanly with one command and to
prompt at the right moment, never to hand over a half-built project.

## Gate 1: XSim waveform, after the verification regression passes

I prepare: elaborated sim, a saved `.wcfg` with the signal groups already
ordered, radix set, and cursors placed on the transactions that matter.

You run:

    cd <project>
    vivado -source vivado/open_sim_gui.tcl

Opens the project, launches simulation, restores the wave config, runs to
the first interesting transaction and stops. Screenshot targets: the full
run zoom-fit, one complete request-to-response transaction, and one
fallback or adversarial case.

I prompt you when: all directed tests and committed random seeds pass in
batch XSim, so the GUI run is a confirmation rather than a debug session.

## Gate 2: integrated block design

I prepare: the block design built from Tcl, validated, address map assigned,
wrapper generated, layout regenerated so it is readable rather than tangled.

You run:

    vivado -source vivado/open_bd_gui.tcl

Opens the project with the block design already open. Screenshot targets:
the whole BD zoom-fit showing PS, SmartConnect, DMA, the accelerator and
the HP port, plus the address editor tab.

I prompt you when: the BD validates with no critical warnings and the
wrapper builds.

## Gate 3: ILA hardware-in-the-loop

I prepare: bitstream and matching `.ltx`, trigger setup scripted, the PS
application built and ready to run, and a documented list of which probe
proves which claim.

Three things already settled for this gate, all measured or tool-verified,
see `docs/hil/ila_budget.md`:

- **ILA sized at 8 probes x 32 bits x 8192 deep, 64 BRAM tiles (20.5%).**
  Measured on this exact part, not taken from a datasheet, because AMD
  publishes no ILA resource model for UltraScale+.
- **URAM cannot hold ILA capture on this part**, so the ILA and the design
  do not fight over it. The ILA competes only for the 312 BRAM.
- **The debug hub clock must be divided.** Our PL clock is 301.03 MHz and
  UG908 wants the hub at roughly 100 MHz or less. Without the divider,
  core discovery fails as `[Labtools 27-3123] debug hub core was not
  detected`, which never mentions a clock and would waste a bench session.
  The divider is applied at synthesis, not at the GUI, so this cannot be
  fixed on the night. Tracked as a task.

You run:

    vivado -source vivado/open_hw_gui.tcl

Opens Hardware Manager, connects to hw_server, programs the device with the
matched bit and ltx, arms the ILA with the trigger already configured. You
then start the PS application and capture. Screenshot targets: one complete
successful transaction, one fallback or misprediction event, and the
counter dump alongside the UART PASS line.

I prompt you when: the board smoke test has passed, timing has closed with
ILA in the design, and the same vectors already pass in Python and XSim, so
the only new variable is the silicon.

## Rule

Every one of these opens an existing, already-validated project. If a gate
would open something that has not passed its prerequisite, I do not prompt.

## Status of each gate, 23 Aug 2026

| gate | prerequisite | state | blocked on |
|---|---|---|---|
| 1 XSim waveform | regression green in batch | **NOT READY** | no RTL exists yet |
| 2 block design | BD validates, wrapper builds | **NOT READY** | no RTL exists yet |
| 3 ILA HIL | smoke test passed, timing closed with ILA in | **partially prepared** | no bitstream yet |

Gate 3 is the furthest along despite being last, because its board-side
prerequisite already passed: `docs/hil/smoke_test_01_jtag.md` records a full
JTAG chain, a programmed device reaching "End of startup status: HIGH", and a
PL clock measured at 301.03 MHz through a VIO. The ILA sizing, the Tcl capture
flow and the debug hub clock fix are all settled. What is missing is a design
to look at.

All three gates trace back to one open decision: candidate A scored 76 against
a pre-agreed novelty gate of 80, and three options are recorded in
`docs/architecture/candidate_trade_study.md` awaiting John's ruling. RTL does
not start before that, so no gate can be prompted before that.
