# Prior-art matrix: predictive data movement for inference accelerators

Compiled 2026-08-23 by the MoE and speculation workstream. Roughly 100 works
verified by fetching arXiv /abs pages, publisher pages, author-hosted PDFs
extracted locally, the Semantic Scholar Graph API keyed on real DOIs, and
FreePatentsOnline. Two further workstreams (KV-cache prior art, ZCU104
feasibility) were still running when this was written.

## The question asked

Has anyone built hardware that
(a) predicts what data an inference engine will need next,
(b) attaches a CALIBRATED confidence to that prediction,
(c) uses that confidence to choose the data representation or precision, and
(d) provides a bounded-cost EXACT fallback when the prediction is wrong?

## The answer

No. No verified work has all four. Critically, **nothing anywhere couples (b)
to (c)**: nobody fetches a cheap copy because the predictor is confident and an
expensive copy because it is not.

| Work | a predict | b calibrated confidence | c confidence picks representation | d bounded exact fallback |
|---|---|---|---|---|
| ST-MoE, arXiv 2606.15453 | yes | 2-bit saturating counter, uncalibrated | no, all BF16 | yes, correctness preserved |
| CXL-SpecKV, FPGA'26, 2512.11920 | yes | aggregate accuracy to depth | no, fixed INT8+delta+RLE | yes, 1850 ns sync fetch |
| HOBBIT, arXiv 2411.01433 | yes | importance score | YES, INT4/INT2 vs FP16 fetch | NO |
| CascadeCNN, FPL'18 | no | gBvSB, validation-tuned | yes, 4-bit then 8-bit | yes, one HPU pass |
| LVA, MICRO'14 | yes | yes, saturating counter + relaxed window | approx vs exact value | no, "rollbacks are eliminated" |
| RFVP, TACO'16 | yes | none | approx value | explicitly rejected |
| Context-Aware MoE CXL-NDP, 2512.04476 | yes | prefill statistics | yes, 1 to 4 bit per expert | no, frozen after prefill |
| SPP, MICRO'16 | yes | yes, per-prediction probability | no | n/a |

## The three papers that define the gap

**ST-MoE** (arXiv 2606.15453, cs.AR) is the closest single work and the most
likely examiner citation. Hardware expert prefetcher with 2-bit saturating
confidence states, prefetch when score >= 2, and on a miss "the missing experts
are fetched immediately to preserve inference correctness". Has a, b, d. Fails
c outright: "All MAC units use bfloat16 (BF16) arithmetic." Evaluated in
SCALE-Sim plus a custom C++ simulator with Synopsys DC on TSMC 40 nm. No FPGA,
no silicon.

**HOBBIT** (arXiv 2411.01433) is the only work where a runtime score picks the
precision of the data it fetches: "if s_ei <= T1 ... load the high-precision
version; otherwise ... the low-precision version". It has no fallback. The
low-precision result is final and the accuracy loss is permanent for that token.

**RFVP** (ACM TACO 12(4) Art. 62, 2016, DOI 10.1145/2836168) is the paper that
already argued the fallback is not worth paying for: "RFVP does not check for or
recover from load-value mispredictions, hence, avoiding the high cost of
pipeline flushes and re-executions." The contribution proposed here is precisely
the thing RFVP discarded, so the specification has to justify why the fallback
is affordable now when it was not then.

## Where novelty actually lives

1. **The b to c coupling.** Nobody selects representation on predictor
   confidence. HOBBIT picks precision by importance, Context-Aware MoE by
   prefill statistics, BitFusion statically per layer, CXL-SpecKV not at all.
2. **Calibration.** Zero works in this corpus calibrate a data-movement
   predictor. Every one reports top-k accuracy, recall or hit rate. None reports
   ECE, a reliability diagram or a coverage guarantee. The June 2026 ML-prefetch
   survey (arXiv 2606.09955) does not list calibration as a dimension at all.
3. **Bounded-cost exact fallback.** The field split into "never be wrong"
   (SpecPrefetch, ST-MoE, Pre-gated MoE) and "be wrong and eat it" (HOBBIT,
   FloE, RFVP, LVA). Only SP-MoE bounds anything, and it bounds prefetch depth,
   not miss cost.

## Obviousness attack to defend against

ST-MoE (a + b + d in hardware) combined with HOBBIT (score to precision)
combined with XtraMAC (ISCA'26, runtime datatype switching at constant
initiation interval on AMD U55c). The specification must carry its weight on
HOW confidence is calibrated and HOW fallback cost is bounded, because the
combination alone is attackable.

## Calibration constraint that binds our own claims

