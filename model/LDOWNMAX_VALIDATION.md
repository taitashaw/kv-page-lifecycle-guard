# Independent validation of `DownstreamEnvelope.l_down_max()`

**Status: the bound as written is REFUTED as a universal bound, and is EXACT
under one specific reading of its own terms.**

| field | value |
|---|---|
| bound under test | `gm/types.py`, `DownstreamEnvelope.l_down_max()` |
| validator | `model/validate_ldownmax.py` (independent, does not import `gm/data_plane.py`) |
| evidence class | **SYNTHETIC** — simulation of a queue/service model. Nothing here is a hardware measurement. |
| grid | 900 cells, 675 in-domain (`C_i <= C_max`), 225 skipped |
| randomised effort | 30 seeds x 3000 transactions per cell per mode |
| adversarial effort | exhaustive over all 1024 refresh start phases at the headline point |
| runtime | 2 m 10 s, single core, Python 3.12.3 |
| reproduce | `python3 validate_ldownmax.py --seeds 30 --ntxn 3000` |

---

## The bound under test

```
L_down,max,i  <=  B_fixed + (N_out - 1) * C_max + C_i + bypass_count * C_max + refresh
```

At `N_out=4, C_max=512, C_i=144, B_fixed=32, refresh=64, bypass=0` it returns
**1776** = `32 + 3*512 + 144 + 0 + 64`.

The validator re-implements this formula from the text (it does **not** call the
artefact for its own arithmetic) and then proves the two are the same function
over 2700 parameter combinations, so that a refutation cannot be an artefact of
a transcription error:

```
TASK 1 PRE-CHECK: analytic_bound() vs gm.types DownstreamEnvelope.l_down_max()
  2700 parameter combinations compared: IDENTICAL
  (gm/data_plane.py is NOT imported anywhere in this file.)

  spot check of the quoted headline: analytic_bound(N_out=4, C_max=512, C_i=144, B=32, refresh=64) = 1776

VALIDATOR SELF-TEST (the validator is checked before it judges)
  7 self-test groups, failures: 0  -> SELF-TEST PASSED
```

---

## Why there are four verdicts, not one

Two clauses of the service model are ambiguous in `types.py`, and the ambiguity
is exactly where the bound lives or dies. Rather than pick a reading and call
it the answer, the simulator is parameterised over both:

| | `B_fixed` charged | `refresh` charged |
|---|---|---|
| **mode L** (literal) | on every acceptance | truly periodic, every `window_cycles` |
| **mode B1** | on every acceptance | lumped, once per busy period |
| **mode B2** | once per busy period | truly periodic |
| **mode F** (bound-faithful) | once per busy period | lumped, once per busy period |

Mode L is the literal service model: *"fixed overhead `B_fixed` at acceptance"*
and *"a periodic refresh stall of `refresh` cycles per window"*. Mode F is the
only reading under which the bound can be true. B1 and B2 exist to attribute
blame to one term at a time.

---

## TASK 2 — grid result

```
in-domain cells (C_i <= C_max): 675
out-of-domain cells skipped (C_i > C_max): 225
randomised: 30 seeds x 3000 transactions per cell per mode

VERDICT PER SERVICE-MODEL VARIANT (adversarial + randomised):
  mode variant                                               violating cells
  L    literal    (B_fixed per acceptance, refresh truly periodic)    796  REFUTED   (adv 443, rand 353)
  B1   B_fixed-only(B_fixed per acceptance, refresh lumped once)    360  REFUTED   (adv 360, rand 0)
  B2   refresh-only(B_fixed amortised,      refresh truly periodic)    254  REFUTED   (adv 254, rand 0)
  F    bound-faithful (B_fixed amortised,   refresh lumped once)      0  not refuted   (adv 0, rand 0)
```

The counts are *findings*, not distinct cells: a cell refuted both adversarially
and randomly is counted twice. Mode L's 796 findings correspond to **443
distinct violating cells out of 675**.

Read that as: **each of the two ambiguous terms independently refutes the
bound.** Fixing only one does not save it.

### Every violating cell is named by a closed-form predicate

Listing 443 violating cells row by row would be noise. The validator instead
proposes a predicate and checks it against the observed violation set exactly:

