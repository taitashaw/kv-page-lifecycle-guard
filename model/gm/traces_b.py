"""Sweep B capacity-contended trace generator. POLICY-NEUTRAL by construction.

Nothing in this file may read, import or branch on a policy. The trace, the
parameters, the envelope and the measurement horizon are all inputs to
`gm.sim.run`, never outputs of it. That is what makes the horizon fixed across
policies rather than a function of policy behaviour.

Three tenants, deliberately concrete:

    tenant 0  interactive voice / chat   short deadlines, actively HELD KV pages
    tenant 1  coding assistant           longer context, medium deadlines
    tenant 2  batch summariser           speculative EXPERT prefetch

Held pages and the draining state
---------------------------------
A `held` fetch emits ACQUIRE at admission. Every held fetch is paired with a
later RELEASE request, and the hold durations are drawn so that a deliberate
fraction of releases land while the transfer is STILL IN FLIGHT. That is the
only way to reach

    logical_refcount == 0  AND  inflight > 0

which the contract defines as DRAINING. A release that lands before AXI
acceptance leaves the page merely reserved, not draining, so a single fixed
hold length would not reliably reach the state. Three hold bands are therefore
generated (see `_hold_cycles`), spanning pre-accept, mid-transfer and
long-after-completion.

Deadlines and the downstream envelope
-------------------------------------
`DownstreamEnvelope.l_down_max` is a DECLARED worst case, and at the frozen
envelope it is 1768 cycles for a 2176-byte KV page. An SLO shorter than that is
infeasible for every policy by construction and would make the whole grid
degenerate, so the SLO explicitly budgets for it:

    SLO_i        = L_down,max,i  +  slack * headroom_i
    d_SLO_i      = A_i + SLO_i
    d_issue,i    = d_SLO_i - L_down,max,i  =  A_i + slack * headroom_i

The deadline-slack axis therefore scales the CONTROLLER-side headroom, which is
exactly the quantity every admission predicate tests against. `headroom_i` is
per-tenant and fixed.

Working set
-----------
`ws_ratio` sets the number of DISTINCT objects as a multiple of the frame pool.
Objects are keyed by `(tenant, obj_type, key)` in the control plane, so key
indices are partitioned by ownership rather than reused across tenants; a page
belongs to exactly one session. Without that partition a nominal working set of
`ws` would produce `2*ws` distinct objects and `ws_ratio` would not mean what it
says.

Measurement horizon
-------------------
`measurement_horizon` is derived from the trace alone: the latest completion
deadline plus one declared downstream worst case, so a transfer accepted at the
last deadline can still be observed to completion. Every fetch therefore has
`deadline <= horizon` and the right-censoring guard in `gm.sim.run` excludes
NOTHING. The runner still reports the censored count rather than assuming it.
"""
from __future__ import annotations

import random
from dataclasses import dataclass

from .types import DownstreamEnvelope, ObjType, Params, TrafficClass

# ------------------------------------------------------------------ constants
# Frozen with the generator. Changing any of these changes the config hash and
# therefore the run identity.

KV_BYTES = 2176            # one KV page, interactive and coding tenants
EXPERT_BYTES = 4096        # one expert shard, speculative prefetch
N_REQ_DEFAULT = 200        # requests per trace, per FROZEN_SWEEP_PLAN.md

#: controller-side headroom before the slack multiplier, in KV service times
HEADROOM_SVC = {0: 2.0, 1: 6.0, 2: 40.0}

#: split of mandatory traffic between the interactive and coding tenants
P_INTERACTIVE = 0.6

#: share of held pages whose release is aimed INSIDE the in-flight window
P_RELEASE_IN_FLIGHT = 0.5

TENANT_INTERACTIVE, TENANT_CODING, TENANT_BATCH = 0, 1, 2


@dataclass
class Request:
    """The request record consumed by `gm.sim.run`.

    `is_release` marks a RELEASE event, which carries no bytes and no deadline
    of its own; `gm.sim.run` routes it to `ControlPlane.release_ref` and
    excludes it from the offered count.
    """
    arrival: int
    tenant_id: int
    obj_type: ObjType
    key: int
    tclass: TrafficClass
    n_bytes: int
    deadline: int
    held: bool = False
    is_release: bool = False


# ------------------------------------------------------------------ helpers

