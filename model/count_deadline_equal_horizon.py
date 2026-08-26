#!/usr/bin/env python3
"""READ-ONLY. Counts requests whose d_SLO == H exactly.

sim.run iterates range(H), observing cycles 0..H-1. A request with deadline
exactly H is currently ELIGIBLE under `d_SLO <= H` but a legal completion at
cycle H can never be observed. If any exist, those requests are structurally
unable to succeed and the affected cells cannot receive PASS.
"""
import itertools, sys, json
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from gm.traces_b import capacity_contended

FRAMES=(4,8,16); WS=(0.75,1.0,1.5,2.0); NE=(0.0,0.25,0.50,0.75)
LOAD=(0.70,0.80,0.90,0.95); SPEC=(0.0,0.25,0.50); SLACK=(1.25,2.0,4.0); SEEDS=(1,2,3,4,5)

total_eq = 0
cfgs_with = []
n = 0
for cfg in itertools.product(FRAMES,WS,NE,LOAD,SPEC,SLACK,SEEDS):
    f,ws,ne,load,spec,slack,seed = cfg
    p,e,reqs,hz = capacity_contended(f,ws,ne,load,spec,slack,seed)[:4]
    eq = sum(1 for r in reqs
             if not getattr(r,"is_release",False) and r.deadline == hz)
    n += 1
    if eq:
        total_eq += eq
        cfgs_with.append((cfg, eq))
    if n % 1500 == 0:
        print(f"  ...{n}/8640 scanned, {total_eq} found so far", flush=True)

print(f"\nconfigurations scanned          : {n}")
print(f"n_deadline_equal_horizon TOTAL  : {total_eq}")
print(f"configurations affected         : {len(cfgs_with)}")
if cfgs_with:
    print("  first 5:", cfgs_with[:5])
    print("  -> NONZERO. Those requests must be excluded and affected metrics")
    print("     recomputed, or the affected cells CANNOT receive PASS.")
else:
    print("  -> ZERO. The formal notation changes to d_SLO < H.")
    print("     No request is affected and no result changes.")
Path("N_DEADLINE_EQ_HORIZON.json").write_text(json.dumps(
    {"scanned": n, "total": total_eq, "affected_configs": len(cfgs_with)}, indent=2))