```
VIOLATION PREDICATE (mode L): can every violating cell be named?
  Claim: in mode L a cell is refuted iff
     (N_out > 1 and B_fixed > 0)                     [B_fixed defect]
  or (refresh > 0 and span > window - refresh)       [refresh defect]
  where span = B_fixed + (N_out-1)*C_max + C_i.
  cells in domain            : 675
  cells the predicate flags  : 443
  cells actually refuted     : 443
  predicted-but-not-refuted  : 0
  refuted-but-not-predicted  : 0
  -> the predicate is EXACT. Every violation is one of exactly
     two arithmetic defects; no third failure mode exists in
     this grid.

  cells where the asserted bound HOLDS even in mode L: 232/675 (34.4%)
```

The full violating-cell list, with per-cell bound / observed / excess / seed, is
in the JSON emitted by `--json`. The predicate above is the whole content of
that list.

### Defect 1 — `B_fixed` is counted once but paid `N_out` times

If `B_fixed` is a per-acceptance overhead, then the `N_out - 1` transactions
ahead of transaction *i* each pay it too. The bound charges it once. The
shortfall is `(N_out - 1) * B_fixed`, and it is present **even when
`refresh = 0`**.

### Defect 2 — `refresh` is counted once but the interval crosses many windows

`window_cycles` is a declared field of `DownstreamEnvelope` (default 1024) and
`l_down_max()` never reads it. Adding `refresh` exactly once is only sound if
the whole acceptance-to-completion interval fits inside one window. It usually
does not — including at the shipped operating point:

```
SINGLE-REFRESH VALIDITY CONDITION  (arithmetic only, no simulation)
  cells with refresh>0 and C_i<=C_max : 450
  cells satisfying the condition       : 196  (43.6%)
  cells VIOLATING the condition        : 254  (56.4%)

  worst offenders (refresh stalls the interval can actually meet):
    N_out=16  C_max=1024  C_i=512  B=128  refresh=256  -> span=16000 > usable=768, up to 21 stalls, bound counts 1

  SHIPPED OPERATING POINT (N_out=4, C_max=512, C_i=144, B=32, refresh=64):
    span = 1712 cycles, usable per window = 960 cycles, stalls meetable = 2
    the condition is VIOLATED at the default operating point.
```

That block needs no simulator at all. It is arithmetic on the envelope's own
declared fields.

### Worst violations found

```
WORST VIOLATIONS BY EXCESS (mode L, the literal service model)
  N_out=16  C_max=1024  C_i=512  B=128  refresh=256  | bound=16256   observed=24064   excess=+7808   ratio=1.480 [adversarial]
  N_out=16  C_max=1024  C_i=16   B=128  refresh=256  | bound=15760   observed=23312   excess=+7552   ratio=1.479 [adversarial]
  N_out=16  C_max=1024  C_i=64   B=128  refresh=256  | bound=15808   observed=23360   excess=+7552   ratio=1.478 [adversarial]
  N_out=16  C_max=512   C_i=512  B=128  refresh=256  | bound=8576    observed=13824   excess=+5248   ratio=1.612 [adversarial]

  WORST RATIO ANYWHERE IN THE GRID: 2.9765x  at N_out=16 C_max=64 C_i=16 B=128 refresh=256  (bound=1360, observed=4048) [adversarial]
```

Worst *absolute* excess: **+7808 cycles**. Worst *ratio*: **2.98x the asserted
bound** — that cell is dominated by `B_fixed=128` paid 16 times against a
`C_max` of only 64, so the term the bound charges once is 16x larger than the
term it charges 15 times.

### Random traffic alone refutes 353 cells, with seeds

353 cells were refuted without any adversarial construction — plain randomised
arrivals found them. Example, replayed from its seed and confirmed to
reproduce:

```
  N_out=16 C_max=64 C_i=64 B_fixed=128 refresh=256 window=1024 seed=26
    bound=1408  observed=4045  excess=+2637  (replay reproduces: YES)
    ...
    #2052  PROBE arrive=269530   accept=460946   svc=64     start=464419   complete=464611   lat=3665
    #2053        arrive=269543   accept=461138   svc=60     start=464611   complete=465055   lat=3917
    #2054  PROBE arrive=269927   accept=461316   svc=64     start=465055   complete=465247   lat=3931
    #2055        arrive=270075   accept=461477   svc=63     start=465247   complete=465438   lat=3961
    #2056  PROBE arrive=270407   accept=461878   svc=64     start=465438   complete=465630   lat=3752
    #2057  PROBE arrive=270409   accept=462033   svc=64     start=465630   complete=466078   lat=4045
```

