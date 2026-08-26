# Environment inventory

Captured 2026-08-14 on the build host. Every line below was read from the
machine, not assumed.

## Tools

| tool | version | path | status |
|---|---|---|---|
| Vivado | v2025.2 (64-bit), tool version limit 2025.11 | /tools/Xilinx/2025.2/Vivado/bin/vivado | on PATH |
| Vitis | 2025.2, SW build 6298600, 13 Nov 2025 | /tools/Xilinx/2025.2/Vitis/bin/vitis | installed, NOT on PATH |
| xsct | same build as Vitis | /tools/Xilinx/2025.2/Vitis/bin/xsct | installed, NOT on PATH |
| xsdb | 2025.2 | /tools/Xilinx/2025.2/Vivado/bin/xsdb | on PATH |
| hw_server | 2025.2 | /tools/Xilinx/2025.2/Vivado/bin/hw_server | on PATH |
| Verilator | 5.020 (Debian 5.020-1) | /usr/bin/verilator | on PATH |
| Icarus Verilog | present | /usr/bin/iverilog | on PATH |
| Yosys | absent | | not installed system-wide |
| Python | 3.12.3 | | |
| Git | 2.43.0 | | |

Vitis and xsct require `export PATH=/tools/Xilinx/2025.2/Vitis/bin:$PATH`.
No `settings64.sh` exists under the 2025.2 tree; the 2025.2 Vitis uses the
unified launcher instead.

## Board

ZCU104 board files present:
`/tools/Xilinx/2025.2/data/xhub/boards/XilinxBoardStore/boards/Xilinx/zcu104`

Board NOT attached at inventory time: no Xilinx or Digilent device on lsusb,
no /dev/ttyUSB* or /dev/ttyACM*. Hardware-in-the-loop is therefore BLOCKED
until the board is connected and powered.

## Host

24 logical cores, 62 GB RAM.

## BLOCKER: disk

Root filesystem /dev/nvme0n1p5 is 480 GB, 453 GB used, **3.0 GB available,
100 percent full**. /, /home and /tmp are all the same filesystem.

The Xilinx install alone is 166 GB. The two largest user files are TEXBAT
GNSS datasets referenced by an existing project and must not be deleted
without the owner's decision:

- /home/jotshawlinux/Downloads/ds7.bin  47.0 GB
- /home/jotshawlinux/Downloads/ds2.bin  45.7 GB

A Vivado synthesis, implementation and bitstream run for a Zynq design of
this class needs materially more than 3 GB of scratch. This must be resolved
before Phase 6.

## Existing adjacent work by the same author

Three prior projects bear directly on the novelty gate and were inspected:

| project | what it is | reported status |
|---|---|---|
| kvcache-compress-engine | group-quantized KV codec, FP16 to INT2/INT4, outlier protection | 1,348 lines RTL, 16/16 tests, 400 MHz claimed |
| moe-router-engine | streaming top-8 of 256 experts, load balancer, AXI4-Stream + DMA | 17/17 tests, 300 MHz claimed |
| cxl-kv-forge-qos | multi-tenant KV QoS: tenant credits, token buckets, deadline-aware tournament arbiter, SLA telemetry | 12/12 XSim PASS, 350 MHz post-route WNS +0.004 ns, bitstream and .ltx generated |

cxl-kv-forge-qos is much closer to the brief's hypothesis than the two named
GitHub repositories, because the brief lists "request deadlines, fairness and
multi-tenant service guarantees" as a candidate axis and that axis is already
built and timing-closed. The novelty boundary must be drawn against all three.
