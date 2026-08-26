#!/usr/bin/env python3
"""EXECUTABLE analysis plan. The ONLY code permitted to compute a Sweep B verdict.

GATED. It refuses to run unless an audit artifact exists carrying the exact run
id, the manifest hash, and audit_status == PASS. It also verifies the
authoritative analysis plan's hash before doing anything.

THREE-STATE OUTCOME LOGIC. If cohort identity is not directly verified, the
experiment can support NEITHER a definitive positive NOR a branch-closing
negative:

    PASS                          -> apply the frozen gates, issue GO / NO-GO
    INDETERMINATE_COHORT_IDENTITY -> PROVISIONAL regions only.
                                     NO GO and NO BRANCH CLOSURE.
    FAIL                          -> suppress interpretation; run invalid

PRIMARY METRIC, offered-cohort on-time completion fraction:

    S_p = |{ r in E : completed_p(r) AND t_complete,p(r) <= d_SLO(r) }| / |E|
    E   = { r : NOT r.is_release AND d_SLO(r) <= H(c,s) }

The completion predicate is EXPLICIT so an unfinished request can never be
counted, and d_SLO is used, never d_issue. |E| == 0 is DEGENERATE and cannot
qualify; that is distinct from a nonempty cell whose baseline score is zero.

The 10% boundary uses INTEGER cross-multiplication, never float equality.
"""
from __future__ import annotations
import collections, hashlib, json, sys
from pathlib import Path

LOAD_ORDER = (0.70, 0.80, 0.90, 0.95)
GAIN_NUM, GAIN_DEN = 11, 10        # candidate/baseline >= 1.10  <=>  10*c >= 11*b
RETAIN_NUM, RETAIN_DEN = 9, 10     # candidate/baseline >= 0.90  <=>  10*c >= 9*b
SEEDS_MIN, SEEDS_OF, ADJ_MIN = 3, 5, 2
CANDIDATE = "integrated"
BASELINES = ("tuned_axi_qos", "separable_conservative_guard")
AUTHORITATIVE_PLAN = "SWEEP_B_ANALYSIS_PLAN_004.json"

#: FIVE-STATE outcome table. "GO" is retired: Sweep B is a DISCOVERY
#: experiment and can never authorize RTL or Vivado.
OUTCOME = {
    ("PASS", True):  "DISCOVERY_PASS_CONFIRMATION_REQUIRED",
    ("PASS", False): "DISCOVERY_NO_GO_BRANCH_CLOSED",
    ("INDETERMINATE_COHORT_IDENTITY", True):  "PROVISIONAL_REGIONS_ONLY",
    ("INDETERMINATE_COHORT_IDENTITY", False): "INCONCLUSIVE_BRANCH_REMAINS_OPEN",
}
OUTCOME_MEANING = {
    "DISCOVERY_PASS_CONFIRMATION_REQUIRED":
        "Regions found under a passing audit. ALL are forwarded to the "
        "fresh-seed confirmation. This does NOT authorize RTL or Vivado.",
    "DISCOVERY_NO_GO_BRANCH_CLOSED":
        "No region under a passing audit. The C+D performance branch is CLOSED. "
        "The lifecycle counterexample is retained as a correctness artifact.",
    "PROVISIONAL_REGIONS_ONLY":
        "Cohort identity unverified. These are THRESHOLD-MATCHING PROVISIONAL "
        "regions, not qualifying regions. No advance, no closure.",
    "INCONCLUSIVE_BRANCH_REMAINS_OPEN":
        "Cohort identity unverified and no region matched. The result is "
        "INCONCLUSIVE and the branch REMAINS OPEN. It is NOT closed.",
    "RUN_INVALID":
        "Audit failed. Performance interpretation is suppressed.",
}
#: STRUCTURED outcome fields. Testing a string for "BRANCH_CLOSED" is itself a
#: string-literal test; these are the machine-checkable facts.
def outcome_fields(audit_status, region_count):
    passed = (audit_status == "PASS")
    return {
        "outcome": OUTCOME.get((audit_status, region_count > 0), "RUN_INVALID"),
        "audit_status": audit_status,
        "region_count": region_count,
        "branch_closed": passed and region_count == 0,
        "confirmation_required": passed and region_count > 0,
        "rtl_authorized": False,
        "interpretation_permitted": audit_status != "FAIL",
    }


OUTCOME_EXIT = {"DISCOVERY_PASS_CONFIRMATION_REQUIRED": 0,
                "DISCOVERY_NO_GO_BRANCH_CLOSED": 0,
                "PROVISIONAL_REGIONS_ONLY": 2,
                "INCONCLUSIVE_BRANCH_REMAINS_OPEN": 2,
                "RUN_INVALID": 3}