Two more replayed traces (seed 20 and seed 25) are in the console output of the
full run; all three reproduce exactly from `(cell, seed)`.

### Looseness — not a problem here

```
MODE F (bound-faithful) TIGHTNESS: observed/analytic, adversarial
  cells: 675   min ratio=1.0000   max ratio=1.0000   cells attaining the bound exactly: 675/675

LOOSENESS UNDER RANDOM TRAFFIC (mode F, randomised observed/analytic)
  cells=675  min=0.556  median=0.930  max=1.000
  cells where random traffic reached <10% of the bound: 0/675  (LOOSENESS finding, not a failure)
```

Under mode F the bound is not merely safe, it is **attained exactly in all 675
cells**. There is no slack to trade away. This is the strongest positive result
in this report and it is the reason the fix below is additive rather than a
rescale: nothing can be shaved off the existing terms.

---

## TASK 4 — adversarial, at the shipped operating point

The construction: server idle and empty at `t0`; `N_out - 1` blockers each with
service exactly `C_max` accepted at `t0`; the probe (service `C_i`) accepted at
`t0` as well, filling the outstanding window exactly. FIFO then forces the probe
behind all of them. Every one of the 1024 possible refresh start phases is
enumerated.

```
TASK 4  ADVERSARIAL AT THE SHIPPED OPERATING POINT   [SYNTHETIC]
  N_out=4 C_max=512 C_i=144 B_fixed=32 refresh=64 window=1024 bypass=0
  analytic bound = 32 + 3*512 + 144 + 0 + 64 = 1776

  mode L   literal    (B_fixed per acceptance, refresh truly periodic) observed=1936   ratio=1.0901  EXCEEDS BOUND   worst start phase t0=113
  mode B1  B_fixed-only(B_fixed per acceptance, refresh lumped once) observed=1872   ratio=1.0541  EXCEEDS BOUND   worst start phase t0=0
  mode B2  refresh-only(B_fixed amortised,      refresh truly periodic) observed=1840   ratio=1.0360  EXCEEDS BOUND   worst start phase t0=209
  mode F   bound-faithful (B_fixed amortised,   refresh lumped once) observed=1776   ratio=1.0000  within bound   worst start phase t0=0

  REPRODUCIBLE TRACE, mode L, start phase t0=113 (deterministic, no seed needed):
    #0           arrive=113      accept=113      svc=512    start=113      complete=657      lat=544
    #1           arrive=113      accept=113      svc=512    start=657      complete=1265     lat=1152
    #2           arrive=113      accept=113      svc=512    start=1265     complete=1809     lat=1696
    #9999  PROBE arrive=113      accept=113      svc=144    start=1809     complete=2049     lat=1936
    probe acceptance-to-completion = 1936 cycles vs bound 1776  -> excess +160

  over all 1024 start phases in mode L: min=1872 max=1936; 1024/1024 phases exceed the bound (100.0%)
  over all 1024 start phases in mode B2 (refresh defect ALONE, B_fixed amortised): min=1776 max=1840; 815/1024 phases exceed the bound (79.6%)
```

**This is the headline result.** The shipped `1776` is exceeded at the shipped
operating point, deterministically, with no seed required, in **100% of refresh
start phases** under the literal service model — and in **79.6% of phases** even
if you grant that `B_fixed` is amortised and only the refresh reading is held
literally.

The reproduction is one line:

```python
from validate_ldownmax import adversarial
adversarial(4, 512, 144, 32, 64, 1024, "per_txn", "periodic", phases=[113])
# -> (1936, 113, [...trace...])
```

---

## TASK 3 — sensitivity

### (a) Which term dominates as `N_out` grows

```
  N_out    bound |  B_fixed  (N-1)Cmax    C_i  refresh | share of the queueing term
      1      240 |       32          0    144       64 |    0.0%
      2      752 |       32        512    144       64 |   68.1%
      4     1776 |       32       1536    144       64 |   86.5%
      8     3824 |       32       3584    144       64 |   93.7%
     16     7920 |       32       7680    144       64 |   97.0%
     32    16112 |       32      15872    144       64 |   98.5%
     64    32496 |       32      32256    144       64 |   99.3%
```

`(N_out - 1) * C_max` is the only term that grows with `N_out`. It passes 50%
of the bound between `N_out=1` and `2`, is 86.5% at the shipped `N_out=4`, and
asymptotes to 100%. Every other term is a rounding error above `N_out=8`.

### (b) Marginal effect of each of the five terms

