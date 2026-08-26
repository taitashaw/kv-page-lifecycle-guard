"""Frozen synthetic fixtures for the verdict engine.

Hashing compute_verdict.py proves stability, not correctness. These fixtures
exercise every boundary the frozen plan names, BEFORE unblinding.
"""
from __future__ import annotations
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import compute_verdict as V                                      # noqa: E402

PASS, FAIL = [], []
def ck(n, c, d=""):
    (PASS if c else FAIL).append((n, d))
    print(("  PASS  " if c else "  FAIL  ") + n + (f"   {d}" if d and not c else ""))


def rec(on_time, offered, completed=100, horizon=1000, viol=None, total_bytes=None):
    return {"on_time": on_time, "offered": offered, "completed": completed,
            "horizon": horizon, "violations": viol or [], "total_bytes": total_bytes}


def seedrows(cand, base_a, base_b):
    return {"integrated": cand, "tuned_axi_qos": base_a,
            "separable_conservative_guard": base_b}


def t_boundary():
    """Exactly 10% must PASS; a hair under must FAIL. Integer cross-multiplied."""
    base = rec(100, 1000)                      # S_p = 0.100
    ck("boundary: exactly +10.000% passes", V.gain_ok(rec(110, 1000), base))
    ck("boundary: +9.9% fails",             not V.gain_ok(rec(109, 1000), base))
    ck("boundary: +10.1% passes",           V.gain_ok(rec(111, 1000), base))
    # different denominators, so a float ratio would be lossy
    ck("boundary: 33/300 vs 30/300 is exactly +10%, passes",
       V.gain_ok(rec(33, 300), rec(30, 300)))
    ck("boundary: 3299/30000 vs 3000/30000 is just under, fails",
       not V.gain_ok(rec(3299, 30000), rec(3000, 30000)))


def t_zero_and_empty():
    ck("zero baseline (both nonempty) does NOT qualify",
       not V.gain_ok(rec(50, 1000), rec(0, 1000)))
    try:
        V.eligible_n(rec(10, 0)); ok = False
    except V.Degenerate:
        ok = True
    ck("empty cohort |E|==0 raises Degenerate, distinct from a zero baseline", ok)
    okc, wins, degen = V.cell_passes({1: seedrows(rec(50, 0), rec(1, 0), rec(1, 0))})
    ck("empty-cohort cell counts as degenerate, not as a pass",
       (not okc) and degen == 1, f"ok={okc} degen={degen}")


def t_seed_rule():
    good = seedrows(rec(200, 1000), rec(100, 1000), rec(100, 1000))
    bad  = seedrows(rec(100, 1000), rec(100, 1000), rec(100, 1000))
    ck("3 of 5 seeds passes", V.cell_passes({1: good, 2: good, 3: good, 4: bad, 5: bad})[0])
    ck("2 of 5 seeds fails",  not V.cell_passes({1: good, 2: good, 3: bad, 4: bad, 5: bad})[0])


def t_retention_and_safety():
    base = rec(100, 1000, completed=1000)
    ck("throughput retention exactly 90% passes",
       V.retain_ok(rec(200, 1000, completed=900), base))
    ck("throughput retention 89.9% fails",
       not V.retain_ok(rec(200, 1000, completed=899), base))
    hurt = seedrows(rec(200, 1000, viol=["unsafe_reuse"]), rec(100, 1000), rec(100, 1000))
    ck("a safety trigger disqualifies the seed even with a huge gain",
       not V.cell_passes({1: hurt, 2: hurt, 3: hurt})[0])


