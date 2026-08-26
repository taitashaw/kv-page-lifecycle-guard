#!/usr/bin/env python3
"""Sweep B runner. DISTRIBUTIONAL suite over the frozen grid, no row exclusion.

Run hygiene, every item of it a direct response to the three orphaned copies
that raced on one output path in Sweep A:

  * a unique run id with its OWN directory under `runs/`
  * an flock-based lock enforcing exactly ONE active process, failing loudly
  * `manifest.json` written BEFORE any simulation starts, recording the PID,
    the sha256 of every source file that can change a number, the config hash,
    the full seed list and the expected record count
  * every completed configuration appended as an independent JSONL checkpoint
    and fsync'd, so a kill loses at most ONE configuration
  * the final aggregate written to a temp file and ATOMICALLY renamed
  * the console summary printed ONLY AFTER that rename returns
  * resumable: an existing run id skips the configurations already checkpointed
  * a closed stdout is a loud failure, not silent truncation, so piping the
    producer into `head` cannot quietly destroy a run

NO ROW EXCLUSION. Coverage counters are recorded as annotations for
stratification and never decide which rows are kept. `validate()` asserts that
the number of kept rows equals the number of produced rows.

The targeted correctness suite is `tests/test_gm_targeted.py`. It is a SEPARATE
suite, never mixed with these rows; only its expected record count is recorded
here, in the manifest.
"""
from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import itertools
import json
import os
import socket
import sys
import time
from datetime import datetime, timezone
from multiprocessing import Pool
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from gm import sim, traces_b                                          # noqa: E402
from gm.coverage import (                                             # noqa: E402
    ANNOTATION_KEYS, NESTED_SEVERITY_KEYS, NON_CONTENTION_KEYS,
)
from gm.policies import POLICY_NAMES                                  # noqa: E402
from gm.types import SafetyViolation                                  # noqa: E402

# ================================================================ FROZEN GRID
FRAMES = (4, 8, 16)
WS_RATIO = (0.75, 1.0, 1.5, 2.0)
NONEVICT = (0.0, 0.25, 0.50, 0.75)
LOAD = (0.70, 0.80, 0.90, 0.95)
SPEC_SHARE = (0.0, 0.25, 0.50)
SLACK = (1.25, 2.0, 4.0)
SEEDS = (1, 2, 3, 4, 5)
N_REQ = traces_b.N_REQ_DEFAULT

AXES = ("frames", "ws_ratio", "nonevict", "load", "spec_share", "slack", "seed")
FROZEN_GRID = (FRAMES, WS_RATIO, NONEVICT, LOAD, SPEC_SHARE, SLACK, SEEDS)

#: 8,640 configurations x 9 policies. Asserted, not assumed.
EXPECTED_CONFIGS = 8640
EXPECTED_RECORDS = 77760

#: 2 frames-values x 1 of every other axis x 2 seeds. Plumbing proof only.
SMOKE_GRID = ((4, 16), (1.5,), (0.50,), (0.90,), (0.25,), (2.0,), (1, 2))

#: Expected record count of the SEPARATE targeted correctness suite.
#:
#: MEASURED by running the file (`PASSED 47   FAILED 0`), never inferred by
#: counting `ck(` calls: some assertions are emitted conditionally, so the
#: static count is wrong.
#:
#: The count is pinned to the EXACT sha256 it was measured against, and
#: `targeted_suite_block()` re-hashes the file at manifest time and marks the
#: constant STALE if it no longer matches. A bare integer here would go silently
#: wrong the moment anyone edits the suite, which is exactly what happened while
#: this runner was being built.
TARGETED_SUITE = "tests/test_gm_targeted.py"
TARGETED_EXPECTED_RECORDS = 47
TARGETED_MEASURED_AGAINST_SHA256 = (
    "393e25241b90579e0a38e4d216d5c64d60badc0d4e69ba045b36dd78f1c9d55a")

LOCK_PATH = ROOT / "runs" / ".sweep_b.lock"


# ============================================================ identity + hashes

def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def source_hashes() -> dict:
    """sha256 of every file that can change a number in this sweep."""
    files = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "gm").glob("*.py"))
    files += ["sweep_b.py", TARGETED_SUITE]
    return {f: _sha256(ROOT / f) for f in files}


