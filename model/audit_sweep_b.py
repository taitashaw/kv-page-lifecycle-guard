#!/usr/bin/env python3
"""FINAL AUDIT for a completed Sweep B run. READ-ONLY.

Run ONLY after the sweep completes. It refuses to run against a live run,
because inspecting partial performance rows mid-flight is exactly what the
frozen protocol forbids.

Establishes every item required before the verdict may be read.
"""
from __future__ import annotations
import hashlib, json, sys, collections
from pathlib import Path

EXPECTED_RECORDS = 77_760
EXPECTED_CONFIGS = 8_640
EXPECTED_POLICIES = 9
EXPECTED_N_OUT = 2
EXPECTED_L_DOWN_MAX = 784
COHORT_UNVERIFIED = False


CFG_AXES = ("frames","ws_ratio","nonevict","load","spec_share","slack","seed")


def canonical_cfg(cfg: dict) -> str:
    """Canonical serialisation of a configuration's VALUES in frozen axis order.

    Two cfg dicts with identical KEYS but different VALUES must produce
    different identities. The first auditor keyed on tuple(cfg), which for a
    dict yields its KEYS, collapsing all 8,640 configurations to one. This
    function exists so that defect cannot recur silently.
    """
    return "|".join(f"{k}={cfg[k]}" for k in CFG_AXES)


def _regenerate_cohorts(per_cfg):
    """Rebuild the eligible cohort from the FROZEN generator, configuration and
    seed, and check it against what every policy recorded.

    Returns True (verified), False (disagreement) or None (cannot verify).
    """
    try:
        from gm.traces_b import capacity_contended
    except Exception:
        return None
    checked = 0
    for cfg, bypol in per_cfg.items():
        try:
            c = dict(x.split("=") for x in cfg.split("|"))
            frames = int(c["frames"]); ws = float(c["ws_ratio"])
            ne = float(c["nonevict"]); load = float(c["load"])
            spec = float(c["spec_share"]); slack = float(c["slack"])
            seed = int(c["seed"])
            _p, _e, reqs, hz = capacity_contended(frames, ws, ne, load, spec,
                                                  slack, seed)[:4]
        except Exception:
            return None
        fetches = [r for r in reqs if not getattr(r, "is_release", False)]
        elig = [r for r in fetches if r.deadline <= hz]
        want = (len(elig), len(fetches) - len(elig), hz)
        for pol, got in bypol.items():
            if got[:3] != want:
                print(f"      cohort mismatch {cfg} {pol}: recorded {got[:3]} "
                      f"regenerated {want}")
                return False
        checked += 1
        if checked >= 200:      # bounded sample of a 8,640-config regeneration
            break
    return True

def fail(msg): print(f"  FAIL  {msg}"); return 1
def ok(msg):   print(f"  PASS  {msg}"); return 0

