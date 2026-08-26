#!/usr/bin/env python3
"""INDEPENDENT validation of DownstreamEnvelope.l_down_max().

    BOUND UNDER TEST
    L_down,max,i  <=  B_fixed + (N_out - 1)*C_max + C_i + bypass*C_max + refresh

This file deliberately does NOT import gm/data_plane.py and reuses none of its
logic. The queue/service simulator below is written from the service model
description directly, so an error in the model under test cannot hide inside
the validator. gm/types.py IS imported, but only to prove that the analytic
formula re-implemented here is byte-for-byte the same arithmetic as the
artefact under test.

EVERYTHING PRODUCED BY THIS FILE IS SYNTHETIC. It is a validation of the
ARITHMETIC against a queueing model. It is not a measurement of any ZCU104.

Service model (taken verbatim from the validation brief):
  * FIFO, non-preemptive, single server.
  * At most N_out transactions accepted-but-not-completed.
  * Per-transaction service time drawn from [1, C_max].
  * Fixed overhead B_fixed at acceptance.
  * A periodic refresh stall of `refresh` cycles per window of `window` cycles.

Because two of those clauses are ambiguous in the model under test, the
simulator is parameterised over the ambiguity rather than picking a side:

  b_mode  = "per_txn"  B_fixed is charged on every acceptance (literal reading
                       of "fixed overhead B_fixed at acceptance")
          = "bp"       B_fixed is charged once per server busy period
                       (i.e. it is a pipelined, amortised overhead)

  r_mode  = "periodic" the refresh stall really is periodic: the server is
                       blocked for `refresh` cycles in every `window` cycles
          = "bp"       one refresh stall is charged per busy period, so at most
                       one can ever land inside a single transaction's
                       acceptance-to-completion interval

Mode  L  = (per_txn, periodic)  the literal service model
Mode B1  = (per_txn, bp)        isolates the B_fixed term
Mode B2  = (bp,      periodic)  isolates the refresh term
Mode  F  = (bp,      bp)        the reading under which the bound is intended
                                to be true ("bound-faithful")

Usage:
    python3 validate_ldownmax.py            # full run
    python3 validate_ldownmax.py --quick    # reduced grid, for iteration
    python3 validate_ldownmax.py --json out.json
"""
from __future__ import annotations

import argparse
import json
import math
import random
import sys
from collections import deque
from dataclasses import dataclass, field

# --------------------------------------------------------------------------
# 0. THE ANALYTIC BOUND, RE-IMPLEMENTED FROM THE FORMULA TEXT
# --------------------------------------------------------------------------


def analytic_bound(n_out: int, c_max: int, c_i: int, b_fixed: int,
                   refresh: int, bypass: int = 0) -> int:
    """B_fixed + (N_out - 1)*C_max + C_i + bypass*C_max + refresh."""
    return b_fixed + (n_out - 1) * c_max + c_i + bypass * c_max + refresh


def cross_check_against_artefact() -> tuple[bool, str, int]:
    """Prove analytic_bound() is the same arithmetic as the code under test."""
    try:
        sys.path.insert(0, str(__file__).rsplit("/", 1)[0])
        from gm.types import DownstreamEnvelope
    except Exception as exc:                                # pragma: no cover
        return False, f"could not import gm.types: {exc}", 0
    n = 0
    for c_max in (64, 128, 256, 512, 1024):
        for b_fixed in (0, 32, 128):
            for refresh in (0, 64, 256):
                for bypass in (0, 1, 3):
                    env = DownstreamEnvelope(
                        c_max_cycles=c_max, b_fixed_cycles=b_fixed,
                        refresh_cycles_per_window=refresh,
                        max_bypass_transactions=bypass)
                    for n_out in (1, 2, 4, 8, 16):
                        for c_i in (16, 64, 144, 512):
                            got = env.l_down_max(n_out, c_i)
                            mine = analytic_bound(n_out, c_max, c_i, b_fixed,
                                                  refresh, bypass)
                            n += 1
                            if got != mine:
                                return (False,
                                        f"MISMATCH n_out={n_out} c_max={c_max} "
                                        f"c_i={c_i} b={b_fixed} r={refresh} "
                                        f"byp={bypass}: artefact={got} mine={mine}",
                                        n)
    return True, "", n


# --------------------------------------------------------------------------
# 1. INDEPENDENT DISCRETE-EVENT QUEUE / SERVICE SIMULATOR
# --------------------------------------------------------------------------


def advance(t: int, w: int, refresh: int, window: int) -> int:
    """Finish time of `w` cycles of work started at absolute time `t`, when the
    server is blocked for the last `refresh` cycles of every `window` cycles.

    Written from the stall geometry directly; no shared code with the model.
    """
    if refresh <= 0 or w <= 0:
        return t + w
    usable = window - refresh
    if usable <= 0:
        raise ValueError("refresh >= window: the server never makes progress")
    while True:
        k, off = divmod(t, window)
        if off >= usable:                 # inside a stall: skip to next window
            t = (k + 1) * window
            continue
        avail = usable - off
        if w <= avail:
            return t + w
        w -= avail
        t = (k + 1) * window


def worst_case_stall_inflation(w: int, refresh: int, window: int) -> int:
    """Closed form for max over start phase of advance(): w + refresh*ceil(w/u).

    Derivation: the worst start is the first cycle of a stall. You immediately
    eat one stall, then the work is served in chunks of u = window - refresh,
    each chunk followed by another stall. Hence ceil(w/u) stalls. Verified
    exhaustively against advance() in check_stall_lemma().
    """
    if refresh <= 0 or w <= 0:
        return max(w, 0)
    usable = window - refresh
    return w + refresh * math.ceil(w / usable)


def check_stall_lemma(cases, window_list) -> tuple[bool, list]:
    """Brute-force every start phase and confirm the closed form is exact."""
    bad = []
    for window in window_list:
        for refresh in (1, 7, 64, 256, 511):
            if refresh >= window:
                continue
            for w in cases:
                obs = max(advance(p, w, refresh, window) - p
                          for p in range(window))
                pred = worst_case_stall_inflation(w, refresh, window)
                if obs != pred:
                    bad.append((window, refresh, w, obs, pred))
    return (not bad), bad


