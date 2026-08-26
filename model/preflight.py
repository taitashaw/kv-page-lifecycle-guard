#!/usr/bin/env python3
"""PREFLIGHT VALIDITY GATE. Must pass before any result may be interpreted.

Every check here would have BLOCKED the Sweep B interpretation on 2026-08-24.
None of them is a statistic. They are all preconditions: questions about whether
the experiment measured what its author claimed, which is the class of question
that was never asked.

The failure being engineered against, stated once:
  the analyst reported what a tool handed him and never checked whether the tool
  was measuring what he claimed.

Usage:  python3 preflight.py <run_id>
Exit 0 only if every check passes. compute_verdict.py refuses without the
artifact this writes.
"""
from __future__ import annotations

import collections
import hashlib
import json
import re
import sys
from pathlib import Path

MIN_ENGAGEMENT_PCT = 20.0     # the mechanism must act in at least this share
CANDIDATE = "integrated"
ENGAGE_KEY = "feasible_until_lifecycle"

FAILS: list[str] = []
NOTES: list[str] = []


def bad(code: str, msg: str) -> None:
    FAILS.append(f"{code}: {msg}")
    print(f"  BLOCK  [{code}] {msg}")


def good(msg: str) -> None:
    print(f"  ok     {msg}")


def strict(d: dict, *path):
    """Field access that RAISES instead of defaulting.

    `.get(k, 0)` silently fabricates data. That is how a wrong key path nearly
    became a published '0% engagement' figure. If a field is absent the
    experiment is not what the reader thinks it is, and that must stop the run.
    """
    cur = d
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            raise KeyError("missing field: " + ".".join(map(str, path)))
        cur = cur[k]
    return cur


# --------------------------------------------------------------- C1 distinct arms

def c1_arms_distinct_in_data(rows) -> None:
    """Two arms that produce identical rows are ONE arm. A duplicated baseline
    does not look like an error in a per-policy table; it looks like agreement."""
    pols = sorted(rows[0]["rows"].keys())
    ident = collections.Counter()
    for r in rows:
        R = r["rows"]
        for i, a in enumerate(pols):
            for b in pols[i + 1:]:
                # compare BEHAVIOUR only. policy_s is per-run wall time and
                # differs even for identical policies; including it made this
                # check silently pass on a genuine duplicate.
                ra = (R[a].get("summary"), R[a].get("annotations"),
                      R[a].get("status"), R[a].get("escaped"))
                rb = (R[b].get("summary"), R[b].get("annotations"),
                      R[b].get("status"), R[b].get("escaped"))
                ra = ({k: v for k, v in (ra[0] or {}).items() if k != "policy"},) + ra[1:]
                rb = ({k: v for k, v in (rb[0] or {}).items() if k != "policy"},) + rb[1:]
                if ra == rb:
                    ident[(a, b)] += 1
    n = len(rows)
    dupes = [(p, c) for p, c in ident.items() if c == n]
    if dupes:
        for (a, b), c in dupes:
            bad("C1", f"{a} and {b} are IDENTICAL in {c}/{n} runs. "
                      f"They are one arm, not two.")
    else:
        good(f"all {len(pols)} arms produce distinct rows somewhere in the grid")


# ------------------------------------------------------- C2 distinct source bodies

def c2_arms_distinct_in_source(src: Path) -> None:
    """Catch the duplicate BEFORE it costs a sweep. Source-level, so it can run
    with no data at all."""
    if not src.exists():
        bad("C2", f"{src} not found, cannot verify arm sources differ")
        return
    s = src.read_text()
    bodies = {}
    for m in re.finditer(r"class (\w+)\(Policy\):(.*?)(?=\nclass |\nALL_POLICIES)", s, re.S):
        fn = re.search(r"def feasible.*?(?=\n\n|\Z)", m.group(2), re.S)
        if fn:
            bodies[m.group(1)] = re.sub(r"\s+", " ", fn.group(0)).strip()
    inv = collections.defaultdict(list)
    for k, v in bodies.items():
        inv[v].append(k)
    clones = [v for v in inv.values() if len(v) > 1]
    if clones:
        for c in clones:
            bad("C2", f"identical feasible() bodies in source: {', '.join(c)}")
    else:
        good(f"all {len(bodies)} policy feasible() bodies differ in source")


# ------------------------------------------------------------- C3 mechanism acts

def c3_mechanism_engaged(rows) -> None:
    """A policy that never acts differently is not under test. If the
    distinguishing mechanism fires rarely, the grid measured something else."""
    eng = 0
    for r in rows:
        try:
            a = strict(r, "rows", CANDIDATE, "annotations")
        except KeyError as e:
            bad("C3", f"{e}. Cannot establish engagement; refusing to assume 0.")
            return
        if a.get(ENGAGE_KEY, 0) > 0:
            eng += 1
    pct = 100.0 * eng / len(rows)
    if pct < MIN_ENGAGEMENT_PCT:
        bad("C3", f"{CANDIDATE} mechanism engaged in only {eng}/{len(rows)} "
                  f"= {pct:.2f}% of runs (need >= {MIN_ENGAGEMENT_PCT}%). "
                  f"The grid mostly measured a policy that was doing nothing.")
    else:
        good(f"mechanism engaged in {pct:.1f}% of runs")


