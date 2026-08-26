#!/usr/bin/env python3
"""READ-ONLY extractor. Records the values DERIVED from already-hashed source.

Changes nothing. Reads no performance rows. Its purpose is to make the
transitively-pinned values human-readable without trusting a prose document.
"""
import sys, json, hashlib
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from gm.types import Params, DownstreamEnvelope          # noqa: E402
from gm.policies import POLICY_NAMES                     # noqa: E402
import inspect
from gm import sim                                       # noqa: E402

p, e = Params(), DownstreamEnvelope()
src = inspect.getsource(sim.run)
cens = [l.strip() for l in src.splitlines() if "deadline <= horizon" in l]

out = {
    "derived_from_hashed_source": {
        "gm/types.py": hashlib.sha256(Path("gm/types.py").read_bytes()).hexdigest(),
        "gm/sim.py": hashlib.sha256(Path("gm/sim.py").read_bytes()).hexdigest(),
        "gm/policies.py": hashlib.sha256(Path("gm/policies.py").read_bytes()).hexdigest(),
    },
    "N_out": p.max_axi_outstanding,
    "L_down_max_at_C_i_144": e.l_down_max(p.max_axi_outstanding, 144),
    "dispatch_queue_depth": p.dispatch_queue_depth,
    "envelope": {"C_max": e.c_max_cycles, "B_fixed": e.b_fixed_cycles,
                 "refresh": e.refresh_cycles_per_window, "window": e.window_cycles,
                 "bypass_txns": e.max_bypass_transactions,
                 "fifo_non_preemptive": e.fifo_non_preemptive},
    "policies": list(POLICY_NAMES),
    "horizon": "derived per trace by the runner; NOT a constant in gm/",
    "row_exclusion": "none (asserted in sweep_b.validate)",
    "censoring_predicate": cens or ["NOT FOUND"],
    "PRIMARY_GATES": {
        "STATUS": "NOT PRESENT IN ANY HASHED SOURCE OR IN THE MANIFEST",
        "on_time_goodput_gain_pct": 10,
        "total_throughput_retained_pct": 90,
        "qualifying_adjacent_loads": 2,
        "qualifying_primary_seeds": 3,
        "safety_accounting_violations": 0,
        "rejection_only_advantage": False,
        "provenance": "quarantine_sweep_A/FROZEN_SWEEP_PLAN.md lines 47-48, "
                      "dated 2026-08-23, carried forward unchanged. NOT restated "
                      "in any Sweep-B pre-launch artifact and NOT in the manifest.",
    },
}
print(json.dumps(out, indent=2))