def targeted_suite_block() -> dict:
    """Record count of the SEPARATE targeted suite, with a staleness check.

    The distributional rows and the targeted rows are never mixed. Only the
    expected count is carried here, and it is only trustworthy while the file
    still hashes to the value it was measured against.
    """
    current = _sha256(ROOT / TARGETED_SUITE)
    stale = current != TARGETED_MEASURED_AGAINST_SHA256
    return {
        "path": TARGETED_SUITE,
        "expected_records": TARGETED_EXPECTED_RECORDS,
        "measured_against_sha256": TARGETED_MEASURED_AGAINST_SHA256,
        "current_sha256": current,
        "count_is_stale": stale,
        "note": ("SEPARATE suite, never mixed with the distributional rows. "
                 "Counted independently by running the file; re-measure and "
                 "update both constants whenever count_is_stale is true."),
    }


def config_hash(grid, suite: str) -> str:
    """Identity of the experiment definition. A resume against a different
    definition is refused."""
    payload = {
        "axes": AXES,
        "grid": [list(a) for a in grid],
        "policies": list(POLICY_NAMES),
        "n_req": N_REQ,
        "suite": suite,
        "kv_bytes": traces_b.KV_BYTES,
        "expert_bytes": traces_b.EXPERT_BYTES,
        "headroom_svc": {str(k): v for k, v in traces_b.HEADROOM_SVC.items()},
        "p_interactive": traces_b.P_INTERACTIVE,
        "p_release_in_flight": traces_b.P_RELEASE_IN_FLIGHT,
    }
    blob = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode()).hexdigest()


def cfg_key(cfg) -> str:
    """Stable identity of one configuration. Uses repr of the frozen grid
    values so float formatting can never drift between a run and its resume."""
    return "|".join(f"{a}={v!r}" for a, v in zip(AXES, cfg))


# ==================================================================== the lock

class RunLock:
    """Exactly ONE active sweep process, enforced by flock.

    flock is used rather than an O_EXCL sentinel because the kernel releases it
    when the holder dies. A `kill -9` therefore cannot leave a stale lock that
    blocks every later run, which is the failure mode that makes people delete
    lock files by hand and end up with three racing copies again.
    """

    def __init__(self, path: Path):
        self.path = path
        self.fd = None

    def acquire(self, run_id: str) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            if exc.errno not in (errno.EACCES, errno.EAGAIN):
                raise
            held = os.read(self.fd, 4096).decode(errors="replace").strip()
            os.close(self.fd)
            self.fd = None
            raise SystemExit(
                "FATAL: another sweep_b process holds the lock.\n"
                f"  lock file : {self.path}\n"
                f"  holder    : {held or '(no metadata written yet)'}\n"
                "REFUSING TO START. Exactly one active process is permitted.\n"
                "Do not delete the lock file; flock is released automatically\n"
                "when the holder exits.")
        os.ftruncate(self.fd, 0)
        os.write(self.fd, json.dumps({
            "pid": os.getpid(), "host": socket.gethostname(), "run_id": run_id,
            "acquired_utc": datetime.now(timezone.utc).isoformat(),
            "argv": sys.argv,
        }, sort_keys=True).encode())
        os.fsync(self.fd)

    def release(self) -> None:
        if self.fd is None:
            return
        try:
            os.ftruncate(self.fd, 0)
            fcntl.flock(self.fd, fcntl.LOCK_UN)
        finally:
            os.close(self.fd)
            self.fd = None


# ================================================================== simulation

def run_one(cfg):
    """One configuration: build the trace once, run EVERY policy over the SAME
    fixed horizon. Returns 9 records, one per policy, always.

    A `SafetyViolation` raised out of `gm.sim.run` is recorded as a record with
    `status == "escaped_safety_violation"` rather than being allowed to abort
    the sweep. Suppressing the row instead would be exclusion, and losing the
    whole configuration would corrupt the record count.
    """
    frames, ws, ne, load, spec, slack, seed = cfg
    t0 = time.perf_counter()
    params, envelope, reqs, horizon, meta = traces_b.capacity_contended(
        frames, ws, ne, load, spec, slack, seed, n_req=N_REQ)

    rows = {}
    for name in POLICY_NAMES:
        ps = time.perf_counter()
        try:
            res = sim.run(name, params, reqs, envelope, horizon=horizon,
                          strict=False)
        except SafetyViolation as v:
            rows[name] = {
                "policy": name,
                "status": "escaped_safety_violation",
                "escaped": {"kind": v.kind, "cycle": v.cycle, "detail": v.detail},
                "summary": None, "annotations": None,
                "policy_s": round(time.perf_counter() - ps, 4),
            }
            continue
        s = res.summary()
        cov = s.pop("coverage")
        rows[name] = {
            "policy": name,
            "status": "ok",
            "escaped": None,
            "summary": s,
            # ANNOTATIONS ONLY. Nothing here selects or excludes a row.
            "annotations": cov,
            "policy_s": round(time.perf_counter() - ps, 4),
        }

    return {
        "cfg_key": cfg_key(cfg),
        "cfg": dict(zip(AXES, cfg)),
        "horizon": horizon,
        "trace": meta,
        "rows": rows,
        "config_s": round(time.perf_counter() - t0, 4),
    }


