# FROZEN capacity-pressure sweep plan

Committed BEFORE execution at 2026-08-24T02:20:14Z. Nothing below may be
changed after results are observed. The existing D3/D4 failure on the
non-contended workload STANDS UNCHANGED and is not superseded by this sweep.

## Frozen artefacts, SHA-256
```
17b950b41288482fad6ddb64556739078fb364b0e118c9d27196ea589ae88c3c  golden/checks.py
de8e21cd20fd263faa8f4e5a51ead3c0e49a3a89c26daa4b33b0aa489ef8f681  golden/control_plane.py
64b45cf9b71f9ae90a1004bb3ac70768c047d5fa6c286253ee9497aaa2f4b1d0  golden/data_plane.py
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  golden/__init__.py
fd337a33081f6272b16a2297ec9e4126ec616e4fa374c5cf6c5fee13de1f5e15  golden/policies.py
70817005d29a935614225a6df9f0a85777228abf45ca162cbdb5b7929871ce8f  golden/sim.py
07a712306a054b5e7693cdb584f9cba06ca9c4c0d422be3e2c39942d0e0d6eb8  golden/traces.py
a034eae17201d0ec8ef1840607ffe41ab65d42368c72a01bc0f8634ba39e07a1  golden/types.py
6f7927542fb7d39cd5b5aa1e80d01dca85e396c8cf0d1b13314868c89ef260d1  sweep_capacity.py
b39485f26f20a4ee8190de06cfafec57e19e31a1494e4d71912294ba8c74da33  tests/test_golden.py
```

## Frozen grid

| axis | values |
|---|---|
| frames | 4, 8, 16 |
| working set / frames | 0.75, 1.0, 1.5, 2.0 |
| temporarily non-evictable fraction | 0%, 25%, 50%, 75% |
| offered load | 0.70, 0.80, 0.90, 0.95 |
| speculative share | 0%, 25%, 50% |
| deadline slack multiplier | 1.25, 2.0, 4.0 |
| seeds | 1, 2, 3, 4, 5 |
| requests per trace | 200 |

8,640 configs x 7 policies = 60,480 runs.

## Frozen coverage bins. A config missing ANY is INVALID for this test.

1. frame occupancy reaches 100%
2. capacity_block_cycles > 0
3. no_safe_victim_cycles > 0
4. max_non_evictable_frames >= F - 1
5. at least one miss waits for reference or in-flight retirement
6. at least one request feasible without lifecycle blocking, infeasible with it

## Frozen pass gates

- on-time goodput per OFFERED request improves >= 10% over tuned AXI QoS
- completed throughput >= 90% of tuned AXI QoS
- gain appears at >= 2 ADJACENT load points AND >= 3 seeds
- not produced solely by rejecting more requests
- no D1 safety or accounting trigger fires

## Frozen close conditions

- no valid trace hits the required coverage intersection
- the advantage appears in only one hand-crafted trace
- on-time goodput ties while throughput falls
- the integrated policy wins only because a baseline lacks lifecycle safety
- tuned AXI QoS matches or beats it throughout the valid contention region

## Pre-run calibration, disclosed

Two generator constants were set BEFORE freezing and BEFORE observing any
policy comparison, because the axis could not otherwise span the region
under test:

- `downstream_max_latency` set to the isolated transfer latency (144 cycles).
  A value larger than the service time drives d_issue negative for tight
  deadlines.
- deadline base reduced from 8x/20x service to 2x/6x. With an 8x base a drain
  of roughly 1x service can never tip feasibility at any slack in the grid,
  so bin 6 was unreachable by construction.

A coverage probe over 96 grid corners before freezing found 4 fully valid.
The intersection appears only at slack 1.25 with a high non-evictable
fraction. That narrowness is itself a result and is reported as such.

## Baseline added for this sweep

`independent_dual_guard`: a deadline test computed WITHOUT lifecycle
blocking, a SEPARATE capacity test, admit only if both independently pass,
and drain precedence deliberately excluded from the deadline calculation.
This, not `lifecycle_edf`, is the baseline the counterexample is meant to
defeat: `lifecycle_edf` consults drain availability and so already leaks
lifecycle knowledge into its capacity test.

All baselines receive the SAME allocator, lifecycle safety, descriptor
capacity and DDR model. Only the admission predicate differs.