def _beats(n_bytes: int, params: Params) -> int:
    return -(-n_bytes // params.axi_bytes_per_cycle)


def _service(n_bytes: int, params: Params) -> int:
    """Occupancy of the DDR path for one transfer, excluding queueing."""
    return _beats(n_bytes, params) + params.axi_fixed_overhead_cycles


def _key_owner_table(n_kv_keys: int, rng: random.Random) -> list[int]:
    """Deterministic key -> tenant ownership. A KV page belongs to one session."""
    owners = []
    for k in range(n_kv_keys):
        owners.append(TENANT_INTERACTIVE if rng.random() < P_INTERACTIVE
                      else TENANT_CODING)
    # guarantee both mandatory tenants are represented whenever there is room,
    # so the tenant axis never silently collapses at small working sets
    if n_kv_keys >= 2:
        owners[0] = TENANT_INTERACTIVE
        owners[1] = TENANT_CODING
    return owners


def _hold_cycles(rng: random.Random, params: Params, envelope: DownstreamEnvelope,
                 n_bytes: int) -> int:
    """Hold duration for a held page, in cycles after the fetch arrival.

    Three bands, all policy-neutral because they are derived from the declared
    envelope and the transfer size, never from an observed schedule:

    band A  in-flight   accept overhead + fixed overhead + part of the burst.
                        Under light queueing this lands between AXI_ACCEPT and
                        COMPLETE, which is exactly the DRAINING window.
    band B  queued      up to one declared downstream worst case. Under heavy
                        queueing the transfer is accepted late, so this band is
                        the one that lands in flight instead.
    band C  long        many service times. The page stays non-evictable well
                        past completion; this is what produces sustained
                        temporarily-non-evictable pressure.

    Bands A and B together are the `P_RELEASE_IN_FLIGHT` share. Spreading across
    two bands rather than picking one is deliberate: the accept time moves with
    offered load, and the generator is forbidden from measuring it.
    """
    svc = _service(n_bytes, params)
    accept_floor = params.axi_accept_overhead_cycles + params.axi_fixed_overhead_cycles
    if rng.random() < P_RELEASE_IN_FLIGHT:
        if rng.random() < 0.5:
            # band A: mid-burst for an unqueued transfer
            lo = accept_floor + 1
            hi = accept_floor + max(2, _beats(n_bytes, params))
            return rng.randint(lo, hi)
        # band B: inside the burst of a transfer that queued first
        lo = accept_floor + svc
        hi = accept_floor + envelope.l_down_max(params.max_axi_outstanding,
                                                _beats(n_bytes, params))
        return rng.randint(lo, max(lo + 1, hi))
    # band C: long hold, non-evictable well past completion
    return int(svc * rng.uniform(6.0, 20.0)) + accept_floor


# ------------------------------------------------------------------ generator

def capacity_contended(frames: int, ws_ratio: float, nonevict_frac: float,
                       load: float, spec_share: float, slack: float, seed: int,
                       n_req: int = N_REQ_DEFAULT):
    """Build one capacity-contended trace.

    Returns `(params, envelope, requests, horizon, meta)`. `meta` is a plain
    dict of trace-derived facts that the runner records alongside the results;
    none of it is used to select or exclude anything.
    """
    if not 0.0 < load < 1.0:
        raise ValueError(f"offered load must be in (0,1), got {load}")
    if not 0.0 <= spec_share < 1.0:
        raise ValueError(f"speculative share must be in [0,1), got {spec_share}")
    if not 0.0 <= nonevict_frac <= 1.0:
        raise ValueError(f"non-evictable fraction must be in [0,1], got {nonevict_frac}")
    if frames < 1 or n_req < 1:
        raise ValueError("frames and n_req must be positive")

    params = Params(
        n_tenants=3,
        n_frames=frames,
        n_descriptors=max(8, frames),
        n_reserved_mandatory_desc=1,
        n_meta_entries=max(32, frames * 4),
        dispatch_queue_depth=8,
        max_axi_outstanding=4,
        axi_bytes_per_cycle=16,
        axi_accept_overhead_cycles=4,
        axi_fixed_overhead_cycles=8,
        dwrr_quantum_bytes=8192,
        dwrr_replenish_period=256,
        dwrr_max_deficit_bytes=32768,
        spec_bucket_burst_bytes=1 << 15,
        spec_bucket_refill_per_cycle=4,
        speculative_max_wait=4096,
    )
    envelope = DownstreamEnvelope()          # frozen declared service envelope

    svc_kv = _service(KV_BYTES, params)
    l_dm_kv = envelope.l_down_max(params.max_axi_outstanding,
                                  _beats(KV_BYTES, params))
    l_dm_exp = envelope.l_down_max(params.max_axi_outstanding,
                                   _beats(EXPERT_BYTES, params))

    # ---- working set, partitioned so distinct objects == ws exactly
    ws = max(1, int(round(frames * ws_ratio)))
    if spec_share > 0.0:
        n_expert_keys = max(1, int(round(ws * 0.25)))
        n_kv_keys = max(1, ws - n_expert_keys)
    else:
        n_expert_keys, n_kv_keys = 0, ws

    rng = random.Random((seed << 16) ^ (frames * 8191) ^ int(ws_ratio * 1000))
    owners = _key_owner_table(n_kv_keys, rng)

    # ---- arrival process sized to the requested OFFERED load on the AXI path
    mean_bytes = (1.0 - spec_share) * KV_BYTES + spec_share * EXPERT_BYTES
    mean_gap = mean_bytes / (params.axi_bytes_per_cycle * load)

    reqs: list[Request] = []
    n_held = 0
    n_spec = 0
    t = 0
    for _ in range(n_req):
        t += max(1, int(rng.expovariate(1.0 / mean_gap)))

        if n_expert_keys and rng.random() < spec_share:
            # batch summariser: speculative expert prefetch
            slo = l_dm_exp + int(slack * HEADROOM_SVC[TENANT_BATCH] * svc_kv)
            reqs.append(Request(
                arrival=t, tenant_id=TENANT_BATCH, obj_type=ObjType.EXPERT,
                key=rng.randrange(n_expert_keys),
                tclass=TrafficClass.SPECULATIVE, n_bytes=EXPERT_BYTES,
                deadline=t + slo))
            n_spec += 1
            continue

        key = rng.randrange(n_kv_keys)
        tenant = owners[key]
        slo = l_dm_kv + int(slack * HEADROOM_SVC[tenant] * svc_kv)
        deadline = t + slo
        held = rng.random() < nonevict_frac
        reqs.append(Request(
            arrival=t, tenant_id=tenant, obj_type=ObjType.KV_PAGE, key=key,
            tclass=TrafficClass.MANDATORY, n_bytes=KV_BYTES,
            deadline=deadline, held=held))
        if held:
            # EVERY held fetch is paired with a release. Without the pair the
            # page is permanently non-evictable and the pool leaks.
            n_held += 1
            hold = _hold_cycles(rng, params, envelope, KV_BYTES)
            reqs.append(Request(
                arrival=t + hold, tenant_id=tenant, obj_type=ObjType.KV_PAGE,
                key=key, tclass=TrafficClass.MANDATORY, n_bytes=0,
                deadline=t + hold, is_release=True))

    # fetch before release within one cycle, so an ACQUIRE can never be
    # preceded by its own RELEASE
    reqs.sort(key=lambda r: (r.arrival, r.is_release, r.tenant_id,
                             int(r.obj_type), r.key))

    horizon = measurement_horizon(reqs, max(l_dm_kv, l_dm_exp))

    fetches = [r for r in reqs if not r.is_release]
    meta = {
        "n_requests": len(reqs),
        "n_fetches": len(fetches),
        "n_releases": len(reqs) - len(fetches),
        "n_held_fetches": n_held,
        "n_speculative": n_spec,
        "n_mandatory": len(fetches) - n_spec,
        "distinct_objects": n_kv_keys + n_expert_keys,
        "n_kv_keys": n_kv_keys,
        "n_expert_keys": n_expert_keys,
        "ws_target": ws,
        "last_arrival": max((r.arrival for r in reqs), default=0),
        "max_fetch_deadline": max((r.deadline for r in fetches), default=0),
        "l_down_max_kv": l_dm_kv,
        "l_down_max_expert": l_dm_exp,
        "svc_kv_cycles": svc_kv,
        "mean_gap_cycles": round(mean_gap, 3),
        "horizon": horizon,
        # censoring is ZERO BY CONSTRUCTION here; the runner verifies it from
        # the simulator's own count rather than trusting this line
        "expected_censored": sum(1 for r in fetches if r.deadline > horizon),
        "label": (f"capB[F={frames} ws={ws_ratio} ne={nonevict_frac} "
                  f"load={load} spec={spec_share} slack={slack} seed={seed}]"),
    }
    return params, envelope, reqs, horizon, meta


def measurement_horizon(requests, l_down_max_tail: int) -> int:
    """FIXED horizon, computed from the trace and NOTHING else.

    The latest completion deadline plus one declared downstream worst case, so a
    transfer accepted at the last deadline can still be observed to completion.
    No policy influences this value, and every policy is measured over exactly
    the same interval.
    """
    fetch_deadlines = [r.deadline for r in requests if not r.is_release]
    last_arrival = max((r.arrival for r in requests), default=0)
    latest = max(max(fetch_deadlines, default=0), last_arrival)
    return int(latest + l_down_max_tail + 1)
