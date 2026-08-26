# Edge FPGA LLM inference: what has actually been achieved, and on what

Full survey 2026-08-23. Verified by fetching papers, repositories and AMD board
documentation. This is the reality check against which our claims must sit.

## The ceiling on a ZCU104, from published work

**8.6 tokens/s, LLaMA3-8B at W4 GPTQ with KV8, 4K context.** Hummingbird,
ICCAD'25, arXiv 2507.03308, Jindong Li et al. Their accelerator IP core is only
18,355 LUT / 25,422 FF / 59 BRAM / 18 URAM / 179 DSP at 300 MHz. Code is open at
github.com/adamgallas/llama-fpga.

That is the highest figure anyone has published for a real 7B/8B dense model on
a ZU+ eval board, and it is the number our work sits beside.

Context: 4.8 tok/s on KV260 for the same model; 25 to 27 tok/s on KV260 but for
BitNet 0.73B ternary, a model roughly 40x smaller by active parameters; >18
tok/s for Qwen3-30B-A3B but only on a custom 24 GB PCB (Hummingbird+, FPGA'26).

## HARDWARE FACT THAT GATES WHAT WE CAN DEMONSTRATE

UG1267 states verbatim: **"The ZCU104 kit is shipped without a DDR4 SODIMM
installed."** Socket J1 ships empty and AMD recommends a 4 GB x64 DDR4-2666
module. The llama-fpga README independently confirms a 4 GB rank-1 SODIMM is
required for ZCU104.

Consequence, published: **with the PL SODIMM you get 8 to 9 tok/s; without it
you get 4 to 5**, because weights must be split across PS and PL memory.

PS memory on ZCU104 is 2 GB DDR4-2400, 64-bit, four MT40A256M16GE-083E devices.
Hummingbird ran PS at 2133 Mbps for 17.06 GB/s and added the PL SODIMM at the
same rate for **34.1 GB/s combined**.

**ACTION REQUIRED: confirm whether J1 on our board is populated.** No project on
this machine has ever constrained PL DDR pins, so it has never been exercised
here. This determines our achievable memory bandwidth and therefore what the
design can be measured against.

## The field's real currency: DDR bandwidth utilisation

Published band on Zynq UltraScale+: **85 to 94 percent of theoretical.**

- DATE'25 (arXiv 2502.10659), KV260: 85 percent of the 19.2 GB/s theoretical,
  using AXI Datamover across four AXI ports at 300 MHz, bare metal with no OS
  so all DRAM is reserved for weights and KV
- Hummingbird, KV260: 93 to 94 percent, via column-aligned access and a direct
  flash-to-datapath route for the embedding table

To expose 19.2 GB/s you need **four 128-bit AXI HP ports at 300 MHz**, since
4 x 16 B x 300 MHz = 19.2 GB/s exactly. One HP port at 128-bit and 300 MHz gives
4.8 GB/s.

**Architectural caveat from UG1085 that our design must respect:** the four HP
ports do NOT map to four independent DDR controller ports. HP1 and HP2 SHARE a
DDRC port, HP0 shares one with the DisplayPort master, and HP3 shares one with
the FPD-DMA.

## Derived: every 7B design is pinned to the memory wall

Multiplying tokens/s by per-token weight bytes recovers effective bandwidth:

| design | effective BW | fraction of platform peak |
|---|---|---|
| Hummingbird ZCU104 | ~34.4 GB/s | ~100% of 34 GB/s |
| Hummingbird KV260 | ~19.2 GB/s | ~100% of 19.2 GB/s |
| DATE'25 KV260 | ~17.2 GB/s | ~90% of 19.2 GB/s |
| TeLLMe v2 KV260 | ~3.4 GB/s | ~20% of 17.1 GB/s |

Every 7B/8B design is at the wall, so its tokens/s is fully determined by DDR
bandwidth and nothing architectural moves it. Only the sub-1B ternary designs
are compute-bound. **This is the strongest possible support for a design whose
claim is about BYTES MOVED rather than throughput.**

## TWO OPEN GAPS THAT MATCH OUR CAPABILITY

**1. A real KV cache manager in ZU+ fabric.** Nobody has built one. TeLLMe v2
has only K/V address ports, no eviction, no paging, no compression engine.
Hummingbird and DATE'25 quantize KV to 8-bit but manage it in SOFTWARE. The
genuinely detailed KV hardware, Titanus (GLSVLSI'25 Best Paper) and HiKV, is all
ASIC and all simulated. CXL-SpecKV is the only FPGA KV paper and its artifact
does not reproduce.

**2. ILA-grade hardware evidence. This is the finding that matters most to us.**
Stated plainly by the survey: no published FPGA LLM accelerator paper presents
ILA waveform captures or AXI transaction-counter traces as evidence. The field's
evidence ceiling is wall-clock tokens/s, a power meter reading, and occasionally
a demo video.

That is an unoccupied differentiator on exactly the hardware we have, and it
aligns with the workflow already agreed: John captures XSim, block design and
ILA himself in the GUI (docs/gui_gates.md).

## Also: no LLM MoE exists on FPGA at all

Every verified FPGA MoE accelerator (Edge-MoE ICCAD'23, UbiMoE, CoQMoE) runs
M3ViT, a VISION model. Nobody has built an LLM expert-routing crossbar in
fabric.

## Further damage to CXL-SpecKV's credibility

Beyond the earlier finding that its confidence port is tied to zero:
- it claims 64 GB HBM per device on Agilex-7; the M-Series maxes at 32 GB HBM2e
  as two 16 GB stacks, so that configuration does not exist
- 812 MHz post-place-and-route for a compression plus DMA plus coherence
  datapath is an extraordinary claim
- no board bring-up, no CXL link training, no measured CXL latency; T_CXL under
  400 ns is a stated assumption and tokens/s are projected
- the repository claims an FPGA'26 Best Paper Nomination; the program lists
  KANELE as Best Paper and a dynamic-HLS LSQ paper as Runner-up

## What a ZCU104 CANNOT demonstrate, recorded so we do not overclaim

- anything needing more than about 6 GB of weights, so Qwen3-30B-A3B at 4-bit
  (~15 GB) is not reproducible here
- anything HBM-class: FlightLLM's 55 tok/s and AccLLM's 164 tok/s rest on
  460 GB/s, roughly 13x our best case
- long context: llama-fpga caps at 1024 tokens, Hummingbird reaches 4096,
  FAST-Prefill's 128K needs 912 URAM against our 96
- fast prefill on a large model, which is unsolved on ZU+ for 7B class
- beating an embedded GPU on raw tokens/s. The honest framing, which
  Hummingbird+ itself adopts, is cost and energy per token

---

# Second, deeper survey. Corrections and a sharper picture.

A second independent sweep read the PDFs directly with pdftotext rather than
trusting summarisers, and it corrects the first survey in two places.

## CORRECTION 1: the ZU+ class record is 27.8 tok/s, not 18

**PD-Swap (arXiv 2512.11550), KV260, 27.8 tok/s decode, 148 tok/s prefill.**
BitNet 0.73B ternary, 4.9 W. Uses dynamic partial reconfiguration to swap
prefill and decode logic, committing an "equivalent total" of 106 percent of
device LUTs with a 45 ms reconfiguration overlapped into the prefill tail.

But note the caveats the sweep found: the paper **states no clock frequency
anywhere**, and it claims ternary weights are "permanently resident on-chip"
while KV260 has about 1 MB of BRAM plus URAM against a ~144 MB ternary model,
and the same paper later refers to reloading weight channels from DDR. Treat
the residency claim as unsound; the real behaviour is URAM-buffered streaming.

## CORRECTION 2: two entries in my earlier record were wrong

- **EdgeLLM (arXiv 2407.21325) is on a VCU128**, a datacenter HBM card, and is a
  DIFFERENT paper from SECDA-LLM (arXiv 2408.00462) on a PYNQ-Z1. I had
  conflated them.
- **SpeedLLM is Alveo U280**, not an edge part.

## The ZCU104 datapoint, now with the full resource table

Hummingbird, ICCAD'25, on XCZU7EV: LUT 66K, FF 92K, BRAM 133, URAM 40, DSP 362,
**266 MHz**, 34.1 GB/s across PS and PL DDR, **8.6 tok/s** on LLaMA3-8B GPTQ-4
with INT8 KV at 4096 context, batch 1, prefill:decode 32:32.

Derived utilisation on our part: 29 percent LUT, 20 percent FF, 43 percent BRAM,
42 percent URAM, 21 percent DSP. So roughly half the device is free.

Its 7.09 W is a **Vivado report estimate, not a power meter reading.**

## THE FINDING THAT MATTERS MOST FOR OUR DESIGN

Derived by the sweep, and it is the sharpest observation in either survey:

Decode is DDR-bandwidth-bound at 7B scale, and the ceiling is bandwidth divided
by model bytes. LLaMA2-7B at W4 is ~3.7 GB, giving a ~5 tok/s ceiling on
KV260's 19.2 GB/s, and Li et al. measured 4.9, which is 84 percent of it. Every
7B design is at the wall.

**But BitNet 0.73B at 1.58 bits is only ~144 MB, giving a ~133 tok/s ceiling.
TeLLMe v2 and PD-Swap reach 25 to 27.8, which is 19 to 21 percent of that
ceiling. At sub-1B ternary scale the part is no longer bandwidth-bound, it is
LOGIC-bound, and roughly 5x of headroom is unclaimed.**

Two consequences for us:
1. If we work at 7B scale, our bytes-moved claim is measured against a hard wall
   and any reduction shows up directly. This is the regime that validates the
   claim.
2. If anyone works at sub-1B ternary scale, bytes moved is NOT the binding
   constraint and our design would have nothing to prove there. The spec's
   "regimes where CGPF loses" section must add this explicitly.

## THE EVIDENCE GAP IS WIDER THAN FIRST REPORTED

The first survey found no ILA captures. The second states it more strongly:

**"Not one paper in this catalogue shows a board photo, an external power-meter
trace, or a hardware-in-the-loop video."**

Power is Vivado-report-derived for Hummingbird and TerEffic, unstated-method for
the entire TeLLMe family, and only ONE paper in the field, Monteiro and
Guerrieri (Electronics 2026, DOI 10.3390/electronics15051052, ZCU102), uses an
external measurement tool at all, via XRT.

Throughput is genuinely on-board for LlamaF, Hummingbird, Li et al., TeLLMe
v1/v2, PD-Swap, F-BFQ, TMMA and LightMamba-on-VCK190. It is profiled or
simulated for MEADOW, co-simulated for On-Device Qwen2.5, and
post-implementation-estimated for ALL of TerEffic.

This is now the clearest differentiator available to us, and it costs nothing
extra: we already have the board, the ILA path is proven working end to end at
301.03 MHz, and the GUI capture workflow is already agreed.

## Calibration against non-FPGA edge hardware, from PD-Swap's own table

Raspberry Pi 5: 16.6 tok/s on Qwen-0.6B at 7.8 W. Jetson Orin Nano: 67.6 tok/s
on TinyLlama-1.1B at 25 W. The FPGA wins on tokens per joule (5.67 against 2.12
and 2.70), not on raw tokens per second.

**Any public claim must use energy per token, not throughput, as the axis.**

## Batch size is 1 in every single in-scope work

Recorded because it bounds what "throughput" means in this field and prevents an
accidental apples-to-oranges comparison with batched GPU serving.