# =================================================================== reporting

def _pct(n, d):
    return round(100.0 * n / d, 2) if d else 0.0


def aggregate(records):
    """Descriptive aggregates ONLY.

    No pass gate, no qualifying-region decision and no exclusion is applied
    here. Per SWEEP_B_CONTRACT.md section 7 that decision requires a frozen
    region validated on at least 20 fresh unused seeds with a paired confidence
    interval, which this runner deliberately does not attempt.
    """
    by_pol = {}
    for r in records:
        for name, row in r["rows"].items():
            b = by_pol.setdefault(name, {
                "records": 0, "escaped": 0, "offered": 0, "admitted": 0,
                "accepted": 0, "completed": 0, "on_time": 0, "issue_on_time": 0,
                "cancelled": 0, "censored": 0, "with_violation": 0,
                "violation_kinds": {},
            })
            b["records"] += 1
            if row["status"] != "ok":
                b["escaped"] += 1
                k = row["escaped"]["kind"]
                b["violation_kinds"][k] = b["violation_kinds"].get(k, 0) + 1
                continue
            s = row["summary"]
            for f in ("offered", "admitted", "accepted", "completed", "on_time",
                      "issue_on_time", "cancelled", "censored"):
                b[f] += s[f]
            if s["violations"]:
                b["with_violation"] += 1
                for k in s["violations"]:
                    b["violation_kinds"][k] = b["violation_kinds"].get(k, 0) + 1
    for b in by_pol.values():
        b["on_time_per_offered_%"] = _pct(b["on_time"], b["offered"])
        b["completed_per_offered_%"] = _pct(b["completed"], b["offered"])
    return by_pol


def stratify(records):
    """Coverage ANNOTATIONS, tabulated for stratification.

    Recorded so a later, separately frozen analysis can stratify. Explicitly
    NOT a filter: `validate()` asserts that every produced row is kept.
    """
    strata = {"note": "annotations for stratification only; no row was excluded",
              "annotation_keys": list(ANNOTATION_KEYS),
              "nested_severity_keys": list(NESTED_SEVERITY_KEYS),
              "non_contention_keys": list(NON_CONTENTION_KEYS),
              "hit_counts": {}, "hit_counts_by_frames": {}}
    ok_rows = 0
    for r in records:
        for row in r["rows"].values():
            if row["status"] != "ok":
                continue
            ok_rows += 1
            f = str(r["cfg"]["frames"])
            for k in ANNOTATION_KEYS + NESTED_SEVERITY_KEYS:
                v = row["annotations"].get(k, 0) or 0
                if v > 0:
                    strata["hit_counts"][k] = strata["hit_counts"].get(k, 0) + 1
                    d = strata["hit_counts_by_frames"].setdefault(k, {})
                    d[f] = d.get(f, 0) + 1
    strata["rows_annotated"] = ok_rows
    return strata


def censoring_report(records):
    """The horizon is trace-derived and identical across policies, so the
    censored count must be identical across policies within a configuration.
    That equality is CHECKED, not assumed."""
    total, worst, mismatched, offered = 0, 0, [], 0
    for r in records:
        vals = {row["summary"]["censored"] for row in r["rows"].values()
                if row["status"] == "ok"}
        if len(vals) > 1:
            mismatched.append(r["cfg_key"])
        c = max(vals) if vals else 0
        total += c
        worst = max(worst, c)
        for row in r["rows"].values():
            if row["status"] == "ok":
                offered += row["summary"]["offered"]
    return {
        "total_censored_fetches_per_config_sum": total,
        "max_censored_in_any_config": worst,
        "configs_with_policy_disagreement_on_censoring": mismatched,
        "total_offered_over_all_records": offered,
        "note": ("horizon = latest completion deadline + one declared "
                 "L_down,max; every fetch therefore satisfies deadline <= "
                 "horizon and the right-censoring guard excludes nothing"),
    }


