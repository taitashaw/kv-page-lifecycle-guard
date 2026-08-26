"""Simulator with a FIXED measurement horizon shared by every policy."""
from __future__ import annotations

from dataclasses import dataclass, field

from .checks import Checks
from .control_plane import ControlPlane
from .coverage import Coverage
from .data_plane import DataPlane
from .policies import BY_NAME
from .types import DownstreamEnvelope, Params, SafetyViolation, TrafficClass


@dataclass
class Result:
    policy: str = ""
    offered: int = 0
    admitted: int = 0
    rejected: int = 0
    accepted: int = 0
    completed: int = 0
    cancelled: int = 0
    censored: int = 0
    on_time: int = 0            # COMPLETE by d_SLO
    issue_on_time: int = 0      # AXI_ACCEPT by d_issue
    horizon: int = 0
    ddr_util: float = 0.0
    envelope_held: bool = True
    violations: list = field(default_factory=list)
    coverage: dict = field(default_factory=dict)
    accept_latency: list = field(default_factory=list)

    def summary(self):
        lat = sorted(self.accept_latency)
        q = lambda f: lat[min(len(lat) - 1, int(f * len(lat)))] if lat else 0
        pct = lambda n, d: round(100.0 * n / d, 2) if d else 0.0
        return {"policy": self.policy, "offered": self.offered,
                "admitted": self.admitted, "rejected": self.rejected,
                "accepted": self.accepted, "completed": self.completed,
                "cancelled": self.cancelled, "censored": self.censored,
                "on_time": self.on_time,
                "issue_on_time": self.issue_on_time,
                "on_time_per_offered_%": pct(self.on_time, self.offered),
                "horizon": self.horizon,
                "ddr_util_%": round(100.0 * self.ddr_util, 2),
                "p99_accept_latency": q(0.99),
                "envelope_held": self.envelope_held,
                "violations": sorted({v.kind for v in self.violations}),
                "coverage": self.coverage}


def run(policy_name, params: Params, requests, envelope: DownstreamEnvelope,
        horizon: int, strict: bool = False) -> Result:
    """`horizon` is FIXED across policies. A policy that rejects more work and
    drains earlier must not be able to show inflated utilisation."""
    checks = Checks(params, strict=strict)
    cov = Coverage()
    cp = ControlPlane(params, checks, cov)
    dp = DataPlane(params, envelope, checks)
    cp.dp = dp
    pol = BY_NAME[policy_name](params, envelope)

    fetches = [r for r in requests if not getattr(r, "is_release", False)]
    # right-censoring guard, applied IDENTICALLY to every policy
    uncensored = [r for r in fetches if r.deadline <= horizon]
    res = Result(policy=policy_name, offered=len(uncensored), horizon=horizon)
    res.censored = len(fetches) - len(uncensored)

    idx, pending = 0, list(requests)
    envelope_held = True

    for cycle in range(horizon):
        for d in dp.tick_complete(cycle):
            cp.on_complete(d, cycle)

        for d in dp.cancel_stale_speculation(cycle):
            cp.on_cancel_pre_issue(d, cycle)

        dp.replenish(cycle)

        while idx < len(pending) and pending[idx].arrival <= cycle:
            req = pending[idx]; idx += 1
            if getattr(req, "is_release", False):
                cp.release_ref(req.tenant_id, req.obj_type, req.key, cycle)
                continue
            c_i = -(-req.n_bytes // params.axi_bytes_per_cycle)
            l_dm = envelope.l_down_max(params.max_axi_outstanding, c_i)
            d_issue = req.deadline - l_dm
            ok = pol.feasible(req, cycle, cp, dp, d_issue)
            d = cp.admit(req, cycle, ok, l_dm)
            if d is None:
                res.rejected += 1
                continue
            res.admitted += 1
            dp.enqueue(d)

        dp.tick_dispatch(cycle)
        for d in dp.tick_accept(cycle):
            cp.on_axi_accept(d, cycle)

        cov.sample(cp, dp, cycle)
        try:
            checks.per_cycle(cp, dp, cycle, envelope_held)
        except SafetyViolation as v:
            res.violations.append(v)
            break

    for d in cp.all_desc:
        if d.slo_deadline > horizon:
            continue                       # censored: cannot succeed or fail
        if d.accepted:
            res.accepted += 1
            res.accept_latency.append(d.accept_cycle - d.arrival)
            if d.tclass is TrafficClass.MANDATORY and d.accept_cycle <= d.issue_deadline:
                res.issue_on_time += 1
        if d.completed:
            res.completed += 1
            if d.complete_cycle <= d.slo_deadline:
                res.on_time += 1
        if d.cancelled:
            res.cancelled += 1

    res.ddr_util = dp.busy_cycles / horizon if horizon else 0.0
    res.envelope_held = envelope_held
    res.coverage = cov.as_dict()
    res.violations.extend(v for v in checks.fired if v not in res.violations)
    return res