# ------------------------------------------ C4 effect attributable to the mechanism

def c4_effect_attribution(rows, baseline) -> None:
    """An effect that is the same with the mechanism on and off is not the
    mechanism's effect. This is the check that kills a false attribution."""
    import statistics as st
    on, off = [], []
    for r in rows:
        try:
            a = strict(r, "rows", CANDIDATE, "annotations")
            c = strict(r, "rows", CANDIDATE, "summary")
            b = strict(r, "rows", baseline, "summary")
        except KeyError as e:
            bad("C4", str(e)); return
        if not b.get("offered") or not b.get("on_time"):
            continue
        cs = c["on_time"] / c["offered"]
        bs = b["on_time"] / b["offered"]
        g = (cs - bs) / bs * 100
        (on if a.get(ENGAGE_KEY, 0) > 0 else off).append(g)
    if not on or not off:
        NOTES.append("C4: one arm empty, attribution not testable")
        return
    d = st.median(on) - st.median(off)
    if abs(d) < 0.5:
        bad("C4", f"median gain is {st.median(on):+.2f}% with the mechanism "
                  f"engaged and {st.median(off):+.2f}% without. Difference "
                  f"{d:+.2f}%. Any observed effect is NOT attributable to the "
                  f"mechanism under test.")
    else:
        good(f"engaged {st.median(on):+.2f}% vs not-engaged {st.median(off):+.2f}%, "
             f"difference {d:+.2f}%")


# ----------------------------------------------------------- C5 ranked levels

def c5_ranked_levels(rows) -> None:
    """Gains hide levels. '-0.50% relative' and 'eighth of nine' are the same
    fact, and only one of them can be misread."""
    import statistics as st
    acc = collections.defaultdict(list)
    for r in rows:
        for p, v in r["rows"].items():
            s = v.get("summary") or {}
            if s.get("offered"):
                acc[p].append(s.get("on_time", 0) / s["offered"])
    rank = sorted(((p, st.mean(v)) for p, v in acc.items()), key=lambda x: -x[1])
    print("         ranked mean S_p:")
    for i, (p, m) in enumerate(rank, 1):
        mark = "  <-- CANDIDATE" if p == CANDIDATE else ""
        print(f"           {i}. {p:<32}{m:.6f}{mark}")
    pos = [i for i, (p, _) in enumerate(rank, 1) if p == CANDIDATE][0]
    if pos > len(rank) / 2:
        bad("C5", f"{CANDIDATE} ranks {pos} of {len(rank)} on the primary "
                  f"metric. Any narrative of a small relative deficit is "
                  f"misleading.")
    else:
        good(f"{CANDIDATE} ranks {pos} of {len(rank)}")


# ------------------------------------------------------------ C6 claim linter

CHARACTERISATIONS = ("noise", "scattered", "isolated", "negligible",
                     "essentially", "roughly the same", "no effect")


def c6_claim_linter(docs) -> None:
    """A characterisation without a computation is an opinion. Every one of
    today's wrong claims was a word, not a number."""
    hits = []
    for d in docs:
        if not d.exists():
            continue
        for i, line in enumerate(d.read_text().splitlines(), 1):
            low = line.lower()
            for w in CHARACTERISATIONS:
                if w in low and not re.search(r"\d", line):
                    hits.append(f"{d.name}:{i} '{w}' with no number on the line")
    if hits:
        for h in hits[:8]:
            bad("C6", h)
    else:
        good("no unquantified characterisations found in the reports")


def main(run_id: str) -> int:
    root = Path(__file__).resolve().parent
    rd = root / "runs" / run_id
    rows = [json.loads(l) for l in (rd / "checkpoints.jsonl").read_text().splitlines() if l.strip()]
    print(f"\nPREFLIGHT VALIDITY GATE  run={run_id}  rows={len(rows)}\n")
    c2_arms_distinct_in_source(root / "gm" / "policies.py")
    c1_arms_distinct_in_data(rows)
    c3_mechanism_engaged(rows)
    c4_effect_attribution(rows, "tuned_axi_qos")
    c5_ranked_levels(rows)
    c6_claim_linter([root / "SWEEP_B_RESULT.md", root / "SWEEP_B_POSTHOC_REGION.md"])

    art = {"run_id": run_id, "preflight_passed": not FAILS,
           "failures": FAILS, "notes": NOTES}
    (rd / "preflight.json").write_text(json.dumps(art, indent=2))
    print()
    if FAILS:
        print(f"PREFLIGHT FAILED: {len(FAILS)} blocking checks.")
        print("The experiment did not measure what its author claimed.")
        print("NO RESULT MAY BE INTERPRETED until these are fixed.")
        return 1
    print("PREFLIGHT PASSED. Results may be interpreted.")
    return 0


if __name__ == "__main__":
    rid = sys.argv[1] if len(sys.argv) > 1 else Path(".sweep_b_runid").read_text().strip()
    raise SystemExit(main(rid))
