"""Proof that the BOUNDED lifecycle handle is RTL-realizable and equivalent.

RTL cannot store a Python object pointer. A descriptor therefore carries
{lifecycle_slot, phys_idx, expected_generation, transaction_tag} and resolution
is exactly:

    entry = lifecycle_ram[lifecycle_slot]
    valid = entry.phys_idx == d.phys_idx and entry.generation == d.expected_generation

This file proves the mapping: the bounded lookup agrees with pointer semantics
on every descriptor, the handle is bounded, and a stale descriptor resolves to
None rather than keeping an evicted object alive.
"""
from __future__ import annotations

import itertools, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from gm import policies, sim                                       # noqa: E402
from gm.checks import Checks                                       # noqa: E402
from gm.control_plane import ControlPlane                          # noqa: E402
from gm.coverage import Coverage                                   # noqa: E402
from gm.traces_b import capacity_contended                         # noqa: E402

PASS, FAIL = [], []
def ck(n, c, d=""):
    (PASS if c else FAIL).append((n, d))
    print(("  PASS  " if c else "  FAIL  ") + n + (f"   {d}" if d and not c else ""))


def t_source_purity():
    src = (Path(__file__).resolve().parents[1] / "gm" / "control_plane.py").read_text()
    body = src[src.index("def obj_for"):src.index("def on_axi_accept")]
    ck("handle: obj_for NEVER dereferences obj_ref", "obj_ref" not in body)
    for f in ("lifecycle_slot", "phys_idx", "expected_generation"):
        ck(f"handle: obj_for reads descriptor.{f}", f in body)
    ck("handle: obj_for compares entry.phys_idx", "entry.phys_idx" in body)
    ck("handle: obj_for compares entry.generation", "entry.generation" in body)


def t_equivalence_and_bounds():
    """Run real traces and check, on EVERY descriptor, that the bounded lookup
    agrees with pointer semantics and that the handle stays in range."""
    checked = stale_ok = 0
    for ws, ne, seed in itertools.product((1.5, 2.0), (0.25, 0.75), (1, 2)):
        p, e, reqs, hz = capacity_contended(4, ws, ne, 0.90, 0.25, 1.25, seed)[:4]
        for pol in ("integrated", "tuned_axi_qos"):
            ch = Checks(p, strict=False); cov = Coverage()
            cp = ControlPlane(p, ch, cov)
            sim.run(pol, p, reqs, e, hz)      # exercise; then rebuild for probing
            ch2 = Checks(p, strict=False)
            cp2 = ControlPlane(p, ch2, Coverage())
            from gm.data_plane import DataPlane
            dp2 = DataPlane(p, e, ch2); cp2.dp = dp2
            # drive a short prefix so descriptors exist with real handles
            for r in reqs[:60]:
                if getattr(r, "is_release", False):
                    continue
                c_i = -(-r.n_bytes // p.axi_bytes_per_cycle)
                try: l = e.l_down_max(p.max_axi_outstanding, c_i)
                except ValueError: continue
                cp2.admit(r, r.arrival, True, l)
            for d in cp2.all_desc:
                checked += 1
                ck_slot = 0 <= d.lifecycle_slot < p.n_meta_entries
                if not ck_slot:
                    ck("handle: lifecycle_slot within the bounded RAM", False,
                       f"slot={d.lifecycle_slot} bound={p.n_meta_entries}")
                    return
                got = cp2.obj_for(d)
                want = d.obj_ref if (d.obj_ref is not None
                                     and d.obj_ref.slot == d.lifecycle_slot
                                     and d.obj_ref.generation == d.expected_generation
                                     and cp2.lifecycle_ram[d.lifecycle_slot] is d.obj_ref) else None
                if got is not want:
                    ck("handle: bounded lookup agrees with pointer semantics",
                       False, f"desc {d.desc_id} got={got} want={want}")
                    return
    ck(f"handle: lifecycle_slot within the bounded RAM on all {checked} descriptors", True)
    ck(f"handle: bounded lookup agrees with pointer semantics on all {checked} descriptors",
       checked > 0, str(checked))


def t_stale_resolves_none():
    """A descriptor whose frame was rebound must resolve to None, NOT to a
    revived object. This is the whole reason a pointer is unsafe."""
    p, e, reqs, hz = capacity_contended(4, 2.0, 0.75, 0.95, 0.25, 1.25, 3)[:4]
    ch = Checks(p, strict=False)
    cp = ControlPlane(p, ch, Coverage())
    from gm.data_plane import DataPlane
    dp = DataPlane(p, e, ch); cp.dp = dp
    r = [x for x in reqs if not getattr(x, "is_release", False)][0]
    c_i = -(-r.n_bytes // p.axi_bytes_per_cycle)
    d = cp.admit(r, r.arrival, True, e.l_down_max(p.max_axi_outstanding, c_i))
    ck("stale: descriptor resolves while fresh", cp.obj_for(d) is not None)
    o = cp.obj_for(d)
    o.generation += 1                                  # frame rebound underneath
    ck("stale: generation bump makes it resolve to None", cp.obj_for(d) is None)
    o.generation -= 1
    cp._free_slot(o)                                   # object left the manager
    ck("stale: freed slot makes it resolve to None", cp.obj_for(d) is None)
    ck("stale: the freed slot returned to the pool", o.slot == -1)


def main():
    print("\n=== bounded lifecycle handle ===\n")
    t_source_purity(); print()
    t_equivalence_and_bounds(); print()
    t_stale_resolves_none()
    print(f"\nPASSED {len(PASS)}   FAILED {len(FAIL)}")
    for n, d in FAIL: print(f"  {n}   {d}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