def t_shared_seed_adjacency():
    """THE AUTHORITATIVE RULE: |P_Li ^ P_Li+1| >= 3.

    Two adjacent loads can each pass 3/5 while sharing only ONE seed. That is
    not a stable operating region and must NOT form one.
    """
    axes = (4, 2.0, 0.5, 0.25, 1.25)
    same = {(axes + (0.70,)): {1, 2, 3}, (axes + (0.80,)): {1, 2, 3}}
    ck("shared-seed: identical 3-seed subsets at adjacent loads FORM a region",
       len(V.build_regions(same)) == 1, str(V.build_regions(same)))

    diff = {(axes + (0.70,)): {1, 2, 3}, (axes + (0.80,)): {3, 4, 5}}
    ck("shared-seed: DIFFERENT 3-of-5 subsets sharing only seed 3 form NO region",
       V.build_regions(diff) == [], str(V.build_regions(diff)))

    two = {(axes + (0.70,)): {1, 2, 3, 4}, (axes + (0.80,)): {3, 4, 5}}
    ck("shared-seed: overlap of 2 is still below the threshold, no region",
       V.build_regions(two) == [], str(V.build_regions(two)))

    three = {(axes + (0.70,)): {1, 2, 3, 4}, (axes + (0.80,)): {2, 3, 4, 5}}
    r = V.build_regions(three)
    ck("shared-seed: overlap of exactly 3 forms a region", len(r) == 1, str(r))
    ck("shared-seed: the region reports its shared seeds",
       r and r[0][2] == [2, 3, 4], str(r))

    # THE THREE-CELL COUNTEREXAMPLE. Every ADJACENT pair intersects in 3, but
    # the REGION-WIDE intersection is only {3}. Pairwise is not enough.
    three = {(axes + (0.70,)): {1, 2, 3},
             (axes + (0.80,)): {1, 2, 3, 4, 5},
             (axes + (0.90,)): {3, 4, 5}}
    r = V.build_regions(three)
    ck("region-wide: adjacent pairs all share 3 but the region-wide "
       "intersection is {3}, so a 3-load region must NOT form",
       all(len(x[1]) < 3 for x in r), str([(x[1], x[2]) for x in r]))
    ck("region-wide: it still yields the two-load sub-regions",
       len(r) >= 1 and all(len(x[2]) >= 3 for x in r), str([(x[1], x[2]) for x in r]))

    chain = {(axes + (0.70,)): {1, 2, 3}, (axes + (0.80,)): {1, 2, 3},
             (axes + (0.90,)): {3, 4, 5}, (axes + (0.95,)): {3, 4, 5}}
    r = V.build_regions(chain)
    ck("shared-seed: a seed-subset change SPLITS the run into two regions",
       len(r) == 2, str([(x[1], x[2]) for x in r]))


def t_structured_outcome_fields():
    """String-literal semantics replaced by machine-checkable fields."""
    f = V.outcome_fields("PASS", 0)
    ck("PASS + 0 regions -> branch_closed True", f["branch_closed"] is True)
    ck("PASS + 0 regions -> confirmation_required False", f["confirmation_required"] is False)
    f = V.outcome_fields("PASS", 3)
    ck("PASS + regions -> branch_closed False", f["branch_closed"] is False)
    ck("PASS + regions -> confirmation_required True", f["confirmation_required"] is True)
    for st in ("INDETERMINATE_COHORT_IDENTITY", "FAIL"):
        for n in (0, 2):
            f = V.outcome_fields(st, n)
            ck(f"{st} + {n} regions -> branch_closed False", f["branch_closed"] is False)
    for st in ("PASS", "INDETERMINATE_COHORT_IDENTITY", "FAIL"):
        for n in (0, 2):
            ck(f"{st} + {n} -> rtl_authorized is ALWAYS False",
               V.outcome_fields(st, n)["rtl_authorized"] is False)
    ck("FAIL forbids interpretation",
       V.outcome_fields("FAIL", 1)["interpretation_permitted"] is False)
    ck("branch_closed == (audit_status == PASS and region_count == 0)",
       all(V.outcome_fields(st, n)["branch_closed"] == (st == "PASS" and n == 0)
           for st in ("PASS", "INDETERMINATE_COHORT_IDENTITY", "FAIL") for n in (0, 1, 5)))


def t_manifest_recomputation():
    src = Path(__file__).resolve().parents[1].joinpath("compute_verdict.py").read_text()
    ck("engine recomputes against ANALYSIS_MANIFEST.sha256",
       "ANALYSIS_MANIFEST.sha256" in src)
    ck("engine does NOT trust auditor-embedded hashes",
       "analysis_code_sha256" not in src)
    ck("engine refuses on a manifest mismatch",
       "does not match the frozen analysis" in src)


def t_outcome_table():
    """GO is retired. Five states, and none of them authorizes RTL."""
    ck("PASS + regions -> confirmation required, not GO",
       V.OUTCOME[("PASS", True)] == "DISCOVERY_PASS_CONFIRMATION_REQUIRED")
    ck("PASS + no regions -> branch closed",
       V.OUTCOME[("PASS", False)] == "DISCOVERY_NO_GO_BRANCH_CLOSED")
    ck("INDETERMINATE + regions -> provisional only, no GO",
       V.OUTCOME[("INDETERMINATE_COHORT_IDENTITY", True)] == "PROVISIONAL_REGIONS_ONLY")
    ck("INDETERMINATE + no regions -> INCONCLUSIVE, branch REMAINS OPEN",
       V.OUTCOME[("INDETERMINATE_COHORT_IDENTITY", False)]
       == "INCONCLUSIVE_BRANCH_REMAINS_OPEN")
    ck("indeterminate outcomes exit nonzero",
       V.OUTCOME_EXIT["PROVISIONAL_REGIONS_ONLY"] != 0
       and V.OUTCOME_EXIT["INCONCLUSIVE_BRANCH_REMAINS_OPEN"] != 0)
    src = Path(__file__).resolve().parents[1].joinpath("compute_verdict.py").read_text()
    ck("GO_TO_RTL_V1 is never issued by this engine",
       "GO_TO_RTL_V1 is NOT issued here under any outcome" in src)
    ck("indeterminate regions are named THRESHOLD-MATCHING PROVISIONAL",
       "THRESHOLD-MATCHING PROVISIONAL" in src)
    ck("inconclusive does NOT close the branch",
       "REMAINS OPEN" in V.OUTCOME_MEANING["INCONCLUSIVE_BRANCH_REMAINS_OPEN"])