class Degenerate(Exception):
    pass


def eligible_n(rec):
    n = rec.get("offered")
    if not n:
        raise Degenerate("|E| == 0: empty eligible cohort is undefined")
    return n


def s_p_parts(rec):
    """Returns (numerator, denominator) as INTEGERS. No float division here."""
    return int(rec.get("on_time", 0)), int(eligible_n(rec))


def gain_ok(cand, base):
    """10 * (c_num/c_den) >= 11 * (b_num/b_den), integer cross-multiplied."""
    cn, cd = s_p_parts(cand)
    bn, bd = s_p_parts(base)
    if bn == 0:
        return False                       # zero baseline: degenerate, fails
    return GAIN_DEN * cn * bd >= GAIN_NUM * bn * cd


def retain_ok(cand, base):
    bc = int(base.get("completed", 0))
    if bc == 0:
        return False
    return RETAIN_DEN * int(cand.get("completed", 0)) >= RETAIN_NUM * bc


def completed_byte_throughput(rec):
    """ALL completed payload bytes per observation cycle. Not SLO-aware."""
    h, b = observation_cycles(rec), rec.get("total_bytes")
    return (b / h) if (h and b is not None) else None


def on_time_byte_goodput(rec):
    """Payload bytes of ON-TIME completions per observation cycle. Reported
    SEPARATELY from completed-byte throughput; the two are never conflated."""
    h, b = observation_cycles(rec), rec.get("on_time_bytes")
    return (b / h) if (h and b is not None) else None


def cell_passes(by_seed):
    """Returns (passes, PASSING_SEED_SET, degenerate_count).

    The SET matters: region continuity requires the SAME seeds to succeed at
    both adjacent loads, not merely 3/5 at each independently.
    """
    winners, degenerate = set(), 0
    for seed, rows in by_seed.items():
        cand = rows.get(CANDIDATE)
        if cand is None or cand.get("violations"):
            continue                        # safety trigger: seed fails
        try:
            ok = all(gain_ok(cand, rows[b]) and retain_ok(cand, rows[b])
                     for b in BASELINES if b in rows)
            ok = ok and all(b in rows for b in BASELINES)
        except Degenerate:
            degenerate += 1
            continue
        if ok:
            winners.add(seed)
    return (len(winners) >= SEEDS_MIN), winners, degenerate


def build_regions(passing):
    """AUTHORITATIVE RULE: shared-seed continuity.

        |P_Li  intersect  P_Li+1|  >=  SEEDS_MIN

    Each load independently reaching 3/5 is NOT sufficient. Two adjacent cells
    can each pass 3/5 while sharing only one successful seed, which does not
    demonstrate a stable operating region. The intersection rule is the one
    that binds.
    """
    regions, by_axes = [], collections.defaultdict(dict)
    for (f, ws, ne, spec, slack, load), winners in passing.items():
        by_axes[(f, ws, ne, spec, slack)][load] = winners
    for axes, loads in by_axes.items():
        idx = sorted(LOAD_ORDER.index(l) for l in loads)
        run = [idx[0]]
        for i in idx[1:]:
            cur = LOAD_ORDER[i]
            contiguous = (i == run[-1] + 1)
            # REGION-WIDE cumulative intersection, not pairwise. Pairwise
            # overlap does not survive a longer region: {1,2,3} / {1,2,3,4,5} /
            # {3,4,5} has every adjacent pair at 3 but a region-wide
            # intersection of just {3}.
            cum = _common(loads, run) if contiguous else []
            shared = len(set(cum) & loads[cur]) >= SEEDS_MIN if contiguous else False
            if contiguous and shared:
                run.append(i)
            else:
                if len(run) >= ADJ_MIN:
                    regions.append((axes, [LOAD_ORDER[j] for j in run],
                                    _common(loads, run)))
                run = [i]
        if len(run) >= ADJ_MIN:
            regions.append((axes, [LOAD_ORDER[j] for j in run], _common(loads, run)))
    return regions


def _common(loads, run):
    out = None
    for j in run:
        w = loads[LOAD_ORDER[j]]
        out = set(w) if out is None else (out & w)
    return sorted(out or [])


def observation_cycles(rec):
    """EXACT definition. sim.run iterates `for cycle in range(horizon)`, so the
    observed cycles are 0 .. H-1 inclusive and the interval length is

        observation_cycles = H - start = H        (start == 0)

    It is NOT H - start + 1.
    """
    return rec.get("horizon") or 0


