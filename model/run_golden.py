#!/usr/bin/env python3
"""Run every policy against every trace and emit the comparison table.

Reports offered, admitted, completed and on-time SEPARATELY, because collapsing
them into one throughput number is exactly what hid Candidate C's admission
trade. Decision 004 section D3.

Everything printed here is SYNTHETIC. It is a model, not the board.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from golden import sim, traces                                    # noqa: E402
from golden.policies import ALL_POLICIES                          # noqa: E402

POLICIES = [c.name for c in ALL_POLICIES]
COLS = [
    ("policy", 15, "s"), ("offered", 8, "d"), ("admitted", 9, "d"),
    ("completed", 10, "d"), ("on_time", 8, "d"), ("late", 6, "d"),
    ("rejected", 9, "d"), ("on-time/offered %", 18, "s"),
    ("ddr %", 7, "s"), ("p99 lat", 8, "d"), ("spec", 6, "d"),
]


def row(r):
    s = r.summary()
    late = r.completed - r.on_time
    return (f"{s['policy']:<15}{s['offered']:>8}{s['admitted']:>9}"
            f"{s['completed']:>10}{s['on_time']:>8}{late:>6}{s['rejected']:>9}"
            f"{s['on_time_per_offered_%']:>18}{s['ddr_util_%']:>7}"
            f"{s['p99_issue_latency']:>8}{s['spec_issued']:>6}"
            f"   {','.join(sorted(set(s['violations']))) or '-'}")


def header():
    h = "".join(f"{n:<{w}}" if f == "s" and i == 0 else f"{n:>{w}}"
                for i, (n, w, f) in enumerate(COLS))
    return h + "   violations"


def main() -> int:
    out = {}
    for tname, fn in traces.REGISTRY.items():
        p, reqs, desc = fn()
        print(f"\n=== TRACE: {tname} ===")
        print(f"    {desc.strip().splitlines()[0] if desc else ''}")
        print(f"    frames={p.n_frames} desc={p.n_descriptors} "
              f"reserved={p.n_reserved_mandatory_desc} "
              f"port={p.axi_bytes_per_cycle}B/cy outstanding={p.max_axi_outstanding}")
        print()
        print(header())
        print("-" * len(header()))
        out[tname] = {}
        for pol in POLICIES:
            r = sim.run(pol, p, reqs, tname, strict=False)
            print(row(r))
            out[tname][pol] = r.summary()

    # load sweep: Decision 004 D3 requires comparison across offered load,
    # not at one operating point
    print("\n=== LOAD SWEEP, two-tenant, SYNTHETIC ===")
    print(f"{'load':>6}{'policy':>16}{'admitted':>10}{'completed':>11}"
          f"{'on_time':>9}{'ot/offered %':>14}{'ddr %':>8}{'p99':>8}")
    sweep = {}
    for load in (0.70, 0.80, 0.90, 0.95):
        p_, reqs_, _ = traces.two_tenant_workload(target_load=load)
        sweep[load] = {}
        for pol in ("tuned_axi_qos", "lifecycle_edf", "integrated"):
            r = sim.run(pol, p_, reqs_, f"two_tenant@{load}", strict=False)
            t = r.summary()
            sweep[load][pol] = t
            print(f"{load:>6.2f}{pol:>16}{t['admitted']:>10}{t['completed']:>11}"
                  f"{t['on_time']:>9}{t['on_time_per_offered_%']:>14}"
                  f"{t['ddr_util_%']:>8}{t['p99_issue_latency']:>8}")
        print()
    out["_sweep"] = {str(k): v for k, v in sweep.items()}

    # the primary gate from Decision 004 D4
    print("\n=== PRIMARY GATE (D4), SYNTHETIC ===")
    print("    improve on-time completions per OFFERED request by >=10% over")
    print("    tuned AXI QoS while retaining >=90% of its completed throughput")
    print()
    for tname, rows in out.items():
        if tname.startswith("_"):
            continue
        base = rows.get("tuned_axi_qos")
        cand = rows.get("integrated")
        if not base or not cand:
            continue
        b_ot = base["on_time_per_offered_%"]
        c_ot = cand["on_time_per_offered_%"]
        rel = (c_ot - b_ot) / b_ot * 100 if b_ot else float("inf")
        tput = (cand["completed"] / base["completed"] * 100) if base["completed"] else 0.0
        passed = rel >= 10.0 and tput >= 90.0
        print(f"  {tname:<16} on-time/offered {b_ot:>6}% -> {c_ot:>6}%  "
              f"({rel:+.1f}% rel)   throughput retained {tput:.1f}%   "
              f"{'PASS' if passed else 'FAIL'}")

    print()
    for load, rows in sweep.items():
        b, c = rows["tuned_axi_qos"], rows["integrated"]
        rel = ((c["on_time_per_offered_%"] - b["on_time_per_offered_%"])
               / b["on_time_per_offered_%"] * 100) if b["on_time_per_offered_%"] else float("nan")
        tput = (c["completed"] / b["completed"] * 100) if b["completed"] else 0.0
        ok = rel >= 10.0 and tput >= 90.0
        print(f"  load {load:.2f}   {b['on_time_per_offered_%']:>6}% -> "
              f"{c['on_time_per_offered_%']:>6}%  ({rel:+.1f}% rel)   "
              f"throughput {tput:.1f}%   {'PASS' if ok else 'FAIL'}")

    dest = Path(__file__).resolve().parent / "results_golden.json"
    dest.write_text(json.dumps(out, indent=2, sort_keys=True))
    print(f"\nwritten: {dest}")
    print("ALL FIGURES ABOVE ARE SYNTHETIC. No AXI, DDR, ZCU104 or ILA measurement.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
