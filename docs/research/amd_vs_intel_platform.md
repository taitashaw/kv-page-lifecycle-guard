# AMD versus Intel/Altera: why this design targets the weaker platform on purpose

## The headline comparison, and it is not flattering to our board

| | AMD Zynq UltraScale+ XCZU7EV (ZCU104) | Intel Agilex 7 M-Series |
|---|---|---|
| memory | PS DDR4, 64-bit, 2400 Mb/s | 2x HBM2e stacks plus DDR5 |
| peak memory bandwidth | 19.2 GB/s theoretical (AMD SPA guide) | **820 GB/s HBM2e per device, VERIFIED** from Altera doc 683458 section 13. The circulating 1.0 to 1.1 TB/s total is a MARKETING TILE only and appears in no device-level document |
| realistic path to fabric | 5.3 GB/s per HP port arithmetic; measured 3.2 GB/s peak through SmartConnect, 810 MB/s through a full AXI DMA system | HBM directly attached to fabric |
| on-chip memory | 4.75 MB (312 BRAM + 96 URAM) | far larger, plus eSRAM on some SKUs |
| logic | 230,400 LUT elements | AGF 014 has 487,200 ALMs |
| CXL | none | CXL support on M-series |

**Agilex 7 M-Series has roughly a 40 to 57x memory bandwidth advantage.** That is
not a small gap to engineer around. It is the difference between a platform that
can hold and stream a model and one that cannot.

## Why this matters to the architecture decision, and why it argues FOR the ZCU104

The instinct is that the weaker board is a handicap. For this specific claim it
is the opposite, for three reasons.

**1. The claim is about bytes moved, and scarcity is the test.** The hypothesis
is that confidence-selected representation reduces bytes per useful result. On a
platform with 1 TB/s of HBM, a bandwidth saving is hard to observe because
bandwidth is not the binding constraint. On a board where the measured path to
DDR is a few GB/s, a reduction in bytes moved shows up directly in wall-clock
time and in counters. **The ZCU104 is a better instrument for measuring this
effect precisely because it is bandwidth-starved.**

**2. The closest published hardware work targets Agilex and does not
reproduce.** CXL-SpecKV (arXiv 2512.11920, FPGA'26, 12 citations) targets
AGFB014R24A2E2V and reports utilisation against a 933,120 ALM denominator with
64 GB HBM per device. Intel's own F-Series product table gives AGF 014 as
487,200 ALMs with no HBM. Its RTL has the confidence port tied to 32'd0, no
predictor module, and no testbenches. So the Agilex lane in this exact problem
is occupied by a paper whose artifact does not back it.

**3. If it works on the constrained platform, the case on the larger one is
arithmetic.** A result that reduces bytes per token on a 5 GB/s path transfers
upward. The reverse does not hold: a result demonstrated on HBM tells you
nothing about whether it helps where memory is scarce, which is where edge and
cost-sensitive inference actually lives.

## What we must NOT claim as a consequence

- not that the ZCU104 competes with Agilex or with a GPU on throughput
- not that results here predict datacenter performance
- the honest framing is that the board is a measurement instrument for a
  mechanism, and the mechanism is what generalises

## PRIMARY-SOURCE VERIFICATION, completed 2026-08-23

The earlier note said the Intel figures were secondary. They have now been
verified from primary Altera documents, reached via docs.altera.com because
intel.com, altera.com and cdrdv2-public.intel.com all return HTTP 403 to
automated fetch.

### Agilex 7 M-Series, from Altera doc 683458 section 13 and the M-Series Product Table

| item | verified figure |
|---|---|
| HBM2e stacks per device | 2 |
| capacity per stack | 8 GB or 16 GB |
| capacity per device | **16 GB or 32 GB** |
| bandwidth per stack | 410 GB/s |
| bandwidth per device | **820 GB/s** |
| HBM2e channels | 8 x 128-bit, or 16 x 64-bit pseudo-channels |
| DDR5 | hard controller, 6,400 Mbps (683458 Table 27) |
| devices | AGM 032 at 1,100,000 ALM; AGM 039 at 1,305,600 ALM |

CORRECTION TO MY OWN EARLIER ENTRY: I recorded "1.0 to 1.1 TB/s total" from
secondary sources. That figure exists only as a marketing tile on the product
page and appears in NO device-level document. The defensible number is 820 GB/s
of HBM2e per device. Aggregate DDR5 bandwidth in GB/s is stated nowhere in
primary documentation; the device docs give only data rate, width and EMIF
count.

### AMD XCZU7EV, from DS891 v1.11.1 Table 5, ALL CONFIRMED

230,400 CLB LUTs, 312 block RAM blocks (11.0 Mb), 96 UltraRAM blocks (27.0 Mb),
1,728 DSP slices, 460,800 CLB flip-flops, 504,000 system logic cells.

DS925 FAXICLK 333 MHz CONFIRMED, with a citation hazard: the current HTML
portal numbers it Table 6, the legacy PDF numbers the identical table Table 33.
Cite it by section name plus table number, because DS925 has no PDF and the
numbering is per topic.

UG1085 v2.5 Table 35-1 CONFIRMED. Note the coherent ports ACP, ACE and HPC are
FIXED at 128-bit; only HP, LPD and HPM are width-configurable.

### CXL-SpecKV: both flagged figures now definitively REFUTED, with a probable source

Decoding AGFB014R24A2E2V per 683458 section 2.5 Figure 6: the B in position
three means HPS yes, SCA no, **HBM2E none**.

- claimed 933,120 ALM denominator: **REFUTED**. AGF 014 has **487,200 ALMs**,
  confirmed by two independent primary tables. The paper's denominator is
  1.915x too large, which understates every reported utilisation by about 48
  percent.
- claimed 64 GB HBM per device: **REFUTED twice**. F-Series has no HBM
  interface at all, and no Agilex 7 part anywhere has 64 GB; the family maximum
  is 32 GB.
- **probable provenance of 933,120**: the Stratix 10 DX 2800 Product Table lists
  933,120 ALMs. The denominator appears to come from a different device family
  entirely.

### Documentation accessibility, the asymmetry that matters

AMD's authoritative numbers are reachable by an automated toolchain, and legacy
xilinx.com PDF links redirect cleanly into the portal. Intel's are reachable
only if you know to bypass intel.com entirely: the canonical cdrdv2-public URLs
that search engines surface and that papers cite return S3 AccessDenied, and the
M-Series memory-bandwidth white paper now 404s after the Altera spin-out.

Three internal inconsistencies were found in Intel documentation and none in
AMD's: an MLAB count that differs between the Product Table and the Device
Overview for AGF 019, a DDR5 rate given as 5,600 Mbps on the product page and
6,400 Mbps in Table 27, and the 1 TBps total-bandwidth claim that exists only
in marketing.

**For reproducible citation: use docs.altera.com khub PDFs with their internal
Gen-xxxx-x.x version stamp for Intel, never a cdrdv2-public URL or a product
page. For AMD, cite DS891 and UG1085 by version plus table, and DS925 by section
name plus table number.**