```
  term           delta   d(bound)   d(obs) L   d(obs) F   note
  b_fixed           32      1.000      6.000      1.000   model moves 6.0x faster than the bound
  c_max            128      3.000      3.500      3.000   model moves 1.2x faster than the bound
  c_i               64      1.000      1.000      1.000   MATCHES
  refresh           64      1.000      4.000      1.000   model moves 4.0x faster than the bound
  n_out              1    512.000    608.000    512.000   model moves 1.2x faster than the bound
  bypass             1    512.000    608.000    512.000   model moves 1.2x faster than the bound
```

Term by term:

- **`C_i`** is the only term the bound tracks correctly under every reading.
  Coefficient 1.0 in all modes. It is sound.
- **`B_fixed`** — the bound moves 1 cycle per cycle of `B_fixed`; the model
  moves **6**. Four of those are the four transactions that each pay it
  (`N_out=4`); the other two come from the extra work pushing the interval
  across an additional refresh stall. The two defects compound.
- **`refresh`** — the bound moves 1; the model moves **4**. Raising `refresh`
  both lengthens every stall *and* shrinks the usable window, so the effect is
  superlinear. This is the term the bound handles worst in relative terms.
- **`C_max`** and **`N_out`** — the bound's coefficients (`N_out - 1` and
  `C_max` respectively) are structurally right; the 1.2x gap is entirely the
  extra refresh crossings the longer interval now meets.
- **`bypass`** — exact under mode F (see below).

### (c) When does the bound become useless in practice

Criterion, taken from the model's own code: `gm/sim.py` line 88 computes
`d_issue = req.deadline - l_dm`. Once `L_down,max >= SLO`, the issue deadline
falls at or before arrival and **nothing is ever admissible**. The SLO reference
is the repo's own trace generator (`golden/traces.py` line 122:
`deadline = t + svc_kv * uniform(8, 16)` with `svc_kv = 144`), giving
1152 to 2304 cycles for the latency-sensitive tenant.

```
  N_out    bound  us @301MHz  vs SLO 1152  vs SLO 2304
      1      240       0.797           ok           ok
      2      752       2.498           ok           ok
      3     1264       4.199      USELESS           ok
      4     1776       5.900      USELESS           ok
      5     2288       7.601      USELESS           ok
      6     2800       9.301      USELESS      USELESS
      8     3824      12.703      USELESS      USELESS
     16     7920      26.310      USELESS      USELESS
     32    16112      53.523      USELESS      USELESS
```

- Against the **tightest** SLO in the repo (1152 cycles) the bound is already
  unusable at **`N_out = 3`**.
- Against the **loosest** (2304 cycles) it is unusable at **`N_out = 6`**.
- The shipped `N_out = 4` bound of 1776 cycles already consumes **154% of the
  tightest** and **77% of the loosest** SLO in the repo's own traffic model.

The 301.03 MHz clock used for the microsecond column is MEASURED and is cited
from `docs/hil/smoke_test_01_jtag.md`; it was not measured by this work. Every
cycle count in the table is SYNTHETIC.

The practical reading: the admission controller's `N_out` is not a free
performance knob. Raising it past 2 does not buy throughput, it destroys
admissibility, because `L_down,max` is subtracted from every deadline before
any request is tested.

### (d) Is the `C_max` assumption load-bearing? (heavy tails)

Randomised distribution sweep, mode F so the distribution is the only variable:

```
  dist              observed max    bound    ratio  verdict
  uniform                   1602     1776    0.902  within
  bimodal                   1680     1776    0.946  within
  pareto_trunc               944     1776    0.532  within
  always_max                1680     1776    0.946  within
  pareto_over x1.5 OVER          1200     1776    0.676  within
```

**Heavy tails are not the threat.** Any distribution *supported on* `[1, C_max]`
is safe, because the bound only ever uses the supremum of the service
distribution, never its shape. Pareto service was the *loosest* of all (ratio
0.532), because a heavy tail spends most of its mass near the minimum. Tail
shape changes tightness, not soundness.

What *is* load-bearing is the `C_max` cap itself. Random sampling understates
this (a Pareto tail rarely samples the extreme), so the adversarial version:

```
    ADVERSARIAL C_max violation: every blocker takes f*C_max,
    mode F (the otherwise-unrefuted variant), bypass=0
      f  blocker svc   observed    bound    ratio  verdict
   1.00          512       1776     1776    1.000  within
   1.01          517       1791     1776    1.008  EXCEEDS
   1.10          563       1929     1776    1.086  EXCEEDS
   1.25          640       2160     1776    1.216  EXCEEDS
   1.50          768       2544     1776    1.432  EXCEEDS
   2.00         1024       3312     1776    1.865  EXCEEDS
```

**Any** `f > 1` breaks the bound, by exactly `(N_out - 1) * C_max * (f - 1)`.
A single transfer that exceeds `C_max` by 1% is not a 1% error — it is amplified
`N_out - 1` times, because every transaction queued behind it inherits the
overrun. `C_max` is not a typical-case parameter and cannot be characterised by
sampling; it needs a genuine worst case or the whole envelope is void.

---

## The `bypass_count * C_max` term

```
  bypass    bound  obs mode F   ratio  obs mode L   ratio
       0     1776        1776   1.000        1936   1.090
       1     2288        2288   1.000        2544   1.112
       2     2800        2800   1.000        3152   1.126
       3     3312        3312   1.000        3696   1.116
```

Under mode F the bypass term is **exact**: each bypassing transaction
contributes exactly one further `C_max` and no more. The term's *arithmetic* is
correct. Whether `bypass_count = 0` is the right value is a separate question,
answered in Task 5.

---

## Proposed corrected bound

The refresh geometry has an exact closed form, verified by brute force over
every start phase against a second, independent cycle-stepping implementation:

```
  w   = N_out*B_fixed + (N_out-1+bypass)*C_max + bypass*B_fixed + C_i
  u   = window - refresh
  L  <=  w + refresh * ceil(w / u)

  refresh-inflation lemma, exhaustive over every start phase: EXACT

  cells checked (mode L, adversarial): 675
  corrected-bound violations          : 0
  tightest observed/corrected ratio   : 1.0000

  at the shipped operating point the corrected bound is 1936 cycles, versus 1776 asserted (+160 cycles, 1.09x).
```

Zero violations across all 675 in-domain cells, and attained exactly (ratio
1.0000), so it is a bound and not a fudge factor. It also finally *uses*
`window_cycles`, which the current implementation declares and ignores.

Two further robustness gaps worth closing at the same time:

1. `l_down_max()` does not check `C_i <= C_max`. 225 of the 900 grid cells are
   internally inconsistent in exactly this way and the function returns a
   confident number for every one of them. It should refuse, the same way it
   already refuses on unbounded bypass.
2. `window_cycles` is declared and never read. Either it constrains the bound
   or it should not be in the envelope.

---

## TASK 5 — scope, and what this is NOT

**This is validation of the ARITHMETIC against a queue/service model. It is not
proof of the ZCU104 PS DDR controller's universal worst-case response time.**
No hardware was involved at any point. The simulator is an idealised FIFO
non-preemptive server with a periodic stall; a real DDR4 controller has bank
conflicts, read/write turnaround, rank switching, page hits and misses, and a
PS-side arbiter shared with the APU, the GPU, the DisplayPort controller and the
DMA engines. **None of that is modelled here.** A refutation in this model is a
refutation of the arithmetic. A pass in this model is *not* a guarantee about
silicon.

The correct reading of the mode F result is therefore: *given* the envelope's
own assumptions, the formula is exact. The envelope's assumptions are the
unproven part.

### `bypass_count = 0` is a MODEL ASSUMPTION

`DownstreamEnvelope.max_bypass_transactions = 0` with the comment
"bounded priority bypass; 0 under FIFO" is **an assumption, not an established
property of the ZCU104 PS DDR path.** It asserts that no transaction can ever
overtake transaction *i* between its AXI acceptance and its completion. The
model does not derive this and no measurement in this repo supports it. The
same applies to `fifo_non_preemptive = True`.

This matters more than its size suggests. `bypass_count` multiplies `C_max`, the
single largest term. At the shipped operating point each unit of bypass adds
512 cycles, i.e. **+29% on the 1776 bound per bypassing transaction**. If the
true value is 3 rather than 0, the bound is 3312 and the admission controller
has been computing issue deadlines that are 1536 cycles too optimistic.

Beyond the QoS-401 read/write reordering below, the ZCU104 PS DDR path has at
least three other potential bypass sources this model does not represent: the
CCI-400 / interconnect arbiter shared with the APU and other masters, the DDR
controller's own bank-level scheduling (a page-hit to an open bank can be
serviced ahead of an older page-miss), and any QoS priority promotion applied
to a different HP/HPC port.