def _advance_bruteforce(t: int, w: int, refresh: int, window: int) -> int:
    """Second, deliberately naive implementation of the same stall geometry,
    stepping one cycle at a time. Used only to cross-check advance()."""
    if refresh <= 0:
        return t + w
    usable = window - refresh
    left = w
    while left > 0:
        if (t % window) < usable:
            left -= 1
        t += 1
    return t


def selftest() -> list[str]:
    """The validator validates itself before it is allowed to judge anything."""
    fails = []
    rng = random.Random(20260824)

    # 1. advance() vs an independent cycle-stepping implementation
    for _ in range(4000):
        window = rng.choice([16, 64, 256, 1024])
        refresh = rng.randrange(0, window)
        t = rng.randrange(0, 4 * window)
        w = rng.randrange(0, 3 * window)
        a = advance(t, w, refresh, window)
        b = _advance_bruteforce(t, w, refresh, window)
        if a != b:
            fails.append(f"advance({t},{w},{refresh},{window}) = {a} but "
                         f"cycle-stepping gives {b}")
            break

    # 2. refresh = 0 must be pure work
    for _ in range(200):
        t, w = rng.randrange(10_000), rng.randrange(10_000)
        if advance(t, w, 0, 1024) != t + w:
            fails.append("advance() adds time when refresh = 0")
            break

    # 3. degenerate server: N_out=1, B=0, refresh=0 -> latency == service
    r = simulate(1, 64, 37, 0, 0, 1024, "per_txn", "periodic", seed=1,
                 n_txn=300)
    if r.max_probe_lat != 37:
        fails.append(f"N_out=1,B=0,refresh=0: probe latency {r.max_probe_lat} "
                     f"!= service 37")

    # 4. the outstanding cap is really enforced
    for n_out in (1, 2, 4, 8, 16):
        r = simulate(n_out, 256, 64, 16, 64, 1024, "per_txn", "periodic",
                     seed=7, n_txn=400, rho=3.0)
        if r.max_outstanding > n_out:
            fails.append(f"outstanding {r.max_outstanding} exceeded cap {n_out}")
        if r.max_outstanding < n_out and n_out <= 8:
            fails.append(f"cap {n_out} never reached: traffic too light to "
                         f"stress the queue (max {r.max_outstanding})")

    # 5. FIFO non-preemption: completion order must equal acceptance order
    r = simulate(8, 512, 144, 32, 64, 1024, "per_txn", "periodic", seed=3,
                 n_txn=200, rho=3.0, record=True)
    fin = [x.finish for x in r.trace]
    if fin != sorted(fin):
        fails.append("completion times out of order: server is not FIFO")

    # 6. single transaction into an empty system, mode F, must equal the
    #    N_out=1 analytic bound exactly
    lat, _, _ = adversarial(1, 512, 144, 32, 64, 1024, "bp", "bp",
                            phases=list(range(1024)))
    want = analytic_bound(1, 512, 144, 32, 64)
    if lat != want:
        fails.append(f"N_out=1 mode F gives {lat}, analytic says {want}")

    # 7. monotonicity: raising N_out must never lower the observed worst case
    prev = -1
    for n in (1, 2, 4, 8, 16):
        lat, _, _ = adversarial(n, 512, 144, 32, 64, 1024, "per_txn",
                                "periodic")
        if lat < prev:
            fails.append(f"observed worst case fell when N_out rose to {n}")
        prev = lat
    return fails


@dataclass
class TxnRec:
    idx: int
    arrival: int
    accept: int
    svc: int
    start: int
    finish: int
    is_probe: bool

    def as_row(self) -> str:
        tag = "PROBE" if self.is_probe else "     "
        return (f"    #{self.idx:<5d} {tag} arrive={self.arrival:<8d} "
                f"accept={self.accept:<8d} svc={self.svc:<6d} "
                f"start={self.start:<8d} complete={self.finish:<8d} "
                f"lat={self.finish - self.accept}")


@dataclass
class SimResult:
    max_probe_lat: int = 0
    n_probe: int = 0
    n_txn: int = 0
    max_outstanding: int = 0
    trace: list = field(default_factory=list)


SVC_DISTS = ("uniform", "bimodal", "pareto_trunc", "always_max", "pareto_over")