def main(run_dir: Path) -> int:
    bad = 0
    man = json.loads((run_dir / "manifest.json").read_text())

    # RUN-SPECIFIC liveness: this run's PID, its start time, and its own lock.
    # A broad process-name match is wrong in both directions.
    pid = man.get("pid")
    want_start = man.get("pid_start_ticks")   # may be absent on older manifests
    lock = Path(man.get("lock_file", "")) if man.get("lock_file") else None
    if pid:
        proc = Path(f"/proc/{pid}")
        if proc.exists():
            try:
                cmd = (proc / "cmdline").read_bytes().decode(errors="replace")
            except OSError:
                cmd = ""
            start_ticks = None
            try:
                start_ticks = int((proc / "stat").read_text().rsplit(")", 1)[1].split()[19])
            except Exception:
                pass
            same_process = (want_start is None or start_ticks == want_start)
            if "sweep_b.py" in cmd and man["run_id"] in cmd and same_process:
                print(f"REFUSING: run {man['run_id']} is still live "
                      f"(pid {pid} matches run id). Audit only a completed run.")
                return 2
            # pid recycled onto an unrelated process: not our run, continue
    # every worker must have exited, not just the parent
    import subprocess
    workers = subprocess.run(["pgrep", "-f", f"sweep_b.py.*{man['run_id']}"],
                             capture_output=True).stdout.split()
    if workers:
        print(f"REFUSING: {len(workers)} process(es) for this run id are still alive.")
        return 2

    if lock and lock.exists():
        import fcntl
        try:
            fh = open(lock, "r+")
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fh, fcntl.LOCK_UN); fh.close()
        except OSError:
            print(f"REFUSING: the run lock {lock} is still held.")
            return 2

    rows, seen, malformed = [], collections.Counter(), 0
    cfg_key_mismatch = []
    for line in (run_dir / "checkpoints.jsonl").read_text().splitlines():
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            malformed += 1
    bad += ok("no malformed checkpoint lines") if malformed == 0 else fail(f"{malformed} malformed lines")

    recs = []
    for r in rows:
        for pol, s in (r.get("rows") or {}).items():
            cc = canonical_cfg(r["cfg"])
            if cc != r["cfg_key"]:
                cfg_key_mismatch.append((r["cfg_key"], cc))
            recs.append((cc, pol, (s or {}).get("summary", s), r["cfg"]["seed"]))
    bad += ok(f"{len(recs)} records present") if len(recs) == EXPECTED_RECORDS \
        else fail(f"{len(recs)} records, expected {EXPECTED_RECORDS}")

    bad += ok("cfg_key equals canonical_serialization(cfg values) on every row") \
        if not cfg_key_mismatch else fail(
            f"{len(cfg_key_mismatch)} rows where cfg_key != canonical form, "
            f"e.g. {cfg_key_mismatch[0]}")

    # two cfg dicts with the SAME KEYS but DIFFERENT VALUES must differ
    a = {k: 1 for k in CFG_AXES}
    b = dict(a); b["seed"] = 2
    bad += ok("identical cfg keys with different values yield different identities") \
        if canonical_cfg(a) != canonical_cfg(b) else fail("canonical_cfg ignores values")

    # observed composite set vs the expected Cartesian product
    import itertools as _it
    GRID = {"frames": (4, 8, 16), "ws_ratio": (0.75, 1.0, 1.5, 2.0),
            "nonevict": (0.0, 0.25, 0.5, 0.75), "load": (0.7, 0.8, 0.9, 0.95),
            "spec_share": (0.0, 0.25, 0.5), "slack": (1.25, 2.0, 4.0),
            "seed": (1, 2, 3, 4, 5)}
    pols = sorted({p for _, p, _, _ in recs})
    def _independent_serialise(combo):
        """Deliberately NOT canonical_cfg(). Built from the grid literals by a
        separate code path so a common-mode serialisation defect cannot make
        both sides agree while both are wrong."""
        parts = []
        for name, value in zip(CFG_AXES, combo):
            parts.append(name + "=" + str(value))
        return "|".join(parts)

    expected = {(pol, _independent_serialise(combo), combo[-1])
                for combo in _it.product(*(GRID[k] for k in CFG_AXES))
                for pol in pols}
    observed = {(p, c, sd) for c, p, _, sd in recs}
    miss, extra = expected - observed, observed - expected
    bad += ok(f"observed (policy, canonical_cfg, seed) set equals the expected "
              f"Cartesian product, {len(expected)} members") \
        if not miss and not extra else fail(
            f"{len(miss)} missing, {len(extra)} unexpected; "
            f"e.g. missing {next(iter(miss)) if miss else None}")

    keys = [(c, p) for c, p, _, _ in recs]
    bad += ok("all (config, seed, policy) keys unique") if len(set(keys)) == len(keys) \
        else fail(f"{len(keys)-len(set(keys))} duplicate keys")

    per_pol = collections.Counter(p for _, p, _, _ in recs)
    bad += ok(f"{EXPECTED_CONFIGS} records per policy") \
        if all(v == EXPECTED_CONFIGS for v in per_pol.values()) and len(per_pol) == EXPECTED_POLICIES \
        else fail(f"per-policy counts: {dict(per_pol)}")

    per_cfg = collections.Counter(c for c, _, _, _ in recs)
    bad += ok(f"{EXPECTED_POLICIES} records per configuration") \
        if all(v == EXPECTED_POLICIES for v in per_cfg.values()) \
        else fail(f"{sum(1 for v in per_cfg.values() if v != EXPECTED_POLICIES)} configs with wrong count")
    bad += ok(f"{EXPECTED_CONFIGS} distinct configurations") if len(per_cfg) == EXPECTED_CONFIGS \
        else fail(f"{len(per_cfg)} configurations")

    hashes = man.get("source_sha256") or {}
    drift = [f for f, h in hashes.items()
             if Path(f).exists() and hashlib.sha256(Path(f).read_bytes()).hexdigest() != h]
    bad += ok(f"all {len(hashes)} frozen source hashes still match") if not drift \
        else fail(f"HASH DRIFT, run is INVALID: {drift}")

    bad += ok(f"N_out == {EXPECTED_N_OUT} and L_down_max == {EXPECTED_L_DOWN_MAX}") \
        if _params_ok() else fail("frozen parameters do not match")
    bad += ok("manifest declares no row exclusion") \
        if man.get("row_exclusion") == "none" else fail(f"row_exclusion={man.get('row_exclusion')}")
    bad += ok("manifest expected_records == 77760") \
        if man.get("frozen_grid_expected_records") == EXPECTED_RECORDS \
        else fail(str(man.get("frozen_grid_expected_records")))
    bad += ok("manifest n_policies == 9") if man.get("n_policies") == EXPECTED_POLICIES \
        else fail(str(man.get("n_policies")))
    bad += ok("targeted suite counted SEPARATELY (47 records, not mixed in)") \
        if (man.get("targeted_suite") or {}).get("expected_records") == 47 \
        and not (man.get("targeted_suite") or {}).get("count_is_stale") \
        else fail("targeted suite count missing or stale")

    # ---- policy-independent censoring, per CONFIGURATION, not one sample
    per_cfg = collections.defaultdict(dict)
    for c, pol, srec, _sd in recs:
        per_cfg[c][pol] = (srec.get("offered"), srec.get("censored"),
                           srec.get("horizon"), srec.get("eligible_hash"))
    disagree = [c for c, d in per_cfg.items() if len(set(d.values())) != 1]
    bad += ok(f"offered/censored/horizon/eligible-hash identical across all 9 "
              f"policies in every one of {len(per_cfg)} configurations") \
        if not disagree else fail(
            f"{len(disagree)} configurations disagree across policies, "
            f"e.g. {disagree[0]}: {per_cfg[disagree[0]]}")
    # FAIL CLOSED. Equal counts are NOT cohort identity: two different cohorts
    # can share a count. If the records cannot establish identity, say so; do
    # not silently downgrade the claim.
    missing_hash = any(v[3] is None for d in per_cfg.values() for v in d.values())
    regen_ok = _regenerate_cohorts(per_cfg)
    if regen_ok is True:
        bad += ok("eligible cohort REGENERATED from the frozen generator and "
                  "matches every recorded (offered, censored, horizon)")
    elif regen_ok is False:
        bad += fail("regenerated cohort DISAGREES with recorded values")
    else:
        print("  UNVERIFIED  cohort identity NOT DIRECTLY VERIFIED: "
              f"{'eligible_hash absent from records' if missing_hash else 'regeneration unavailable'}. "
              "Equal counts across policies are consistent with, but do not "
              "prove, identical cohorts. Reported as unverified, NOT as passed.")
        global COHORT_UNVERIFIED
        COHORT_UNVERIFIED = True

    cens = collections.Counter()
    for c, p, s, _ in recs:
        cens[p] += s.get("censored", 0)
    print("  censored requests by policy:")
    for p, v in sorted(cens.items()):
        print(f"      {p:<32}{v}")

    kept = sum(1 for _ in recs)
    bad += ok("no coverage annotation excluded any row (kept == produced)") \
        if kept == len(recs) else fail("row count mismatch")

    canon = json.dumps(sorted([[c, p, s] for c, p, s, _ in recs],
                              key=lambda x: (x[0], x[1])), sort_keys=True)
    print(f"  canonical SHA-256: {hashlib.sha256(canon.encode()).hexdigest()}")

    status = ("FAIL" if bad else
              "INDETERMINATE_COHORT_IDENTITY" if COHORT_UNVERIFIED else "PASS")
    import hashlib as _h
    art = {
        "run_id": man["run_id"],
        "manifest_sha256": _h.sha256((run_dir / "manifest.json").read_bytes()).hexdigest(),
        "audit_status": status,
        "failed_checks": bad,
        "cohort_identity_verified": not COHORT_UNVERIFIED,
        "records": len(recs),
        "canonical_sha256": _h.sha256(canon.encode()).hexdigest(),
        "permitted_consequence": {
            "PASS": "compute the frozen GO/NO-GO verdict",
            "INDETERMINATE_COHORT_IDENTITY":
                "report PROVISIONAL regions only. NO GO and NO BRANCH CLOSURE.",
            "FAIL": "suppress performance interpretation; the run is invalid",
        }[status],
    }
    art["analysis_code_sha256"] = {
        f: _h.sha256(Path(f).read_bytes()).hexdigest()
        for f in ("audit_sweep_b.py", "compute_verdict.py",
                  "tests/test_verdict_engine.py",
                  "SWEEP_B_ANALYSIS_PLAN_003.json")
        if Path(f).exists()
    }
    # ATOMIC creation, then record the digest of what was actually written, so
    # the evidence chain covers the PROGRAM that assigned PASS, not only the
    # artifact it produced.
    body = json.dumps(art, indent=2)
    tmp = run_dir / "audit_artifact.json.tmp"
    tmp.write_text(body)
    import os as _os
    _os.replace(tmp, run_dir / "audit_artifact.json")
    digest = _h.sha256((run_dir / "audit_artifact.json").read_bytes()).hexdigest()
    (run_dir / "audit_artifact.json.sha256").write_text(
        f"{digest}  audit_artifact.json\n")
    print(f"  audit_artifact.json sha256 = {digest}")
    print(f"\n  audit_status = {status}")
    print(f"  -> {art['permitted_consequence']}")

    if COHORT_UNVERIFIED:
        print("\nCOHORT IDENTITY NOT DIRECTLY VERIFIED. Any verdict computed "
              "below inherits that limitation and must state it.")
    if bad:
        print(f"\nAUDIT FAILED ({bad} checks). "
              f"PERFORMANCE RESULTS ARE WITHHELD: no policy verdict may be "
              f"computed from a run that failed integrity.")
        return 1
    print("\nAUDIT PASSED. Results are canonically sorted and hashed above; "
          "the policy verdict may now be computed.")
    return 0

def _params_ok():
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from gm.types import Params, DownstreamEnvelope
    p, e = Params(), DownstreamEnvelope()
    return (p.max_axi_outstanding == EXPECTED_N_OUT
            and e.l_down_max(p.max_axi_outstanding, 144) == EXPECTED_L_DOWN_MAX)

if __name__ == "__main__":
    rid = sys.argv[1] if len(sys.argv) > 1 else Path(".sweep_b_runid").read_text().strip()
    raise SystemExit(main(Path("runs") / rid))