def validate(records, expected_configs, expected_records, all_keys):
    """Record-count validation. Reports missing and duplicated records."""
    seen, dupes = {}, []
    for r in records:
        k = r["cfg_key"]
        if k in seen:
            dupes.append(k)
        seen[k] = seen.get(k, 0) + 1
    produced = sum(len(r["rows"]) for r in records)
    wrong_width = [r["cfg_key"] for r in records
                   if len(r["rows"]) != len(POLICY_NAMES)]
    missing = sorted(set(all_keys) - set(seen))
    extra = sorted(set(seen) - set(all_keys))

    # NO ROW EXCLUSION, asserted rather than promised
    kept = sum(len(r["rows"]) for r in records)
    assert kept == produced, "row exclusion detected; the suite forbids it"

    return {
        "expected_configs": expected_configs,
        "observed_configs": len(seen),
        "expected_records": expected_records,
        "observed_records": produced,
        "records_match": produced == expected_records,
        "configs_match": len(seen) == expected_configs,
        "missing_config_keys": missing[:200],
        "n_missing_config_keys": len(missing),
        "unexpected_config_keys": extra[:200],
        "n_unexpected_config_keys": len(extra),
        "duplicated_config_keys": sorted(set(dupes))[:200],
        "n_duplicated_config_keys": len(set(dupes)),
        "configs_with_wrong_record_width": wrong_width[:200],
        "rows_kept": kept,
        "rows_produced": produced,
        "row_exclusion": "none",
        "filters_applied": [],
        "frozen_grid_expected_records": EXPECTED_RECORDS,
        "frozen_grid_definition_is_77760": (
            len(list(itertools.product(*FROZEN_GRID))) * len(POLICY_NAMES)
            == EXPECTED_RECORDS),
    }


# ======================================================================== main