Verified Uncertainty Calibration (arXiv 1909.10155, NeurIPS'19): "popular
recalibration methods like Platt scaling and temperature scaling are (i) less
calibrated than reported, and (ii) current techniques cannot estimate how
miscalibrated they are."

This kills any claim of the form "we measured ECE therefore we are calibrated",
including ours. The defensible route is a finite-sample risk-control method:
Learn then Test (arXiv 2110.01052) as used by CALM (arXiv 2207.07061,
NeurIPS'22 Oral) to set early-exit thresholds "while provably maintaining high
performance", or online conformal prediction as in arXiv 2302.07675.

## Patent landscape

No patent covers a + b + c + d. Nothing recites a calibrated confidence.

- **Qualcomm US10176090** is the most dangerous. Claim 28: "determining the
  number of memory lines to read is based on a prefetch accuracy indicator
  provided by the memory read request"; claim 29 generates that indicator from
  "a ratio of a count of prefetched lines". A granted claim where a prefetch
  accuracy ratio governs how much compressed data is read. It is read
  granularity, not numeric precision, and the ratio is not calibrated, but it is
  the closest thing in any jurisdiction to the b to c coupling.
- **AMD US8510518**, claim 1: retrieving data "in one of a compressed access
  mode and a full access mode according to whether a bandwidth limited condition
  exists". Broad. Would read on a design that switches representation on runtime
  conditions. The trigger is bandwidth, not confidence.
- **IBM US10915446**: confidence gates drop or no-drop of a prefetch, not
  representation.
- **Intel US20250356164**: full versus partial hot expert buffers with a
  three-tier fallback. Cheap-copy-versus-full-copy with fallback in claim form,
  but the selector is a reactive frequency counter and the reduction is
  structural, not precision.
- **Intel WO/2025/184895A1**: reuse likelihood versus threshold produces a
  prefetch hint. No calibration, no representation choice, no fallback.

COVERAGE CAVEAT recorded by the agent: Google Patents was hard-blocked (HTTP
503) from this environment and assignee-wide sweeps could not be run. This is a
targeted probe, not a clearance search. A professional freedom-to-operate search
is required before any filing.

## Finding of concern: the closest hardware prior art does not reproduce

CXL-SpecKV is real and published (FPGA'26, Session II, 23 Feb 2026). The agent
cloned https://github.com/FastLM/CXL-SpecKV and read the RTL. Findings:

- the confidence path is tied to zero (`cxl_speckv_top.v:201` drives
  `.lstm_resp_confidences(32'd0)`), and there is no LSTM module in the RTL
- `pred_confidences` is written and never read anywhere in the design
- port width mismatch: declared [7:0], driven 32'd0, indexed [i*8 +: 8]
- SystemVerilog constructs inside .v files added as VERILOG_FILE
- no testbenches, no .sdc, no .qsf, no synthesis reports
- device mismatch: build targets AGFB014R24A2E2V; Intel's F-Series table gives
  AGF 014 487,200 ALMs and no HBM, while the paper claims 933K ALMs and 64 GB
  HBM per device and reports utilization against a 933,120 denominator

CONSEQUENCE FOR US: treat CXL-SpecKV as an architecture citation, not a
performance baseline. Its 3.2x / 2.8x / 812 MHz figures are not reproducible
from its own artifact.

HANDLING NOTE: this is a serious finding about another group's published work.
It belongs in our internal novelty reasoning and in a private note to the
authors if we ever benchmark against them. It is NOT material for a LinkedIn
post. We do not build credibility by attacking a peer's artifact in public.

## Citation hygiene flags recorded by the agent

- RFVP contains the string "confidence" zero times. The confidence windows and
  saturating counters belong to LVA (MICRO'14). Do not merge the two.
- Several arXiv entries were retitled with the same ID: 2503.04398 Speculative
  MoE is now Semantic Parallelism with a different author list; 2406.14066
  SmartSpec is now TurboSpec; 2503.05096 SpecServe is now AdaSpec; 2502.12224
  is now Fate. Version-1 numbers do not apply to current versions.
- Sarathi-Serve's current abstract says 2.6x/3.7x/5.6x, not the circulating
  6.9x. Clockwork says 99.9999 percent, not 99.997. FPGA spatial acceleration
  says 13.4x, not 16.1x.
- Unverified and flagged: SPP's own abstract, MegaBlocks repository URL,
  Pre-gated MoE ISCA'24 venue, SLOs-Serve OSDI'25 venue, AdaServe EuroSys'26
  venue. DFVG and Polaris dropped entirely as unverifiable.
