#!/usr/bin/env python3
"""FROZEN capacity-pressure coverage sweep.

Committed BEFORE execution. Nothing in this file, in golden/traces.py, or in the
kill thresholds may be changed after results are observed. The existing D3/D4
failure on the non-contended workload stands unchanged and is not superseded by
anything here.

Reports the COMPLETE grid including losing regions.
"""
from __future__ import annotations

import itertools
import json
import sys
from collections import defaultdict
from multiprocessing import Pool
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from golden import sim, traces                                     # noqa: E402

# ----------------------------------------------------------------- FROZEN GRID
FRAMES = (4, 8, 16)
WS_RATIO = (0.75, 1.0, 1.5, 2.0)
NONEVICT = (0.0, 0.25, 0.50, 0.75)
LOAD = (0.70, 0.80, 0.90, 0.95)
SPEC_SHARE = (0.0, 0.25, 0.50)
SLACK = (1.25, 2.0, 4.0)
SEEDS = (1, 2, 3, 4, 5)
N_REQ = 200

POLICIES = ("fifo", "edf_only", "credit_only", "tuned_axi_qos",
            "lifecycle_edf", "independent_dual_guard", "integrated")
BASELINE = "tuned_axi_qos"
CANDIDATE = "integrated"

# ------------------------------------------------------------ FROZEN THRESHOLDS
MIN_REL_GOODPUT_GAIN = 10.0     # percent, over tuned AXI QoS
MIN_THROUGHPUT_RETAINED = 90.0  # percent, of tuned AXI QoS completed
MIN_SEEDS = 3                   # distinct seeds showing the gain
MIN_ADJACENT_LOADS = 2          # adjacent load points showing the gain


def one(cfg):
    F, ws, ne, load, spec, slack, seed = cfg
    p, reqs, label = traces.capacity_contended(F, ws, ne, load, spec, slack,
                                               seed, n_req=N_REQ)
    rows = {}
    cov, valid = None, False
    for pol in POLICIES:
        r = sim.run(pol, p, reqs, label, strict=False)
        s = r.summary()
        rows[pol] = s
        if pol == CANDIDATE:
            cov = r.coverage
            valid = all(fn(r.coverage, p.n_frames)
                        for fn in traces.COVERAGE_BINS.values())
    return {"cfg": cfg, "label": label, "valid": valid,
            "coverage": cov, "rows": rows}


def gain(rows):
    b, c = rows[BASELINE], rows[CANDIDATE]
    b_ot, c_ot = b["on_time_per_offered_%"], c["on_time_per_offered_%"]
    rel = ((c_ot - b_ot) / b_ot * 100) if b_ot else (100.0 if c_ot else 0.0)
    tput = (c["completed"] / b["completed"] * 100) if b["completed"] else 0.0
    safe = not c["violations"]
    # "not produced solely by rejecting more": the candidate must not win while
    # completing materially less work
    not_by_rejection = c["completed"] >= b["completed"] * (MIN_THROUGHPUT_RETAINED / 100)
    return rel, tput, (rel >= MIN_REL_GOODPUT_GAIN
                       and tput >= MIN_THROUGHPUT_RETAINED
                       and safe and not_by_rejection)