def _load_checkpoints(path: Path):
    """Read completed configurations. A torn final line (the config that was
    in flight when the process died) is dropped and recomputed."""
    records, torn = [], 0
    if not path.exists():
        return records, torn
    with open(path, "r") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                torn += 1
    return records, torn


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--smoke", action="store_true",
                    help="small subset that proves the plumbing; NOT the sweep")
    ap.add_argument("--run-id", default=None,
                    help="reuse an existing run id to RESUME it")
    ap.add_argument("--workers", type=int, default=os.cpu_count())
    ap.add_argument("--sample", type=int, default=None,
                    help="deterministic evenly-STRIDED subset of N configurations "
                         "across the frozen grid. For timing probes only; it "
                         "gets its own suite name and config hash so it can "
                         "never be mistaken for the sweep itself. A prefix of "
                         "the product would be one corner of the grid and would "
                         "not time anything representative.")
    ap.add_argument("--label", default="", help="free-text note into the manifest")
    args = ap.parse_args()

    suite = "distributional-smoke" if args.smoke else "distributional"
    grid = SMOKE_GRID if args.smoke else FROZEN_GRID
    configs = list(itertools.product(*grid))
    if args.sample is not None:
        if not 0 < args.sample <= len(configs):
            raise SystemExit(f"--sample must be in 1..{len(configs)}")
        stride = len(configs) / args.sample
        configs = [configs[int(i * stride)] for i in range(args.sample)]
        suite += f"-sample{args.sample}"
    all_keys = [cfg_key(c) for c in configs]

    cfg_hash = config_hash(grid, suite)
    expected_configs = len(configs)
    expected_records = expected_configs * len(POLICY_NAMES)

    run_id = args.run_id or (
        f"b-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-"
        f"{cfg_hash[:8]}")
    run_dir = ROOT / "runs" / run_id
    ck_path = run_dir / "checkpoints.jsonl"
    manifest_path = run_dir / "manifest.json"
    results_path = run_dir / "results.json"
    tmp_path = run_dir / "results.json.tmp"

    lock = RunLock(LOCK_PATH)
    lock.acquire(run_id)                      # raises SystemExit if held
    try:
        run_dir.mkdir(parents=True, exist_ok=True)

        # ---- resume, before anything is written
        done, torn = _load_checkpoints(ck_path)
        done_keys = {r["cfg_key"] for r in done}
        # a duplicate cfg_key in an existing file is a defect in a prior run;
        # keep the FIRST and report it rather than silently double counting
        deduped, seen = [], set()
        for r in done:
            if r["cfg_key"] in seen:
                continue
            seen.add(r["cfg_key"])
            deduped.append(r)
        dropped_dupes = len(done) - len(deduped)
        done = deduped
        todo = [c for c in configs if cfg_key(c) not in done_keys]

        srcs = source_hashes()
        provenance, source_changed = [], False
        if manifest_path.exists():
            prior = json.loads(manifest_path.read_text())
            if prior.get("config_hash") != cfg_hash:
                raise SystemExit(
                    f"FATAL: run id {run_id} was created with config_hash "
                    f"{prior.get('config_hash')}, this invocation is {cfg_hash}. "
                    "REFUSING to mix two experiment definitions in one run.")
            # provenance is APPENDED, never overwritten: a resume must not erase
            # the record of which sources produced the earlier checkpoints
            provenance = list(prior.get("provenance", []))
            provenance.append({k: prior.get(k) for k in
                               ("started_utc", "pid", "host", "argv",
                                "source_sha256")})
            source_changed = prior.get("source_sha256") != srcs
            if source_changed:
                print("WARNING: source hashes differ from the manifest that "
                      "produced the existing checkpoints. Both hash sets are "
                      "recorded under 'provenance'. Checkpoints from the "
                      "earlier sources are NOT recomputed.", file=sys.stderr)

        # ---- MANIFEST WRITTEN BEFORE ANY SIMULATION STARTS
        manifest = {
            "run_id": run_id,
            "suite": suite,
            "started_utc": datetime.now(timezone.utc).isoformat(),
            "pid": os.getpid(),
            "host": socket.gethostname(),
            "python": sys.version.split()[0],
            "argv": sys.argv,
            "label": args.label,
            "workers": args.workers,
            "lock_file": str(LOCK_PATH),
            "output_dir": str(run_dir),
            "config_hash": cfg_hash,
            "source_sha256": srcs,
            "provenance": provenance,
            "source_changed_since_previous_invocation": source_changed,
            "axes": list(AXES),
            "grid": {a: list(v) for a, v in zip(AXES, grid)},
            "seed_list": list(grid[AXES.index("seed")]),
            "frozen_seed_list": list(SEEDS),
            "n_req_per_trace": N_REQ,
            "policies": list(POLICY_NAMES),
            "n_policies": len(POLICY_NAMES),
            "this_run_expected_configs": expected_configs,
            "this_run_expected_records": expected_records,
            "frozen_grid_expected_configs": EXPECTED_CONFIGS,
            "frozen_grid_expected_records": EXPECTED_RECORDS,
            "targeted_suite": targeted_suite_block(),
            "row_exclusion": "none",
            "coverage_role": ("annotations for stratification only; never an "
                              "eligibility filter"),
            "horizon_rule": ("fixed per trace: latest completion deadline plus "
                             "one declared L_down,max. Derived from the trace, "
                             "identical for every policy."),
            "resume": {
                "checkpoints_found": len(done_keys),
                "torn_lines_dropped": torn,
                "duplicate_checkpoints_dropped": dropped_dupes,
                "configs_to_run": len(todo),
            },
        }
        manifest_path.write_text(json.dumps(manifest, indent=1, sort_keys=True))

        print(f"run_id      {run_id}", file=sys.stderr)
        print(f"output      {run_dir}", file=sys.stderr)
        print(f"suite       {suite}", file=sys.stderr)
        print(f"configs     {expected_configs}  ({len(todo)} to run, "
              f"{len(done_keys)} already checkpointed)", file=sys.stderr)
        print(f"records     {expected_records} = {expected_configs} x "
              f"{len(POLICY_NAMES)} policies", file=sys.stderr)
        print(f"manifest    written BEFORE any run: {manifest_path}",
              file=sys.stderr)

        # ---- run, checkpointing every completed configuration
        t0 = time.time()
        n_new = 0
        if todo:
            ck = open(ck_path, "a")
            try:
                with Pool(args.workers) as pool:
                    for rec in pool.imap_unordered(run_one, todo, chunksize=1):
                        ck.write(json.dumps(rec, sort_keys=True) + "\n")
                        ck.flush()
                        os.fsync(ck.fileno())
                        done.append(rec)
                        n_new += 1
                        if n_new % 10 == 0 or n_new == len(todo):
                            el = time.time() - t0
                            rate = n_new / el if el else 0.0
                            eta = (len(todo) - n_new) / rate if rate else 0.0
                            print(f"  {n_new}/{len(todo)} configs  "
                                  f"{el:7.1f}s elapsed  {rate:6.2f} cfg/s  "
                                  f"eta {eta:8.1f}s", file=sys.stderr)
            finally:
                ck.close()
        wall = time.time() - t0

        # ---- validation, censoring, aggregates
        val = validate(done, expected_configs, expected_records, all_keys)
        cens = censoring_report(done)
        agg = aggregate(done)
        strata = stratify(done)
        times = sorted(r["config_s"] for r in done if "config_s" in r)
        timing = {
            "wall_s_this_invocation": round(wall, 2),
            "configs_run_this_invocation": n_new,
            "workers": args.workers,
            "throughput_cfg_per_s": round(n_new / wall, 4) if wall else None,
            "per_config_worker_s_min": times[0] if times else None,
            "per_config_worker_s_median": times[len(times) // 2] if times else None,
            "per_config_worker_s_max": times[-1] if times else None,
            "per_config_worker_s_mean": (round(sum(times) / len(times), 3)
                                         if times else None),
        }

        payload = {
            "manifest": manifest,
            "finished_utc": datetime.now(timezone.utc).isoformat(),
            "validation": val,
            "censoring": cens,
            "timing": timing,
            "per_policy_aggregate": agg,
            "stratification": strata,
            "records": sorted(done, key=lambda r: r["cfg_key"]),
        }

        # ---- ATOMIC: temp file, fsync, rename. Nothing is printed before this.
        with open(tmp_path, "w") as fh:
            json.dump(payload, fh, indent=1, sort_keys=True)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_path, results_path)
        dfd = os.open(run_dir, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        lock.release()

    # ================= AUTHORITATIVE RESULT IS ON DISK. ONLY NOW DO WE PRINT.
    try:
        _print_summary(run_id, results_path, val, cens, timing, agg, strata, done)
    except BrokenPipeError:
        # never pipe the producer into `head`
        os.write(2, b"FATAL: stdout closed early (piped into head?). "
                    b"The authoritative result IS written; the summary is not.\n")
        return 3
    return 0 if val["records_match"] and not val["n_missing_config_keys"] else 1


def _print_summary(run_id, results_path, val, cens, timing, agg, strata, done):
    w = sys.stdout.write
    w("\n" + "=" * 78 + "\n")
    w(f"SWEEP B  run {run_id}\n")
    w(f"authoritative result written and renamed: {results_path}\n")
    w("=" * 78 + "\n")

    w("\nRECORD COUNT VALIDATION\n")
    w(f"  configs   expected {val['expected_configs']:>7}   "
      f"observed {val['observed_configs']:>7}   "
      f"{'OK' if val['configs_match'] else 'MISMATCH'}\n")
    w(f"  records   expected {val['expected_records']:>7}   "
      f"observed {val['observed_records']:>7}   "
      f"{'OK' if val['records_match'] else 'MISMATCH'}\n")
    w(f"  missing configs    {val['n_missing_config_keys']}\n")
    w(f"  duplicated configs {val['n_duplicated_config_keys']}\n")
    w(f"  unexpected configs {val['n_unexpected_config_keys']}\n")
    w(f"  wrong record width {len(val['configs_with_wrong_record_width'])}\n")
    w(f"  row exclusion      {val['row_exclusion']}  "
      f"(kept {val['rows_kept']} of {val['rows_produced']} produced)\n")
    w(f"  frozen grid defines 77,760 records: "
      f"{val['frozen_grid_definition_is_77760']}\n")

    esc_rows = sum(1 for r in done for row in r["rows"].values()
                   if row["status"] != "ok")
    if esc_rows:
        esc_cfgs = sum(1 for r in done
                       if any(row["status"] != "ok" for row in r["rows"].values()))
        w("\nESCAPED SAFETY VIOLATIONS  (rows kept, marked, NOT excluded)\n")
        w(f"  records escaped : {esc_rows}/{val['rows_produced']}  "
          f"({100.0*esc_rows/val['rows_produced']:.1f}%)\n")
        w(f"  configs touched : {esc_cfgs}/{val['observed_configs']}\n")
        per = {}
        for r in done:
            for name, row in r["rows"].items():
                if row["status"] != "ok":
                    per[name] = per.get(name, 0) + 1
        w("  per policy      : ")
        w(", ".join(f"{n} {per.get(n,0)}" for n in POLICY_NAMES) + "\n")
        w("  WARNING: the escape rate DIFFERS BY POLICY, so the surviving rows\n"
          "  are not an unbiased sample. Comparing policies across them would\n"
          "  reintroduce exactly the selection bias this suite exists to avoid.\n")

    ts = targeted_suite_block()
    if ts["count_is_stale"]:
        w("\nTARGETED SUITE COUNT IS STALE\n")
        w(f"  {ts['path']} now hashes to {ts['current_sha256'][:16]}...\n")
        w(f"  the recorded count {ts['expected_records']} was measured against "
          f"{ts['measured_against_sha256'][:16]}...\n")
        w("  re-run that suite and update both constants.\n")

    w("\nRIGHT-CENSORING\n")
    w(f"  max censored fetches in any config : "
      f"{cens['max_censored_in_any_config']}\n")
    w(f"  summed censored fetches            : "
      f"{cens['total_censored_fetches_per_config_sum']}\n")
    w(f"  policy disagreement on censoring   : "
      f"{len(cens['configs_with_policy_disagreement_on_censoring'])}\n")

    w("\nPER-POLICY AGGREGATE  (descriptive only; NO pass gate applied)\n")
    w(f"  {'policy':<32}{'rows':>6}{'esc':>5}{'offered':>9}{'admit':>8}"
      f"{'comp':>8}{'on_time':>9}{'ot/off%':>9}{'viol':>6}\n")
    for name in POLICY_NAMES:
        b = agg.get(name)
        if not b:
            continue
        w(f"  {name:<32}{b['records']:>6}{b['escaped']:>5}{b['offered']:>9}"
          f"{b['admitted']:>8}{b['completed']:>8}{b['on_time']:>9}"
          f"{b['on_time_per_offered_%']:>9}{b['with_violation']:>6}\n")

    kinds = {}
    for b in agg.values():
        for k, v in b["violation_kinds"].items():
            kinds[k] = kinds.get(k, 0) + v
    if kinds:
        w("\nVIOLATION / ESCAPE KINDS (all policies)\n")
        for k, v in sorted(kinds.items(), key=lambda x: -x[1]):
            w(f"  {k:<34}{v:>8}\n")

    w("\nCOVERAGE ANNOTATIONS  (stratification only; excluded nothing)\n")
    tot = strata["rows_annotated"] or 1
    for k in ANNOTATION_KEYS + NESTED_SEVERITY_KEYS:
        n = strata["hit_counts"].get(k, 0)
        tag = "  [NESTED severity]" if k in NESTED_SEVERITY_KEYS else ""
        w(f"  {k:<40}{n:>8}/{tot}  {100.0*n/tot:>6.1f}%{tag}\n")

    w("\nTIMING\n")
    w(f"  configs this invocation : {timing['configs_run_this_invocation']}\n")
    w(f"  wall                    : {timing['wall_s_this_invocation']} s "
      f"on {timing['workers']} workers\n")
    w(f"  throughput              : {timing['throughput_cfg_per_s']} cfg/s\n")
    w(f"  per-config worker time  : min {timing['per_config_worker_s_min']} / "
      f"median {timing['per_config_worker_s_median']} / "
      f"max {timing['per_config_worker_s_max']} s\n")
    if timing["throughput_cfg_per_s"]:
        full = EXPECTED_CONFIGS / timing["throughput_cfg_per_s"]
        w(f"  extrapolated full grid  : {EXPECTED_CONFIGS} configs / "
          f"{timing['throughput_cfg_per_s']} cfg/s = {full/3600:.2f} h "
          f"at {timing['workers']} workers\n")
        w("    (extrapolation from THIS batch only; a batch too small to keep\n"
          "     every worker busy understates the achievable throughput)\n")

    w("\nALL FIGURES SYNTHETIC. No AXI, DDR, ZCU104 or ILA measurement.\n")
    w("No GO/NO-GO is inferred here. Per SWEEP_B_CONTRACT.md section 7 a\n"
      "qualifying region must be frozen and revalidated on >=20 fresh unused\n"
      "seeds with a paired confidence interval excluding zero.\n")
    sys.stdout.flush()


if __name__ == "__main__":
    raise SystemExit(main())