### Evidence that would establish `bypass_count`

Ordered cheapest first. None of these has been run.

1. **Read the QoS-401 / DDR controller configuration, not the datasheet.**
   Dump the live `DDRC` register block on the target board and record the
   read/write reordering, bank scheduling and port-arbitration settings. If
   reordering is enabled, `bypass_count = 0` is refuted on the spot, from a
   register dump, with no RTL. This is the single highest-value cheap check and
   it requires only a booted board.
2. **AXI ID discipline audit.** If the fabric master issues all transactions on
   a single AXI ID, AXI4 ordering rules force per-ID response ordering and
   `bypass_count = 0` becomes defensible *for that master in isolation*.
   Multiple IDs, or multiple masters sharing a port, void it. This is an RTL
   design decision that can be made and then verified, not discovered.
3. **ILA capture of AR/AW ID and R/B ID with cycle timestamps.** Trigger on
   AXI_ACCEPT and COMPLETE (both are hardware-observable at the interface, per
   the `TxnEvent` docstring; `DDR_SERVICE_START` is not). Count, over a long
   capture, any completion whose acceptance was later than a still-outstanding
   transaction's. `max(bypass observed)` is a lower bound on `bypass_count`; it
   can never establish the upper bound.
4. **Adversarial co-tenant traffic during the ILA capture.** Run the APU
   hammering DDR from Linux, or a second DMA master, while capturing. Bypass
   from interconnect arbitration will not appear under a quiet system.
5. **A stated, written envelope from AMD** covering the PS DDR controller's
   reordering behaviour under the configured QoS settings. This is the only
   evidence class that can establish an *upper* bound rather than a lower one.
   Absent it, `bypass_count` should carry an engineering margin rather than a 0.

Until at least (1) and (2) exist, `bypass_count = 0` should be recorded in the
model as an **ASSUMPTION with an open evidence gap**, and the value used in
`l_down_max()` should be a conservative non-zero margin, not 0.

### What this validation does and does not need

It does **not** need FPGA hardware, and requiring board measurement before
checking the arithmetic would have been a circular gate: the bound is used at
admission time to compute `d_issue`, so a wrong bound corrupts the RTL's
behaviour before there is any RTL to measure. The two defects found here are
arithmetic and would have survived any amount of board time, because a real
board would simply have exhibited the longer latency and been blamed for it.

---

## Summary

| claim | verdict | evidence class |
|---|---|---|
| The formula matches the artefact under test | confirmed, 2700 combinations | SYNTHETIC |
| Bound holds under literal service model | **REFUTED**, 443/675 cells | SYNTHETIC |
| Bound holds at the shipped `N_out=4, C_i=144` point | **REFUTED**, 1936 vs 1776, all 1024 phases | SYNTHETIC |
| Worst overshoot found | **2.98x** the bound (+7808 cycles at worst absolute) | SYNTHETIC |
| `B_fixed` term correct | **REFUTED**, undercounts by `(N_out-1)*B_fixed` | SYNTHETIC |
| `refresh` term correct | **REFUTED**, undercounts every window crossing past the first | SYNTHETIC |
| `C_i` term correct | confirmed, coefficient 1.0 in all modes | SYNTHETIC |
| `(N_out-1)*C_max` term correct | confirmed, exact under mode F | SYNTHETIC |
| `bypass*C_max` term correct | confirmed, exact under mode F | SYNTHETIC |
| Bound is exact (not loose) under its intended reading | confirmed, 675/675 attain it exactly | SYNTHETIC |
| Heavy-tailed service breaks the bound | **NO** — tail shape is irrelevant, only `C_max` matters | SYNTHETIC |
| Service exceeding `C_max` breaks the bound | **YES**, for any `f > 1`, amplified `N_out - 1` times | SYNTHETIC |
| Proposed corrected bound holds | confirmed, 0/675 violations, attained exactly | SYNTHETIC |
| `bypass_count = 0` is true of the ZCU104 | **NOT ESTABLISHED** — model assumption, evidence gap | NOT RUN |
| Anything about real ZCU104 PS DDR worst-case latency | **NOT ESTABLISHED** — out of scope | NOT RUN |

Net: `l_down_max()` is not a bound as written. It is exact under an
interpretation the code does not state and its own `window_cycles` field
contradicts. Two terms undercount, both by the same mistake — charging a
per-occurrence cost once — and the fix is arithmetic, additive, and verified
here across the same 675 cells.
