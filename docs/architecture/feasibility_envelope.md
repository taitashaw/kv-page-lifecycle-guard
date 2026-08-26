## Device envelope, read from the installed Vivado part database

Part xczu7ev-ffvc1156-2-e, board part xilinx.com:zcu104:part0:1.1

| resource | count | derived |
|---|---|---|
| LUT elements | 230,400 | |
| Slices | 28,800 | |
| Block RAM | 312 x 36 Kb | 11,232 Kb = 1.37 MB |
| UltraRAM | 96 x 288 Kb | 27,648 Kb = 3.38 MB |
| DSP | 1,728 | |
| **total on-chip memory** | | **4.75 MB** |

## The capacity finding that kills a whole class of architectures

Per-token KV footprint, computed as 2 (K and V) x kv_heads x head_dim x
bytes x layers. Tokens that fit in the ENTIRE 4.75 MB of on-chip memory,
ignoring that the design also needs buffers, FIFOs and ILA storage:

| model | FP16 KB/tok | tokens on chip | INT4 KB/tok | tokens on chip |
|---|---|---|---|---|
| Llama-3-8B | 128 | 38 | 32 | 152 |
| Llama-3-70B | 320 | 15 | 80 | 61 |
| Mixtral-8x7B | 128 | 38 | 32 | 152 |
| Qwen3-30B-A3B | 96 | 51 | 24 | 202 |

Even at INT4, the whole device holds tens to low hundreds of tokens. A single
4,096-token context of Llama-3-8B at FP16 is 512 MB, which is 108 times the
entire on-chip memory of this part.

## Consequences, stated as kill criteria

**KILLED: any architecture that stores the KV cache on chip.** Not marginal,
off by two orders of magnitude.

**KILLED: any architecture whose benefit needs HBM-class bandwidth.** The
measured single-port reality is a few GB/s (docs/research/platform_envelope.md):
3.2 GB/s peak through SmartConnect at 100 MHz decaying to 2.25 GB/s, and a full
AXI DMA system with coherency measured 810 MB/s on ZCU102.

**KILLED: any architecture with fine-grained scattered access.** Measured
penalty is up to 70 percent throughput loss at 16-byte bursts. Anything that
cannot coalesce into 128 to 192 byte bursts loses to a simpler design that can.

**SURVIVES: architectures that MANAGE MOVEMENT of data resident in PS DDR.**
The board's role is a control and decision fabric sitting in the data path, not
a storage tier. This is the shape the brief's hypothesis already implies: a
predictor, a confidence estimator, a representation selector and a fallback
path are all small state machines and arithmetic, not large memories.

**SURVIVES: on-chip structures sized in the tens to low hundreds of kilobytes.**
A page table, a predictor table, a confidence accumulator, a scoreboard and a
handful of stream buffers all fit comfortably inside 4.75 MB with room for ILA.

## Design targets that follow

1. Coalesce every DDR access into bursts of at least 128 bytes, ideally 192.
2. Budget on-chip memory in the low hundreds of kilobytes, not megabytes, and
   reserve explicit headroom for ILA capture storage.
3. Do not claim throughput from clock frequency. At 100 MHz with 384-byte
   bursts the measured figure was only 14 percent below 300 MHz. Burst shape
   dominates.
4. The accelerator must earn its place by reducing BYTES MOVED per useful
   result, because bytes moved is the binding constraint, not compute.