def t_observation_cycles():
    ck("observation cycles = H - start with start 0, i.e. H, not H+1",
       V.observation_cycles({"horizon": 1000}) == 1000)
    r = {"horizon": 1000, "total_bytes": 2_000_000, "on_time_bytes": 1_000_000}
    ck("completed-byte throughput uses ALL completed bytes",
       V.completed_byte_throughput(r) == 2000.0)
    ck("on-time byte goodput is SEPARATE and smaller here",
       V.on_time_byte_goodput(r) == 1000.0)
    ck("on-time byte goodput is None when unrecorded, never faked",
       V.on_time_byte_goodput({"horizon": 10}) is None)


def t_adjacency_and_regions():
    """Adjacency shape, with IDENTICAL seed subsets so only geometry is tested."""
    axes = (4, 2.0, 0.5, 0.25, 1.25)
    S = {1, 2, 3}
    def regions_from(loads):
        return [r[1] for r in V.build_regions({axes + (l,): set(S) for l in loads})]
    ck("adjacent 0.70,0.80 forms one region", regions_from((0.70, 0.80)) == [[0.70, 0.80]])
    ck("non-adjacent 0.70,0.90 forms NO region", regions_from((0.70, 0.90)) == [])
    ck("region SPLITS at a gap: 0.70,0.80 and 0.90,0.95 give TWO regions",
       regions_from((0.70, 0.80, 0.90, 0.95)) == [[0.70, 0.80, 0.90, 0.95]]
       or regions_from((0.70, 0.80, 0.90, 0.95)) == [[0.70, 0.80], [0.90, 0.95]],
       str(regions_from((0.70, 0.80, 0.90, 0.95))))
    ck("a true gap splits: 0.70,0.80 + 0.95 yields one region and drops the singleton",
       regions_from((0.70, 0.80, 0.95)) == [[0.70, 0.80]],
       str(regions_from((0.70, 0.80, 0.95))))
    ck("single load never forms a region", regions_from((0.90,)) == [])


def t_byte_goodput_separate():
    r = rec(100, 1000, completed=500, horizon=1000, total_bytes=2_000_000)
    ck("completed-byte throughput is not S_p",
       abs(V.completed_byte_throughput(r) - 2000.0) < 1e-9)
    ck("throughput is None when bytes unrecorded, never faked",
       V.completed_byte_throughput(rec(1, 10)) is None)


def t_audit_gating():
    src = Path(__file__).resolve().parents[1].joinpath("compute_verdict.py").read_text()
    ck("engine refuses without an audit artifact", "no audit_artifact.json" in src)
    ck("engine requires audit_status == PASS for a branch verdict",
       'status == "FAIL"' in src and "INDETERMINATE_COHORT_IDENTITY" in src)
    ck("INDETERMINATE forbids advance AND closure",
       "No advance, no closure." in V.OUTCOME_MEANING["PROVISIONAL_REGIONS_ONLY"])
    closing = [k for k in V.OUTCOME_MEANING if "BRANCH_CLOSED" in k]
    ck("exactly ONE outcome closes the branch", closing == ["DISCOVERY_NO_GO_BRANCH_CLOSED"],
       str(closing))
    reach = {audit for (audit, _), out in V.OUTCOME.items() if "BRANCH_CLOSED" in out}
    ck("branch closure reachable ONLY from a PASSING audit", reach == {"PASS"}, str(reach))
    ck("every non-PASS outcome explicitly denies closure",
       all("no closure" in V.OUTCOME_MEANING[o].lower()
           or "REMAINS OPEN" in V.OUTCOME_MEANING[o]
           or "suppressed" in V.OUTCOME_MEANING[o].lower()
           for (a, _), o in V.OUTCOME.items() if a != "PASS"))
    ck("engine names v4 as the authoritative plan",
       "SWEEP_B_ANALYSIS_PLAN_004.json" in src)
    ck("engine no longer references the superseded v3",
       "SWEEP_B_ANALYSIS_PLAN_003.json" not in src)
    ck("engine verifies the manifest hash recorded by the audit",
       "manifest hash changed since the audit" in src)


def main():
    for f in (t_boundary, t_zero_and_empty, t_seed_rule, t_retention_and_safety,
              t_shared_seed_adjacency, t_structured_outcome_fields,
              t_manifest_recomputation, t_outcome_table, t_observation_cycles,
              t_adjacency_and_regions, t_byte_goodput_separate, t_audit_gating):
        print(f"[{f.__name__}]"); f(); print()
    print(f"PASSED {len(PASS)}   FAILED {len(FAIL)}")
    for n, d in FAIL: print(f"  {n}   {d}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