def main() -> int:
    grid = list(itertools.product(FRAMES, WS_RATIO, NONEVICT, LOAD,
                                  SPEC_SHARE, SLACK, SEEDS))
    print(f"FROZEN SWEEP: {len(grid)} configs x {len(POLICIES)} policies "
          f"= {len(grid)*len(POLICIES)} runs")
    with Pool() as pool:
        res = pool.map(one, grid, chunksize=8)

    valid = [r for r in res if r["valid"]]
    print(f"\nCOVERAGE: {len(valid)}/{len(res)} configs hit all six bins "
          f"({100*len(valid)/len(res):.1f}%)")

    bin_hits = defaultdict(int)
    for r in res:
        F = r["cfg"][0]
        for k, fn in traces.COVERAGE_BINS.items():
            if r["coverage"] and fn(r["coverage"], F):
                bin_hits[k] += 1
    print("\nper-bin hit rate over the whole grid:")
    for k in traces.COVERAGE_BINS:
        print(f"  {k:<28}{bin_hits[k]:>6}/{len(res)}  {100*bin_hits[k]/len(res):>5.1f}%")

    if not valid:
        print("\nNO VALID CONFIG. The three-way intersection was never entered.")
        print("Per the frozen protocol this CLOSES THE BRANCH.")
        _dump(res)
        return 0

    # wins, only over VALID configs
    wins = []
    print(f"\n{'F':>3}{'ws':>5}{'ne':>5}{'load':>6}{'spec':>5}{'slack':>6}{'seed':>5}"
          f"{'base ot%':>10}{'cand ot%':>10}{'rel%':>8}{'tput%':>7}  gate")
    for r in sorted(valid, key=lambda x: x["cfg"]):
        rel, tput, ok = gain(r["rows"])
        F, ws, ne, load, spec, slack, seed = r["cfg"]
        b = r["rows"][BASELINE]["on_time_per_offered_%"]
        c = r["rows"][CANDIDATE]["on_time_per_offered_%"]
        print(f"{F:>3}{ws:>5}{ne:>5}{load:>6}{spec:>5}{slack:>6}{seed:>5}"
              f"{b:>10}{c:>10}{rel:>8.1f}{tput:>7.1f}  {'PASS' if ok else 'fail'}")
        if ok:
            wins.append(r["cfg"])

    print(f"\n{len(wins)}/{len(valid)} valid configs pass the per-point gate")

    # repeatability: >=MIN_SEEDS seeds AND >=MIN_ADJACENT_LOADS adjacent loads
    by_region = defaultdict(set)
    for F, ws, ne, load, spec, slack, seed in wins:
        by_region[(F, ws, ne, spec, slack)].add((load, seed))
    print("\nREPEATABLE REGIONS (>= "
          f"{MIN_SEEDS} seeds AND >= {MIN_ADJACENT_LOADS} adjacent loads):")
    repeatable = []
    for region, pts in sorted(by_region.items()):
        loads = sorted({l for l, _ in pts})
        adj = max((sum(1 for i in range(len(loads))
                       if i == 0 or LOAD.index(loads[i]) == LOAD.index(loads[i-1]) + 1),), default=0)
        run, best = 1, 1
        for i in range(1, len(loads)):
            run = run + 1 if LOAD.index(loads[i]) == LOAD.index(loads[i-1]) + 1 else 1
            best = max(best, run)
        seeds_ok = all(len({s for l, s in pts if l == L}) >= MIN_SEEDS for L in loads)
        n_seeds = max((len({s for l, s in pts if l == L}) for L in loads), default=0)
        ok = best >= MIN_ADJACENT_LOADS and n_seeds >= MIN_SEEDS
        print(f"  F={region[0]} ws={region[1]} ne={region[2]} spec={region[3]} "
              f"slack={region[4]}: loads {loads} (max adjacent run {best}), "
              f"max seeds at a load {n_seeds}  {'QUALIFIES' if ok else 'no'}")
        if ok:
            repeatable.append(region)

    print("\n" + "=" * 72)
    if repeatable:
        print(f"RESULT: {len(repeatable)} repeatable contiguous region(s) clear every")
        print("frozen gate. Candidate C+D may be REOPENED for the next stage.")
    else:
        print("RESULT: NO repeatable contiguous operating region clears the frozen")
        print("gates. Per the protocol this CLOSES THE BRANCH PERMANENTLY.")
        print("Do not start RTL.")
    print("=" * 72)
    print("ALL FIGURES SYNTHETIC. No AXI, DDR, ZCU104 or ILA measurement.")
    _dump(res)
    return 0


def _dump(res):
    dest = Path(__file__).resolve().parent / "results_sweep_capacity.json"
    dest.write_text(json.dumps(
        [{"cfg": list(r["cfg"]), "valid": r["valid"], "coverage": r["coverage"],
          "rows": r["rows"]} for r in res], indent=1, sort_keys=True))
    print(f"written: {dest}")


if __name__ == "__main__":
    raise SystemExit(main())