def load_gate(run_dir: Path):
    # PREFLIGHT FIRST. Integrity says the records are complete and unaltered.
    # Preflight says the experiment measured what its author claimed. A run can
    # be perfectly recorded and still be meaningless, which is exactly what
    # happened on 2026-08-24: duplicate baselines, a mechanism inert in 94% of
    # runs, and an effect not attributable to it. No verdict may be computed
    # over a failed preflight.
    pf_p = run_dir / "preflight.json"
    if not pf_p.exists():
        print("REFUSING: no preflight.json. Run preflight.py first.")
        sys.exit(4)
    pf = json.loads(pf_p.read_text())
    if pf.get("run_id") != run_dir.name:
        print("REFUSING: preflight.json belongs to a different run.")
        sys.exit(4)
    if not pf.get("preflight_passed"):
        print(f"REFUSING: PREFLIGHT FAILED with {len(pf.get('failures', []))} "
              f"blocking checks. The experiment did not measure what it claimed.")
        for f in pf.get("failures", []):
            print(f"    {f}")
        print("\nNo verdict, no regions, no branch closure. Fix the experiment.")
        sys.exit(4)

    art_p = run_dir / "audit_artifact.json"
    if not art_p.exists():
        print("REFUSING: no audit_artifact.json. Run audit_sweep_b.py first.")
        sys.exit(3)
    art = json.loads(art_p.read_text())
    man = json.loads((run_dir / "manifest.json").read_text())
    if art.get("run_id") != man.get("run_id"):
        print("REFUSING: audit artifact run id does not match the manifest.")
        sys.exit(3)
    live = hashlib.sha256((run_dir / "manifest.json").read_bytes()).hexdigest()
    if art.get("manifest_sha256") != live:
        print("REFUSING: manifest hash changed since the audit.")
        sys.exit(3)
    # Recompute ALL analysis-file hashes against the FROZEN analysis manifest.
    # Trusting hashes the auditor embedded is self-attestation: a modified
    # auditor would simply embed its own new hash.
    manifest = Path("ANALYSIS_MANIFEST.sha256")
    if not manifest.exists():
        print("REFUSING: ANALYSIS_MANIFEST.sha256 is missing.")
        sys.exit(3)
    for line in manifest.read_text().splitlines():
        if not line.strip():
            continue
        want, fname = line.split(None, 1)
        fname = fname.strip()
        got = hashlib.sha256(Path(fname).read_bytes()).hexdigest()
        if got != want:
            print(f"REFUSING: {fname} does not match the frozen analysis "
                  f"manifest.\n  frozen {want}\n  actual {got}")
            sys.exit(3)
    return art


AXES = ("frames", "ws_ratio", "nonevict", "load", "spec_share", "slack", "seed")


def mandatory_conditional_report(rows):
    """PRINTED UNCONDITIONALLY. Not optional, not on request.

    ROOT CAUSE THIS EXISTS TO PREVENT: the first analysis reported a whole-grid
    median and one by-load breakdown. It never conditioned on `frames`, which
    was the axis that mattered. A marginal over a helping regime (+3%) and a
    harming regime (-3%) averages to nothing, and that nothing was reported as
    the finding. If the tool prints every axis, no axis can be skipped.
    """
    import statistics as st
    def sp(r):
        o = r.get("offered") or 0
        return (r.get("on_time", 0) / o) if o else None

    for base in BASELINES:                      # BOTH baselines, always
        per_axis = {a: collections.defaultdict(list) for a in AXES}
        for row in rows:
            R = {k: (v or {}).get("summary", v) for k, v in row["rows"].items()}
            c, b = R.get(CANDIDATE), R.get(base)
            if not c or not b:
                continue
            cs, bs = sp(c), sp(b)
            if cs is None or not bs:
                continue
            g = (cs - bs) / bs * 100
            for a in AXES:
                per_axis[a][row["cfg"][a]].append(g)
        print(f"\n  CONDITIONAL MEDIANS, {CANDIDATE} vs {base}")
        for a in AXES:
            cells = sorted(per_axis[a])
            meds = [f"{v}:{st.median(per_axis[a][v]):+.2f}" for v in cells]
            spread = (max(st.median(per_axis[a][v]) for v in cells)
                      - min(st.median(per_axis[a][v]) for v in cells)) if cells else 0
            flag = "  <-- LARGE SPREAD, this axis conditions the result" if spread >= 1.0 else ""
            print(f"    {a:<11} {'  '.join(meds)}{flag}")


