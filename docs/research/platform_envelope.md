# ZCU104 / Zynq UltraScale+ platform envelope

Every figure below was read from the cited source. Items marked CALCULATED are
my arithmetic on cited values, not published numbers. This file exists to kill
architectures that cannot physically work on this board.

## PS-PL interface widths, UG1085 v2.5 Table 35-1

| Interface | Data width | Direction |
|---|---|---|
| S_AXI_HP{0:3}_FPD | 32 / 64 / 128 | PL to PS FPD |
| S_AXI_HPC{0,1}_FPD | 128 fixed | PL to PS FPD |
| S_AXI_ACP_FPD | 128 | PL to PS FPD |
| S_AXI_LPD | 32 / 64 / 128 | PL to PS LPD |
| M_AXI_HPM{0,1}_FPD | 32 / 64 / 128 | PS FPD to PL |

Also from UG1085, M_AXI_HPM section: "AXI4 access in the PL is limited to a
burst length of 16."

## Maximum AXI interface frequency: 333 MHz, and the source is DS925 not UG1085

DS925, "Processor System (PS) Performance Characteristics", Table 6 "PS-PL
Interface Performance": FAXICLK, "Maximum AXI interface performance", max
333 MHz. Single Max column, not speed-grade split.

CORRECTION RECORDED: the agent grepped all 67,678 extracted lines of UG1085
v2.5 and found NO statement of 333 MHz in connection with the AXI ports. Cite
UG1085 for port widths, DS925 Table 6 for the frequency. Do not cite UG1085
for 333 MHz.

## Bandwidth ceilings

CALCULATED, HP port: 128 bits x 333 MHz = 16 B x 333e6 = **5,328 MB/s per HP
port per direction**. AMD does not print this product anywhere found.

DDR4 theoretical, and AMD states this themselves in the System Performance
Analysis guide: 2400 Mb/s x 8 bytes = **19,200 MB/s**. DS925 Table 3 gives the
2400 Mb/s max data rate.

## MEASURED numbers, in descending order of relevance

**FPT 2019, Manev, Vaishnav, Koch, "Unexpected Diversity: Quantitative Memory
Analysis for Zynq UltraScale+ Systems", DOI 10.1109/ICFPT47387.2019.00029.**
Custom RTL traffic generators attached DIRECTLY to HP ports, no interconnect,
bare metal, SMMU bypassed, 128-bit AXI. NOT the Xilinx AXI DMA IP.

- ZCU102 effective throughput reaches **75% of theoretical DDR peak**; Ultra96
  reaches 92.5%
- highest measured: **13,721 MB/s at 192-byte bursts** (HP0,1,3 or HP0,2,3)
- two-port configs peak **11,600 MB/s at 128-byte bursts**
- at 100 MHz PL: peak **8,800 MB/s** at 384-byte bursts, only 14% below the
  same config at 300 MHz
- single PS AXI connection ceiling: **9.6 GB/s at 300 MHz, 3.2 GB/s at 100 MHz**
- through Xilinx SmartConnect (Ultra96, 100 MHz): **3.2 GB/s** peak, oscillating
  down to an equilibrium of 2.25 GB/s at very large bursts
- SMALL-BURST PENALTY, the key number for our design: **up to 70% throughput
  loss at 16-byte bursts**. "On average, 128 and 192 Byte bursts often provide
  highest throughput."
- writes beat reads by 11 to 13% on average
- max AXI burst for a 128-bit configuration is 4 KiB

**AMD Adaptive Computing Wiki, "Linux DMA From User Space 2.0", ZCU102.**
AXI DMA IP with scatter-gather, 128-bit at 300 MHz PL, HPC port with hardware
coherency, dma-proxy driver, 100,000 transfers of 128 KB with verify enabled:
**810 MB/s**.
CALCULATED: 128 bits x 300 MHz = 4,800 MB/s per direction, so 810/4800 =
**16.9%**. This is a loopback with both channels active and CPU verification
in line. It is a system-level figure, NOT an AXI DMA ceiling. Do not quote it
as one.

**PG021 AXI DMA v7.1 Table 2-3**, the only AMD-published AXI DMA efficiency
table. 10,000-byte transfers at 100 MHz: MM2S **399.04 MB/s (99.76%)**, S2MM
**298.59 MB/s (74.64%)**.
CALCULATED: those percentages imply a 400 MB/s theoretical peak, i.e. 32-bit at
100 MHz, so the default config in that table is 32-bit.
CAVEAT: PG021's Fmax table lists only 7 series parts, not UltraScale+. This is
device-agnostic IP characterisation, not a Zynq UltraScale+ measurement.

**AMD System Performance Analysis guide, ZC702 (Zynq-7000, not ZU+).**
Four HP ports under AXI Traffic Generator stress requesting 4,096 MB/s: total
achieved **3,254.4 MB/s, 76% of theoretical**, with a concurrent CPU benchmark
running. Read bandwidth degrades from ~420 MB/s to ~340 MB/s per port under
CPU memory pressure, "caused by saturation at the DDR controller".

## AXI DMA latency, PG021 Table 2-2

MM2S: tail-descriptor write to m_axi_sg_arvalid 10 clocks; m_axi_sg_arvalid to
m_axi_mm2s_arvalid 28; m_axi_mm2s_arvalid to m_axis_mm2s_tvalid 6.
S2MM: tail-descriptor write to m_axi_sg_arvalid 10; s_axis_s2mm_tvalid to
m_axi_s2mm_awvalid 39.

## Design consequences that follow directly

1. **Burst size is the dominant lever, not clock frequency.** 100 MHz at
   384-byte bursts reached 8,800 MB/s while 16-byte bursts cost up to 70%.
   Any architecture whose access pattern is fine-grained and scattered will
   lose to a coalesced one regardless of how fast we clock the PL.
2. **The realistic single-port working figure is a few GB/s, not 5.3.** The
   5,328 MB/s ceiling is arithmetic. Through SmartConnect at 100 MHz the
   measured figure is 3.2 GB/s peak falling to 2.25 GB/s, and a full AXI DMA
   system with coherency and verification measured 810 MB/s.
3. **A design must coalesce into 128 to 192 byte bursts minimum** to sit near
   the efficient part of the curve.
4. Writes are slightly cheaper than reads, which matters for where we put the
   fallback path.

## Gaps NOT closed, recorded honestly

- XAPP1288 and XAPP1289: not retrieved, no content read
- All adaptivesupport.amd.com and forums.xilinx.com threads: JavaScript-gated,
  zero forum-sourced numbers
- OSTI/IEEE "Characterization of throughput on the AXI DMA bus for burst data
  transfer over Ethernet": access refused. The circulating figures of
  3192.76 Mbps for large packets and 2.6 Mbps for 4-byte packets come only
  from a search-engine abstract summary and are NOT verified. This is the most
  promising unread source for small-packet efficiency.
- AXI DataMover PG022 performance: nothing verified
- No quantified AMD statement exists that AXI DMA efficiency drops with packet
  size. PG021 states only a functional limitation for multichannel S2MM with
  bursts of 4 beats or fewer. The only quantified small-transfer degradation
  verified is the FPT19 academic 70%-at-16-bytes figure.
- PG021 April 2022 revision not confirmed to carry identical Table 2-3 values;
  the read copy is the October 2016 v7.1 from a university mirror.