def _draw_service(rng: random.Random, c_max: int, dist: str,
                  over_factor: float) -> int:
    if dist == "uniform":
        return rng.randint(1, c_max)
    if dist == "always_max":
        return c_max
    if dist == "bimodal":
        return c_max if rng.random() < 0.15 else rng.randint(1, max(1, c_max // 8))
    if dist in ("pareto_trunc", "pareto_over"):
        alpha = 1.1
        u = rng.random()
        x = int(1.0 / ((1.0 - u) ** (1.0 / alpha)))
        cap = c_max if dist == "pareto_trunc" else int(c_max * over_factor)
        return max(1, min(cap, x))
    raise ValueError(dist)


def simulate(n_out: int, c_max: int, c_i: int, b_fixed: int, refresh: int,
             window: int, b_mode: str, r_mode: str, seed: int,
             n_txn: int, dist: str = "uniform", rho: float | None = None,
             record: bool = False, over_factor: float = 1.0) -> SimResult:
    """Randomised discrete-event run. Returns max acceptance-to-completion
    latency over probe transactions (those whose service time is exactly C_i).
    """
    rng = random.Random(seed)
    res = SimResult()

    mean_svc = (c_max + 1) / 2.0 + (b_fixed if b_mode == "per_txn" else 0)
    if rho is None:
        rho = rng.choice([0.6, 0.9, 1.2, 2.5])
    mean_gap = max(1.0, mean_svc / max(rho, 1e-6))

    t = rng.randrange(window)          # randomise refresh phase per seed
    server_free = t
    pending: deque[int] = deque()      # completion times, ascending
    ring: deque[TxnRec] = deque(maxlen=n_out + 4)

    for j in range(n_txn):
        if rng.random() < 0.25:        # bursts: n_out back-to-back arrivals
            gap = 0
        else:
            gap = int(rng.expovariate(1.0 / mean_gap))
        t += gap
        a = t

        while pending and pending[0] <= a:
            pending.popleft()
        if len(pending) >= n_out:
            acc = pending[0]
            while pending and pending[0] <= acc:
                pending.popleft()
        else:
            acc = a

        is_probe = (rng.random() < 0.30)
        svc = c_i if is_probe else _draw_service(rng, c_max, dist, over_factor)

        idle = server_free <= acc
        w = svc
        if b_mode == "per_txn" or idle:
            w += b_fixed
        start = max(acc, server_free)
        if r_mode == "periodic":
            fin = advance(start, w, refresh, window)
        else:
            if idle:
                w += refresh
            fin = start + w
        server_free = fin
        pending.append(fin)

        res.n_txn += 1
        res.max_outstanding = max(res.max_outstanding, len(pending))
        if record:
            ring.append(TxnRec(j, a, acc, svc, start, fin, is_probe))
        if is_probe:
            res.n_probe += 1
            lat = fin - acc
            if lat > res.max_probe_lat:
                res.max_probe_lat = lat
                if record:
                    res.trace = list(ring)
    return res


# --------------------------------------------------------------------------
# 2. ADVERSARIAL CONSTRUCTION
# --------------------------------------------------------------------------


def adversarial(n_out: int, c_max: int, c_i: int, b_fixed: int, refresh: int,
                window: int, b_mode: str, r_mode: str, bypass: int = 0,
                phases=None, blocker_svc: int | None = None
                ) -> tuple[int, int, list]:
    """Deterministic worst case for ONE probe transaction.

    Pattern: the server is idle and empty at t0. N_out-1 transactions each with
    service exactly C_max are accepted at t0, and the probe (service C_i) is
    accepted at t0 as well, filling the outstanding window exactly. FIFO then
    forces the probe behind all N_out-1 of them. `bypass` extra C_max
    transactions are inserted ahead of the probe as slots free.

    Returns (max latency over start phases, best phase, trace of the best run).
    """
    if phases is None:
        base = [0, 1, window - refresh, window - refresh - 1, window - 1,
                max(0, refresh - 1), refresh, window // 2]
        rng = random.Random(0xADDED)
        base += [rng.randrange(window) for _ in range(24)]
        phases = sorted({p % window for p in base})

    if blocker_svc is None:
        blocker_svc = c_max
    c_max, c_max_bound = blocker_svc, c_max      # service used, envelope claim
    best_lat, best_phase, best_trace = -1, 0, []
    for t0 in phases:
        server_free = t0
        idle_first = True
        trace = []
        # N_out-1 blockers, all accepted at t0, all with service C_max
        for k in range(n_out - 1):
            w = c_max + (b_fixed if (b_mode == "per_txn" or idle_first) else 0)
            if r_mode == "bp" and idle_first:
                w += refresh
            start = max(t0, server_free)
            fin = (advance(start, w, refresh, window) if r_mode == "periodic"
                   else start + w)
            trace.append(TxnRec(k, t0, t0, c_max, start, fin, False))
            server_free = fin
            idle_first = False
        # bounded priority bypass: `bypass` transactions jump ahead of the probe
        for k in range(bypass):
            w = c_max + (b_fixed if (b_mode == "per_txn" or idle_first) else 0)
            if r_mode == "bp" and idle_first:
                w += refresh
            start = max(t0, server_free)
            fin = (advance(start, w, refresh, window) if r_mode == "periodic"
                   else start + w)
            trace.append(TxnRec(1000 + k, t0, t0, c_max, start, fin, False))
            server_free = fin
            idle_first = False
        # the probe
        w = c_i + (b_fixed if (b_mode == "per_txn" or idle_first) else 0)
        if r_mode == "bp" and idle_first:
            w += refresh
        start = max(t0, server_free)
        fin = (advance(start, w, refresh, window) if r_mode == "periodic"
               else start + w)
        trace.append(TxnRec(9999, t0, t0, c_i, start, fin, True))
        lat = fin - t0
        if lat > best_lat:
            best_lat, best_phase, best_trace = lat, t0, trace
    return best_lat, best_phase, best_trace


def corrected_bound(n_out: int, c_max: int, c_i: int, b_fixed: int,
                    refresh: int, window: int, bypass: int = 0,
                    b_mode: str = "per_txn", r_mode: str = "periodic") -> int:
    """The bound this validator proposes in place of the one under test."""
    n_over = (n_out + bypass) if b_mode == "per_txn" else 1
    w = n_over * b_fixed + (n_out - 1 + bypass) * c_max + c_i
    if r_mode == "periodic":
        return worst_case_stall_inflation(w, refresh, window)
    return w + refresh


# --------------------------------------------------------------------------
# 3. GRID
# --------------------------------------------------------------------------

N_OUT_GRID = (1, 2, 4, 8, 16)
C_MAX_GRID = (64, 128, 256, 512, 1024)
C_I_GRID = (16, 64, 144, 512)
B_FIXED_GRID = (0, 32, 128)
REFRESH_GRID = (0, 64, 256)
WINDOW = 1024                     # DownstreamEnvelope.window_cycles default

MODES = {
    "L":  ("per_txn", "periodic"),
    "B1": ("per_txn", "bp"),
    "B2": ("bp", "periodic"),
    "F":  ("bp", "bp"),
}
MODE_DESC = {
    "L":  "literal    (B_fixed per acceptance, refresh truly periodic)",
    "B1": "B_fixed-only(B_fixed per acceptance, refresh lumped once)",
    "B2": "refresh-only(B_fixed amortised,      refresh truly periodic)",
    "F":  "bound-faithful (B_fixed amortised,   refresh lumped once)",
}


def cells(quick: bool):
    n_out_g = (1, 2, 4, 16) if quick else N_OUT_GRID
    c_max_g = (64, 512, 1024) if quick else C_MAX_GRID
    for n_out in n_out_g:
        for c_max in c_max_g:
            for c_i in C_I_GRID:
                for b_fixed in B_FIXED_GRID:
                    for refresh in REFRESH_GRID:
                        yield n_out, c_max, c_i, b_fixed, refresh


def run_grid(quick: bool, seeds: int, n_txn: int, out: dict) -> None:
    print("=" * 78)
    print("TASK 2  GRID: analytic bound vs observed maximum   [SYNTHETIC]")
    print("=" * 78)
    modes = ["L", "F"] if not quick else ["L", "F"]
    summary = {}
    violations = {m: [] for m in MODES}
    in_domain = 0
    out_domain = 0
    adv_rows = []

    for cell in cells(quick):
        n_out, c_max, c_i, b_fixed, refresh = cell
        if c_i > c_max:
            out_domain += 1
            continue
        in_domain += 1
        bound = analytic_bound(n_out, c_max, c_i, b_fixed, refresh)

        # --- adversarial, all four modes (cheap, deterministic)
        for m, (bm, rm) in MODES.items():
            lat, phase, _ = adversarial(n_out, c_max, c_i, b_fixed, refresh,
                                        WINDOW, bm, rm)
            if lat > bound:
                violations[m].append(
                    dict(mode=m, n_out=n_out, c_max=c_max, c_i=c_i,
                         b_fixed=b_fixed, refresh=refresh, bound=bound,
                         observed=lat, excess=lat - bound, phase=phase,
                         source="adversarial"))
            adv_rows.append((m, cell, bound, lat))

        # --- randomised, modes L and F
        for m in modes:
            bm, rm = MODES[m]
            worst, worst_seed = 0, -1
            for s in range(seeds):
                r = simulate(n_out, c_max, c_i, b_fixed, refresh, WINDOW,
                             bm, rm, seed=s, n_txn=n_txn)
                if r.max_probe_lat > worst:
                    worst, worst_seed = r.max_probe_lat, s
                if r.max_outstanding > n_out:
                    raise AssertionError("simulator broke its own N_out cap")
            key = (m,) + cell
            summary[key] = (bound, worst, worst_seed)
            if worst > bound:
                violations[m].append(
                    dict(mode=m, n_out=n_out, c_max=c_max, c_i=c_i,
                         b_fixed=b_fixed, refresh=refresh, bound=bound,
                         observed=worst, excess=worst - bound,
                         seed=worst_seed, source="randomised"))

    print(f"\nin-domain cells (C_i <= C_max): {in_domain}")
    print(f"out-of-domain cells skipped (C_i > C_max): {out_domain}")
    print(f"randomised: {seeds} seeds x {n_txn} transactions per cell per mode")
    print("\nVERDICT PER SERVICE-MODEL VARIANT (adversarial + randomised):")
    print(f"  {'mode':<4} {'variant':<52} {'violating cells':>16}")
    for m in MODES:
        v = violations[m]
        n_adv = sum(1 for x in v if x["source"] == "adversarial")
        n_rnd = sum(1 for x in v if x["source"] == "randomised")
        verdict = "REFUTED" if v else "not refuted"
        print(f"  {m:<4} {MODE_DESC[m]:<52} {len(v):>6}  {verdict}"
              f"   (adv {n_adv}, rand {n_rnd})")

    out["grid"] = {
        "in_domain": in_domain, "out_of_domain": out_domain,
        "seeds": seeds, "n_txn": n_txn,
        "violations": {m: violations[m] for m in MODES},
        "n_violations": {m: len(violations[m]) for m in MODES},
    }

    # ---------------- worst violations, with reproducible detail
    print("\n" + "-" * 78)
    print("WORST VIOLATIONS BY EXCESS (mode L, the literal service model)")
    print("-" * 78)
    vl = sorted(violations["L"], key=lambda x: -x["excess"])[:12]
    if not vl:
        print("  none")
    for v in vl:
        print(f"  N_out={v['n_out']:<3d} C_max={v['c_max']:<5d} C_i={v['c_i']:<4d} "
              f"B={v['b_fixed']:<4d} refresh={v['refresh']:<4d} | "
              f"bound={v['bound']:<7d} observed={v['observed']:<7d} "
              f"excess=+{v['excess']:<6d} ratio={v['observed']/v['bound']:.3f} "
              f"[{v['source']}]")
    if violations["L"]:
        wr = max(violations["L"], key=lambda x: x["observed"] / x["bound"])
        print(f"\n  WORST RATIO ANYWHERE IN THE GRID: "
              f"{wr['observed']/wr['bound']:.4f}x  at N_out={wr['n_out']} "
              f"C_max={wr['c_max']} C_i={wr['c_i']} B={wr['b_fixed']} "
              f"refresh={wr['refresh']}  (bound={wr['bound']}, "
              f"observed={wr['observed']}) [{wr['source']}]")
        out["worst_ratio_cell"] = wr

    # ---------------- randomised violations, replayed with seed + trace
    print("\n" + "-" * 78)
    print("RANDOMISED VIOLATIONS, REPLAYED WITH SEED AND TRANSACTION TRACE")
    print("-" * 78)
    rv = sorted((v for v in violations["L"] if v["source"] == "randomised"),
                key=lambda x: -x["excess"])
    print(f"  {len(rv)} cells were refuted by RANDOM traffic alone "
          f"(no adversarial construction). Top 3, replayed:")
    for v in rv[:3]:
        r = simulate(v["n_out"], v["c_max"], v["c_i"], v["b_fixed"],
                     v["refresh"], WINDOW, "per_txn", "periodic",
                     seed=v["seed"], n_txn=n_txn, record=True)
        print(f"\n  N_out={v['n_out']} C_max={v['c_max']} C_i={v['c_i']} "
              f"B_fixed={v['b_fixed']} refresh={v['refresh']} window={WINDOW} "
              f"seed={v['seed']}")
        print(f"    bound={v['bound']}  observed={r.max_probe_lat}  "
              f"excess=+{r.max_probe_lat - v['bound']}  "
              f"(replay reproduces: "
              f"{'YES' if r.max_probe_lat == v['observed'] else 'NO'})")
        for rec in r.trace:
            print(rec.as_row())

    # ---------------- does a closed-form predicate explain every violation?
    print("\n" + "-" * 78)
    print("VIOLATION PREDICATE (mode L): can every violating cell be named?")
    print("-" * 78)
    print("  Claim: in mode L a cell is refuted iff")
    print("     (N_out > 1 and B_fixed > 0)                     [B_fixed defect]")
    print("  or (refresh > 0 and span > window - refresh)       [refresh defect]")
    print("  where span = B_fixed + (N_out-1)*C_max + C_i.")
    viol_cells = {(v["n_out"], v["c_max"], v["c_i"], v["b_fixed"], v["refresh"])
                  for v in violations["L"]}
    pred_cells = set()
    all_cells = set()
    for cell in cells(quick):
        n_out, c_max, c_i, b_fixed, refresh = cell
        if c_i > c_max:
            continue
        all_cells.add(cell)
        span = b_fixed + (n_out - 1) * c_max + c_i
        if (n_out > 1 and b_fixed > 0) or \
           (refresh > 0 and span > WINDOW - refresh):
            pred_cells.add(cell)
    fp = pred_cells - viol_cells
    fn = viol_cells - pred_cells
    print(f"  cells in domain            : {len(all_cells)}")
    print(f"  cells the predicate flags  : {len(pred_cells)}")
    print(f"  cells actually refuted     : {len(viol_cells)}")
    print(f"  predicted-but-not-refuted  : {len(fp)}")
    print(f"  refuted-but-not-predicted  : {len(fn)}")
    if not fp and not fn:
        print("  -> the predicate is EXACT. Every violation is one of exactly")
        print("     two arithmetic defects; no third failure mode exists in")
        print("     this grid.")
    else:
        for c in sorted(fp)[:5]:
            print(f"    predicted, not observed: {c}")
        for c in sorted(fn)[:5]:
            print(f"    observed, not predicted: {c}")
    out["predicate"] = dict(in_domain=len(all_cells), predicted=len(pred_cells),
                            observed=len(viol_cells), false_pos=len(fp),
                            false_neg=len(fn), exact=(not fp and not fn))
    safe = len(all_cells) - len(viol_cells)
    print(f"\n  cells where the asserted bound HOLDS even in mode L: "
          f"{safe}/{len(all_cells)} ({100*safe/len(all_cells):.1f}%)")

    print("\n" + "-" * 78)
    print("MODE F (bound-faithful) TIGHTNESS: observed/analytic, adversarial")
    print("-" * 78)
    fr = [(cell, b, l) for (m, cell, b, l) in adv_rows if m == "F"]
    ratios = [l / b for _, b, l in fr if b > 0]
    if ratios:
        exact = sum(1 for r in ratios if abs(r - 1.0) < 1e-9)
        print(f"  cells: {len(ratios)}   min ratio={min(ratios):.4f}   "
              f"max ratio={max(ratios):.4f}   "
              f"cells attaining the bound exactly: {exact}/{len(ratios)}")
        out["mode_F_ratio"] = dict(n=len(ratios), min=min(ratios),
                                   max=max(ratios), exact=exact)

    # ---------------- looseness under random traffic
    print("\n" + "-" * 78)
    print("LOOSENESS UNDER RANDOM TRAFFIC (mode F, randomised observed/analytic)")
    print("-" * 78)
    rr = [(k, v) for k, v in summary.items() if k[0] == "F" and v[0] > 0]
    rats = sorted(v[1] / v[0] for _, v in rr)
    if rats:
        loose = sum(1 for r in rats if r < 0.10)
        print(f"  cells={len(rats)}  min={rats[0]:.3f}  "
              f"median={rats[len(rats)//2]:.3f}  max={rats[-1]:.3f}")
        print(f"  cells where random traffic reached <10% of the bound: "
              f"{loose}/{len(rats)}  (LOOSENESS finding, not a failure)")
        out["random_looseness"] = dict(n=len(rats), min=rats[0],
                                       median=rats[len(rats) // 2],
                                       max=rats[-1], under_10pct=loose)
    return summary, violations


# --------------------------------------------------------------------------
# 4. SINGLE-REFRESH VALIDITY CONDITION (pure arithmetic, no simulation)
# --------------------------------------------------------------------------


def refresh_validity(quick: bool, out: dict) -> None:
    print("\n" + "=" * 78)
    print("SINGLE-REFRESH VALIDITY CONDITION  (arithmetic only, no simulation)")
    print("=" * 78)
    print("The bound adds `refresh` exactly ONCE. That is only sound if the")
    print("whole acceptance-to-completion interval fits inside one refresh")
    print("window, i.e.  B_fixed + (N_out-1)*C_max + C_i  <=  window - refresh.")
    print(f"window_cycles = {WINDOW} (DownstreamEnvelope default).\n")
    total = ok = 0
    worst = []
    for cell in cells(quick):
        n_out, c_max, c_i, b_fixed, refresh = cell
        if c_i > c_max or refresh == 0:
            continue
        total += 1
        span = b_fixed + (n_out - 1) * c_max + c_i
        usable = WINDOW - refresh
        crossings = math.ceil(span / usable)
        if crossings <= 1:
            ok += 1
        else:
            worst.append((crossings, cell, span, usable))
    print(f"  cells with refresh>0 and C_i<=C_max : {total}")
    print(f"  cells satisfying the condition       : {ok}  ({100*ok/max(total,1):.1f}%)")
    print(f"  cells VIOLATING the condition        : {total-ok}  "
          f"({100*(total-ok)/max(total,1):.1f}%)")
    worst.sort(reverse=True)
    print("\n  worst offenders (refresh stalls the interval can actually meet):")
    for cr, cell, span, usable in worst[:6]:
        n_out, c_max, c_i, b_fixed, refresh = cell
        print(f"    N_out={n_out:<3d} C_max={c_max:<5d} C_i={c_i:<4d} "
              f"B={b_fixed:<4d} refresh={refresh:<4d} -> span={span} > "
              f"usable={usable}, up to {cr} stalls, bound counts 1")
    # the shipped operating point
    span = 32 + 3 * 512 + 144
    usable = WINDOW - 64
    print(f"\n  SHIPPED OPERATING POINT (N_out=4, C_max=512, C_i=144, B=32, "
          f"refresh=64):")
    print(f"    span = {span} cycles, usable per window = {usable} cycles, "
          f"stalls meetable = {math.ceil(span/usable)}")
    print(f"    the condition is "
          f"{'SATISFIED' if span <= usable else 'VIOLATED'} at the default "
          f"operating point.")
    out["refresh_validity"] = dict(total=total, ok=ok, violating=total - ok,
                                   default_span=span, default_usable=usable,
                                   default_ok=span <= usable)


# --------------------------------------------------------------------------
# 5. HEADLINE ADVERSARIAL CASE AT THE SHIPPED OPERATING POINT
# --------------------------------------------------------------------------


def headline(out: dict) -> None:
    n_out, c_max, c_i, b_fixed, refresh = 4, 512, 144, 32, 64
    bound = analytic_bound(n_out, c_max, c_i, b_fixed, refresh)
    print("\n" + "=" * 78)
    print("TASK 4  ADVERSARIAL AT THE SHIPPED OPERATING POINT   [SYNTHETIC]")
    print("=" * 78)
    print(f"  N_out={n_out} C_max={c_max} C_i={c_i} B_fixed={b_fixed} "
          f"refresh={refresh} window={WINDOW} bypass=0")
    print(f"  analytic bound = {b_fixed} + {n_out-1}*{c_max} + {c_i} + 0 + "
          f"{refresh} = {bound}\n")
    rows = []
    for m, (bm, rm) in MODES.items():
        lat, phase, trace = adversarial(n_out, c_max, c_i, b_fixed, refresh,
                                        WINDOW, bm, rm,
                                        phases=list(range(WINDOW)))
        rows.append((m, lat, phase, trace))
        flag = "EXCEEDS BOUND" if lat > bound else "within bound"
        print(f"  mode {m:<3} {MODE_DESC[m]:<52} observed={lat:<6d} "
              f"ratio={lat/bound:.4f}  {flag}   worst start phase t0={phase}")
    out["headline"] = {"bound": bound,
                       "modes": {m: dict(observed=l, phase=p, ratio=l / bound)
                                 for m, l, p, _ in rows}}
    # full trace of the literal mode
    m, lat, phase, trace = rows[0]
    print(f"\n  REPRODUCIBLE TRACE, mode L, start phase t0={phase} "
          f"(deterministic, no seed needed):")
    for r in trace:
        print(r.as_row())
    print(f"    probe acceptance-to-completion = {lat} cycles vs bound "
          f"{bound}  -> excess +{lat-bound}")

    # phase profile: how many phases violate
    lats = [adversarial(n_out, c_max, c_i, b_fixed, refresh, WINDOW,
                        "per_txn", "periodic", phases=[p])[0]
            for p in range(WINDOW)]
    bad = sum(1 for x in lats if x > bound)
    print(f"\n  over all {WINDOW} start phases in mode L: "
          f"min={min(lats)} max={max(lats)}; "
          f"{bad}/{WINDOW} phases exceed the bound "
          f"({100*bad/WINDOW:.1f}%)")
    lats2 = [adversarial(n_out, c_max, c_i, b_fixed, refresh, WINDOW,
                         "bp", "periodic", phases=[p])[0]
             for p in range(WINDOW)]
    bad2 = sum(1 for x in lats2 if x > bound)
    print(f"  over all {WINDOW} start phases in mode B2 (refresh defect ALONE, "
          f"B_fixed amortised): min={min(lats2)} max={max(lats2)}; "
          f"{bad2}/{WINDOW} phases exceed the bound ({100*bad2/WINDOW:.1f}%)")
    out["headline"]["phase_profile"] = dict(
        mode_L=dict(min=min(lats), max=max(lats), n_violating=bad, n=WINDOW),
        mode_B2=dict(min=min(lats2), max=max(lats2), n_violating=bad2, n=WINDOW))


# --------------------------------------------------------------------------
# 6. SENSITIVITY
# --------------------------------------------------------------------------


BASE = dict(n_out=4, c_max=512, c_i=144, b_fixed=32, refresh=64)


def sensitivity(out: dict) -> None:
    print("\n" + "=" * 78)
    print("TASK 3  SENSITIVITY   [SYNTHETIC]")
    print("=" * 78)

    # ---- term dominance as N_out grows
    print("\n(a) TERM DOMINANCE vs N_out   (C_max=512, C_i=144, B=32, refresh=64)")
    print(f"  {'N_out':>5} {'bound':>8} | {'B_fixed':>8} {'(N-1)Cmax':>10} "
          f"{'C_i':>6} {'refresh':>8} | share of the queueing term")
    dom = []
    for n in (1, 2, 4, 8, 16, 32, 64):
        b = analytic_bound(n, 512, 144, 32, 64)
        q = (n - 1) * 512
        dom.append((n, b, q / b))
        print(f"  {n:>5} {b:>8} | {32:>8} {q:>10} {144:>6} {64:>8} | "
              f"{100*q/b:>6.1f}%")
    out["dominance"] = [dict(n_out=n, bound=b, queue_share=s) for n, b, s in dom]
    print("  -> (N_out-1)*C_max dominates from N_out=2 upward; it is the only")
    print("     term that grows with N_out, so it asymptotes to 100%.")

    # ---- marginal effect of each of the five terms
    print("\n(b) MARGINAL EFFECT OF EACH TERM  d(bound)/dx  vs  d(observed)/dx")
    print("    observed = adversarial worst case over start phases")
    print(f"    base: {BASE}, window={WINDOW}, bypass=0")
    print(f"  {'term':<12} {'delta':>7} {'d(bound)':>10} {'d(obs) L':>10} "
          f"{'d(obs) F':>10}   note")
    marg = {}
    for term, delta in (("b_fixed", 32), ("c_max", 128), ("c_i", 64),
                        ("refresh", 64), ("n_out", 1), ("bypass", 1)):
        def ev(bump, mode):
            p = dict(BASE)
            byp = 0
            if term == "bypass":
                byp = bump
            else:
                p[term] += bump
            bm, rm = MODES[mode]
            b = analytic_bound(p["n_out"], p["c_max"], p["c_i"], p["b_fixed"],
                               p["refresh"], byp)
            l, _, _ = adversarial(p["n_out"], p["c_max"], p["c_i"],
                                  p["b_fixed"], p["refresh"], WINDOW, bm, rm,
                                  bypass=byp, phases=list(range(WINDOW)))
            return b, l
        b0, l0L = ev(0, "L")
        _, l0F = ev(0, "F")
        b1, l1L = ev(delta, "L")
        _, l1F = ev(delta, "F")
        db = (b1 - b0) / delta
        dlL = (l1L - l0L) / delta
        dlF = (l1F - l0F) / delta
        note = "MATCHES" if abs(db - dlL) < 1e-9 else \
               f"model moves {dlL/db:.1f}x faster than the bound" if db else "bound flat"
        marg[term] = dict(d_bound=db, d_obs_L=dlL, d_obs_F=dlF)
        print(f"  {term:<12} {delta:>7} {db:>10.3f} {dlL:>10.3f} {dlF:>10.3f}   {note}")
    out["marginal"] = marg

    # ---- when does the bound become useless
    print("\n(c) WHEN DOES THE BOUND BECOME USELESS IN PRACTICE?")
    print("    Criterion: gm/sim.py sets d_issue = deadline - L_down_max. Once")
    print("    L_down_max >= SLO, d_issue <= arrival and NOTHING is admissible.")
    print("    SLO reference is the repo's own trace generator, golden/traces.py")
    print("    line 122: deadline = t + svc_kv*uniform(8,16) with svc_kv=144,")
    print("    i.e. the latency-sensitive tenant's SLO is 1152..2304 cycles.")
    print("    Clock 301.03 MHz is MEASURED (docs/hil/smoke_test_01_jtag.md);")
    print("    the cycles->us conversion below uses it. Everything else here")
    print("    is SYNTHETIC.")
    clk = 301.03e6
    print(f"\n  {'N_out':>5} {'bound':>8} {'us @301MHz':>11} "
          f"{'vs SLO 1152':>12} {'vs SLO 2304':>12}")
    useless = {}
    for n in (1, 2, 3, 4, 5, 6, 8, 12, 16, 32):
        b = analytic_bound(n, 512, 144, 32, 64)
        us = b / clk * 1e6
        t1 = "USELESS" if b >= 1152 else "ok"
        t2 = "USELESS" if b >= 2304 else "ok"
        print(f"  {n:>5} {b:>8} {us:>11.3f} {t1:>12} {t2:>12}")
        useless[n] = dict(bound=b, us=us, useless_tight=b >= 1152,
                          useless_loose=b >= 2304)
    n1 = min(n for n in useless if useless[n]["useless_tight"])
    n2 = min(n for n in useless if useless[n]["useless_loose"])
    print(f"\n  -> against the TIGHTEST SLO in the repo (1152 cycles) the bound")
    print(f"     is already unusable at N_out={n1}.")
    print(f"  -> against the LOOSEST  SLO in the repo (2304 cycles) it is")
    print(f"     unusable at N_out={n2}.")
    print(f"  -> the shipped N_out=4 bound of 1776 cycles already consumes "
          f"{100*1776/1152:.0f}% of the tightest SLO and "
          f"{100*1776/2304:.0f}% of the loosest.")
    out["useless"] = dict(table=useless, n_useless_tight=n1, n_useless_loose=n2)

    # ---- heavy tail
    print("\n(d) IS THE C_max ASSUMPTION LOAD-BEARING? SERVICE DISTRIBUTION SWEEP")
    print("    mode F (bound-faithful) so the distribution is the ONLY variable.")
    print(f"  {'dist':<16} {'observed max':>13} {'bound':>8} {'ratio':>8}  verdict")
    n_out, c_max, c_i, b_fixed, refresh = (BASE["n_out"], BASE["c_max"],
                                           BASE["c_i"], BASE["b_fixed"],
                                           BASE["refresh"])
    bound = analytic_bound(n_out, c_max, c_i, b_fixed, refresh)
    dist_out = {}
    for dist in SVC_DISTS:
        over = 1.5 if dist == "pareto_over" else 1.0
        worst = 0
        for s in range(24):
            r = simulate(n_out, c_max, c_i, b_fixed, refresh, WINDOW,
                         "bp", "bp", seed=s, n_txn=1500, dist=dist,
                         rho=2.5, over_factor=over)
            worst = max(worst, r.max_probe_lat)
        v = "EXCEEDS" if worst > bound else "within"
        lbl = dist + (" x1.5 OVER" if dist == "pareto_over" else "")
        print(f"  {lbl:<16} {worst:>13} {bound:>8} {worst/bound:>8.3f}  {v}")
        dist_out[dist] = dict(observed=worst, bound=bound, ratio=worst / bound)
    print("  -> the envelope survives ANY distribution supported on [1, C_max],")
    print("     heavy-tailed or not: the bound only ever uses the SUPREMUM.")
    print("     Heavy tails change TIGHTNESS, not soundness. The single")
    print("     load-bearing assumption is the C_max cap itself.")

    # how the bound degrades as C_max is violated
    print("\n    degradation when the real service time exceeds C_max by a factor f")
    print(f"  {'f':>5} {'observed max':>13} {'bound':>8} {'ratio':>8}")
    deg = {}
    for f in (1.0, 1.1, 1.25, 1.5, 2.0, 4.0):
        worst = 0
        for s in range(24):
            r = simulate(n_out, c_max, c_i, b_fixed, refresh, WINDOW,
                         "bp", "bp", seed=s, n_txn=1500, dist="pareto_over",
                         rho=2.5, over_factor=f)
            worst = max(worst, r.max_probe_lat)
        deg[f] = worst
        print(f"  {f:>5.2f} {worst:>13} {bound:>8} {worst/bound:>8.3f}")
    print("  -> random heavy tails rarely sample the extreme, so they")
    print("     understate the damage. The ADVERSARIAL version follows.")

    print("\n    ADVERSARIAL C_max violation: every blocker takes f*C_max,")
    print("    mode F (the otherwise-unrefuted variant), bypass=0")
    print(f"  {'f':>5} {'blocker svc':>12} {'observed':>10} {'bound':>8} "
          f"{'ratio':>8}  verdict")
    adv_over = {}
    for f in (1.0, 1.01, 1.1, 1.25, 1.5, 2.0):
        bs = int(round(c_max * f))
        lat, _, _ = adversarial(n_out, c_max, c_i, b_fixed, refresh, WINDOW,
                                "bp", "bp", blocker_svc=bs,
                                phases=list(range(WINDOW)))
        v = "EXCEEDS" if lat > bound else "within"
        print(f"  {f:>5.2f} {bs:>12} {lat:>10} {bound:>8} "
              f"{lat/bound:>8.3f}  {v}")
        adv_over[f] = dict(blocker_svc=bs, observed=lat, ratio=lat / bound)
    print("  -> ANY f > 1 breaks the bound adversarially, by exactly")
    print("     (N_out-1)*C_max*(f-1) cycles. The C_max cap is the single")
    print("     load-bearing assumption and it is amplified N_out-1 times:")
    print("     one unmodelled slow transfer is not a local error.")
    out["adv_cmax_violation"] = {str(k): v for k, v in adv_over.items()}
    out["dists"] = dist_out
    out["cmax_degradation"] = {str(k): v for k, v in deg.items()}


# --------------------------------------------------------------------------
# 7. BYPASS TERM
# --------------------------------------------------------------------------


def bypass_check(out: dict) -> None:
    print("\n" + "=" * 78)
    print("BYPASS TERM   bypass_count * C_max   [SYNTHETIC]")
    print("=" * 78)
    print("bypass_count = 0 is a MODEL ASSUMPTION (see report Task 5). The")
    print("arithmetic of the term itself is checked here for bypass = 0..3.")
    print(f"  {'bypass':>6} {'bound':>8} {'obs mode F':>11} {'ratio':>7} "
          f"{'obs mode L':>11} {'ratio':>7}")
    rows = {}
    for byp in (0, 1, 2, 3):
        b = analytic_bound(BASE["n_out"], BASE["c_max"], BASE["c_i"],
                           BASE["b_fixed"], BASE["refresh"], byp)
        lF, _, _ = adversarial(BASE["n_out"], BASE["c_max"], BASE["c_i"],
                               BASE["b_fixed"], BASE["refresh"], WINDOW,
                               "bp", "bp", bypass=byp,
                               phases=list(range(WINDOW)))
        lL, _, _ = adversarial(BASE["n_out"], BASE["c_max"], BASE["c_i"],
                               BASE["b_fixed"], BASE["refresh"], WINDOW,
                               "per_txn", "periodic", bypass=byp,
                               phases=list(range(WINDOW)))
        print(f"  {byp:>6} {b:>8} {lF:>11} {lF/b:>7.3f} {lL:>11} {lL/b:>7.3f}")
        rows[byp] = dict(bound=b, obs_F=lF, obs_L=lL)
    print("  -> under mode F the bypass term is exact (ratio 1.000): each")
    print("     bypassing transaction contributes exactly one more C_max.")
    out["bypass"] = rows


# --------------------------------------------------------------------------
# 8. CORRECTED BOUND
# --------------------------------------------------------------------------


def corrected_check(quick: bool, out: dict) -> None:
    print("\n" + "=" * 78)
    print("PROPOSED CORRECTED BOUND, CHECKED ON THE SAME GRID   [SYNTHETIC]")
    print("=" * 78)
    print("  w   = N_out*B_fixed + (N_out-1+bypass)*C_max + bypass*B_fixed + C_i")
    print("  u   = window - refresh")
    print("  L  <=  w + refresh * ceil(w / u)")
    ok, bad = check_stall_lemma([1, 2, 63, 64, 65, 500, 959, 960, 961, 1712,
                                 1920, 1921, 5000, 15904], [1024, 512])
    print(f"\n  refresh-inflation lemma, exhaustive over every start phase: "
          f"{'EXACT' if ok else 'FAILED'}")
    if bad:
        for b in bad[:5]:
            print(f"    MISMATCH window={b[0]} refresh={b[1]} w={b[2]} "
                  f"brute={b[3]} formula={b[4]}")
    n_cells = n_viol = 0
    worst_ratio = 0.0
    for cell in cells(quick):
        n_out, c_max, c_i, b_fixed, refresh = cell
        if c_i > c_max:
            continue
        n_cells += 1
        cb = corrected_bound(n_out, c_max, c_i, b_fixed, refresh, WINDOW)
        lat, _, _ = adversarial(n_out, c_max, c_i, b_fixed, refresh, WINDOW,
                                "per_txn", "periodic")
        if lat > cb:
            n_viol += 1
            print(f"    CORRECTED BOUND VIOLATED at {cell}: obs={lat} cb={cb}")
        worst_ratio = max(worst_ratio, lat / cb)
    print(f"\n  cells checked (mode L, adversarial): {n_cells}")
    print(f"  corrected-bound violations          : {n_viol}")
    print(f"  tightest observed/corrected ratio   : {worst_ratio:.4f}")
    cb_def = corrected_bound(4, 512, 144, 32, 64, WINDOW)
    print(f"\n  at the shipped operating point the corrected bound is "
          f"{cb_def} cycles, versus {analytic_bound(4,512,144,32,64)} asserted "
          f"(+{cb_def - analytic_bound(4,512,144,32,64)} cycles, "
          f"{cb_def/analytic_bound(4,512,144,32,64):.2f}x).")
    out["corrected"] = dict(lemma_exact=ok, cells=n_cells, violations=n_viol,
                            worst_ratio=worst_ratio, default=cb_def)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--seeds", type=int, default=10)
    ap.add_argument("--ntxn", type=int, default=400)
    ap.add_argument("--json", default=None)
    a = ap.parse_args()

    out: dict = {"SYNTHETIC": True,
                 "note": "validation of arithmetic against a queueing model; "
                         "not a hardware measurement"}

    print("=" * 78)
    print("validate_ldownmax.py   INDEPENDENT VALIDATION   ALL OUTPUT SYNTHETIC")
    print("=" * 78)
    ok, msg, n = cross_check_against_artefact()
    print(f"\nTASK 1 PRE-CHECK: analytic_bound() vs gm.types "
          f"DownstreamEnvelope.l_down_max()")
    print(f"  {n} parameter combinations compared: "
          f"{'IDENTICAL' if ok else 'DIVERGED -> ' + msg}")
    print("  (gm/data_plane.py is NOT imported anywhere in this file.)")
    out["formula_cross_check"] = dict(ok=ok, n=n, msg=msg)

    e = analytic_bound(4, 512, 144, 32, 64)
    print(f"\n  spot check of the quoted headline: "
          f"analytic_bound(N_out=4, C_max=512, C_i=144, B=32, refresh=64) = {e}")
    assert e == 1776, e

    print("\nVALIDATOR SELF-TEST (the validator is checked before it judges)")
    fails = selftest()
    for f in fails:
        print(f"  FAIL: {f}")
    print(f"  7 self-test groups, failures: {len(fails)}"
          f"{'  -> SELF-TEST PASSED' if not fails else '  -> SELF-TEST FAILED'}")
    out["selftest"] = dict(failures=fails, passed=not fails)
    if fails:
        print("  refusing to report results from a validator that fails its "
              "own checks")
        return 1

    refresh_validity(a.quick, out)
    headline(out)
    run_grid(a.quick, a.seeds, a.ntxn, out)
    sensitivity(out)
    bypass_check(out)
    corrected_check(a.quick, out)

    print("\n" + "=" * 78)
    print("SCOPE STATEMENT (repeated in LDOWNMAX_VALIDATION.md, Task 5)")
    print("=" * 78)
    print("This is validation of the ARITHMETIC against a queue/service model.")
    print("It is NOT proof of the ZCU104 PS DDR controller's universal")
    print("worst-case response time. No hardware was involved. bypass_count=0")
    print("is a MODEL ASSUMPTION, not an established property of the ZCU104 PS")
    print("DDR path.")

    if a.json:
        with open(a.json, "w") as f:
            json.dump(out, f, indent=2, default=str)
        print(f"\nJSON written to {a.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