def near_miss_report(cells, passing):
    """PRINTED WHENEVER regions == 0. A zero result must arrive with its own
    margin analysis, or the reader cannot tell 'no effect' from 'missed by one
    seed'. The first analysis reported zero regions and stopped."""
    print("\n  NEAR MISSES (a zero verdict must show its margin)")
    near = []
    for cell, by_seed in cells.items():
        _, winners, _ = cell_passes(by_seed)
        if winners:
            near.append((len(winners), cell, sorted(winners)))
    near.sort(reverse=True)
    if not near:
        print("    no cell had ANY passing seed. The result is unambiguous.")
        return
    print(f"    cells with >=1 passing seed : {len(near)}")
    print(f"    cells with >=2 passing seeds: {sum(1 for n,_,_ in near if n >= 2)}")
    print(f"    cells with >=3 passing seeds: {sum(1 for n,_,_ in near if n >= 3)}"
          f"   (the gate needs {SEEDS_MIN})")
    print("    top 8 by passing-seed count:")
    for n, cell, seeds in near[:8]:
        print(f"      {n}/5 seeds {seeds}  frames={cell[0]} ws={cell[1]} "
              f"ne={cell[2]} spec={cell[3]} slack={cell[4]} load={cell[5]}")
    axes = collections.defaultdict(list)
    for n, cell, seeds in near:
        axes[cell[:5]].append((cell[5], seeds))
    adj = [(k, v) for k, v in axes.items() if len(v) >= 2]
    print(f"    axis-groups with passing cells at >=2 loads: {len(adj)}")
    for k, v in adj[:5]:
        loads = sorted(x[0] for x in v)
        inter = set.intersection(*[set(x[1]) for x in v])
        print(f"      frames={k[0]} ws={k[1]} ne={k[2]} spec={k[3]} slack={k[4]}"
              f"  loads={loads}  region-wide shared seeds={sorted(inter)} "
              f"(need {SEEDS_MIN})")


def main(run_dir: Path) -> int:
    art = load_gate(run_dir)
    status = art["audit_status"]
    if status == "FAIL":
        print("OUTCOME: RUN_INVALID")
        print(f"  {OUTCOME_MEANING['RUN_INVALID']}")
        return OUTCOME_EXIT["RUN_INVALID"]

    rows = [json.loads(l) for l in
            (run_dir / "checkpoints.jsonl").read_text().splitlines() if l.strip()]
    cells = collections.defaultdict(dict)
    for r in rows:
        c = r["cfg"]
        cells[(c["frames"], c["ws_ratio"], c["nonevict"],
               c["spec_share"], c["slack"], c["load"])][c["seed"]] = {
            pol: (v or {}).get("summary", v) for pol, v in r["rows"].items()}

    passing, degen = {}, 0
    for cell, by_seed in cells.items():
        ok, winners, d = cell_passes(by_seed)
        degen += d
        if ok:
            passing[cell] = winners

    regions = build_regions(passing)

    mandatory_conditional_report(rows)
    if not regions:
        near_miss_report(cells, passing)

    prov = (status == "INDETERMINATE_COHORT_IDENTITY")
    label = "THRESHOLD-MATCHING PROVISIONAL " if prov else "QUALIFYING "
    print(f"audit_status           : {status}")
    print(f"cells evaluated        : {len(cells)}")
    print(f"degenerate seed-cells  : {degen}  (|E| == 0, cannot qualify)")
    print(f"cells passing >={SEEDS_MIN}/{SEEDS_OF}   : {len(passing)}")
    print(f"{label}REGIONS: {len(regions)}")
    for axes, loads, seeds in sorted(regions):
        print(f"  frames={axes[0]} ws={axes[1]} ne={axes[2]} spec={axes[3]} "
              f"slack={axes[4]}  loads={loads}  shared_seeds={seeds}")
    print()
    fields = outcome_fields(status, len(regions))
    outcome = fields["outcome"]
    print(f"OUTCOME: {outcome}")
    print(f"  branch_closed={fields['branch_closed']} "
          f"confirmation_required={fields['confirmation_required']} "
          f"rtl_authorized={fields['rtl_authorized']} "
          f"interpretation_permitted={fields['interpretation_permitted']}")
    print(f"  {OUTCOME_MEANING[outcome]}")
    print()
    print("GO_TO_RTL_V1 is NOT issued here under any outcome. Only a successful "
          "FRESH-SEED CONFIRMATION can produce it.")
    return OUTCOME_EXIT[outcome]


if __name__ == "__main__":
    rid = sys.argv[1] if len(sys.argv) > 1 else Path(".sweep_b_runid").read_text().strip()
    raise SystemExit(main(Path("runs") / rid))
