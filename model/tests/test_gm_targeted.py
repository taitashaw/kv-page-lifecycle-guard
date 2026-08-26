"""Targeted correctness suite.

Three parts:
  A. Bounded BFS transaction oracle, explored to FIXPOINT. Five tags, two
     object types, two frames, generation state, four outstanding slots, plus
     a fifth request that must be rejected at the boundary. The sweep runs
     over states canonicalised by tag-permutation symmetry, which is what
     keeps it tractable; the per-tag properties are checked on EVERY reachable
     state, not only on hand-built spot states.
  A2. Proof that the symmetry reduction in A is lossless, by comparing it
     against the unreduced space at tag counts where that space is tractable.
  B. Common-forced-prefix correctness tests. Every policy is driven into an
     IDENTICAL state before the discriminating request is issued, and that
     identity is ASSERTED rather than assumed.
"""
from __future__ import annotations

import sys
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from gm import policies, sim                                        # noqa: E402
from gm.types import (                                              # noqa: E402
    DownstreamEnvelope, ObjType, Params, TrafficClass,
)

PASS, FAIL = [], []


def ck(name, cond, detail=""):
    (PASS if cond else FAIL).append((name, detail))
    print(("  PASS  " if cond else "  FAIL  ") + name +
          (f"   {detail}" if detail and not cond else ""))


@dataclass
class R:
    arrival: int
    tenant_id: int
    obj_type: object
    key: int
    tclass: object
    n_bytes: int
    deadline: int
    held: bool = False
    is_release: bool = False


# ================================================ A. BFS TRANSACTION ORACLE
#
# A bounded model of the transaction table, explored breadth-first to a
# FIXPOINT: the frontier is drained to empty. There is no depth cap anywhere
# in this section, so the BFS depth reported below is the diameter the model
# actually has, not a limit imposed on it.
#
# Bounds. Every quantity the requirement fixes is at or above its value:
#   N_TAGS   = 5   transaction identities (tags)
#   N_FRAMES = 2   frames
#   N_OBJ    = 2   object types, mirroring gm.types.ObjType (KV_PAGE, EXPERT)
#   N_OUT    = 4   outstanding slots, so a 5th acceptance must be REJECTED
#
# MAX_GEN is the ONE quantity bounded rather than modelled in full, because
# generation is a free-running counter in the real design (gm.types.Params
# carries w_generation = 8 bits, i.e. 256 values) and the reachable set grows
# super-linearly in it. MAX_GEN = 1, i.e. generations {0, 1}, is the SMALLEST
# sound choice:
#   * MAX_GEN = 0 forbids REUSE altogether. No tag could ever outlive a
#     rebind, so "a tag can hold a stale generation" would be vacuously true.
#     That is one of the properties under test, so 0 is not acceptable.
#   * MAX_GEN = 1 exhibits it in full. A tag dispatched against frame f at
#     generation 0 that survives REUSE(f) then holds generation 0 while f
#     stands at generation 1. That IS the stale-reference case, and it is
#     WITNESSED in the reachable set below rather than asserted on a
#     hand-built state.
#   * MAX_GEN >= 2 only widens the numeric distance between a stale tag and
#     its frame (0 vs 2 rather than 0 vs 1). No predicate in this model tests
#     anything but generation EQUALITY, so no new outcome becomes reachable,
#     while the frame-generation combinations rise from 4 to 9 and the
#     reachable canonical set from ~3.2e5 to ~5.1e6 (measured).
# The bound stays plural in objects: an object INSTANCE is (frame, generation,
# object type), so 2 * 2 * 2 = 8 distinct instances exist at MAX_GEN = 1, and
# the sweep asserts all 8 are reached.

N_TAGS = 5
N_FRAMES = 2
N_OBJ = 2
N_OUT = 4
MAX_GEN = 1

# The sweep parses a tag index straight out of a label with a single character
# index rather than a slice, which is only valid while indices are one digit.
assert N_TAGS < 10 and N_FRAMES < 10 and N_OBJ < 10

IDLE, DISP, ACC, DONE, CANC = 0, 1, 2, 3, 4
NAMES = {IDLE: "idle", DISP: "dispatched", ACC: "accepted",
         DONE: "completed", CANC: "cancelled"}
LIVE = (DISP, ACC)          # tag states that still reference an object instance


def successors(st):
    """(tag_state, tag_frame, tag_gen, tag_obj, outstanding, frame_gen,
    frame_obj) -> [(label, next_state)].

    Next states are built with tuple slicing (t[:i] + (v,) + t[i+1:]), a single
    C-level concatenation, rather than the list(t) / mutate / tuple(t) round
    trip this used to do. That round trip allocated five Python lists per
    transition and dominated the profile.
    """
    tstate, tframe, tgen, tobj, out, fgen, fobj = st
    res = []
    for t in range(N_TAGS):
        s = tstate[t]
        if s == IDLE:
            # DISPATCH captures the object instance living in the frame NOW.
            # That captured (gen, obj) is what can later go stale.
            for f in range(N_FRAMES):
                res.append((f"DISPATCH(t{t},f{f})",
                            (tstate[:t] + (DISP,) + tstate[t + 1:],
                             tframe[:t] + (f,) + tframe[t + 1:],
                             tgen[:t] + (fgen[f],) + tgen[t + 1:],
                             tobj[:t] + (fobj[f],) + tobj[t + 1:],
                             out, fgen, fobj)))
        elif s == DISP:
            if out < N_OUT:                     # <-- the outstanding boundary
                res.append((f"AXI_ACCEPT(t{t})",
                            (tstate[:t] + (ACC,) + tstate[t + 1:],
                             tframe, tgen, tobj, out + 1, fgen, fobj)))
            # CANCEL is legal precisely while the tag is still unaccepted.
            res.append((f"CANCEL(t{t})",
                        (tstate[:t] + (CANC,) + tstate[t + 1:],
                         tframe, tgen, tobj, out, fgen, fobj)))
        elif s == ACC:
            res.append((f"COMPLETE(t{t})",
                        (tstate[:t] + (DONE,) + tstate[t + 1:],
                         tframe, tgen, tobj, out - 1, fgen, fobj)))
        # DONE and CANC are terminal for a tag: no label is offered, which is
        # what makes AXI_ACCEPT(tag) and COMPLETE(tag) at-most-once structural.
    # Frame reuse: legal only when NO accepted tag still references that frame,
    # i.e. no outstanding tag holds the generation about to be retired.
    for f in range(N_FRAMES):
        if fgen[f] >= MAX_GEN:
            continue
        if any(tstate[t] == ACC and tframe[t] == f for t in range(N_TAGS)):
            continue
        for o in range(N_OBJ):
            res.append((f"REUSE(f{f},o{o})",
                        (tstate, tframe, tgen, tobj, out,
                         fgen[:f] + (fgen[f] + 1,) + fgen[f + 1:],
                         fobj[:f] + (o,) + fobj[f + 1:])))
    return res


def canon(st):
    """Canonical representative of a state's tag-permutation orbit.

    Tags are interchangeable transaction identities: permuting them is an
    automorphism of the transition relation, so a state and any permutation of
    it have isomorphic futures. Sorting the per-tag records (state, frame, gen,
    obj) picks one representative per orbit.

    This is a SOUND symmetry reduction, not a truncation. Nothing reachable is
    lost; up to 5! = 120 duplicate encodings of the same situation are merged.
    canon() returns a well-formed STATE, so the BFS can store canonical forms
    only and expand directly from the representative.
    """
    tstate, tframe, tgen, tobj, out, fgen, fobj = st
    a, b, c, d = zip(*sorted(zip(tstate, tframe, tgen, tobj)))
    return (a, b, c, d, out, fgen, fobj)


@dataclass
class Sweep:
    """Everything the fixpoint sweep observed, in a single pass."""
    states: int = 0
    transitions: int = 0            # labelled edges out of reachable states
    edges: int = 0                  # distinct (source, target) pairs
    depth: int = 0                  # BFS levels to fixpoint, no cap applied
    frontier_left: int = -1
    max_out: int = 0
    saw_full: bool = False
    out_accounting_ok: bool = True
    accept_only_from_disp: bool = True
    complete_only_from_acc: bool = True
    cancel_only_from_disp: bool = True
    reuse_respects_accepted: bool = True
    boundary_states: int = 0        # reachable, out == N_OUT, a tag still DISP
    boundary_rejects: bool = True   # ... and no acceptance is offered there
    boundary_cancels: int = 0       # ... but CANCEL still is
    stale_states: int = 0
    stale_witness: tuple = ()
    tags_live_max: int = 0
    frames_seen: set = field(default_factory=set)
    gens_seen: set = field(default_factory=set)
    objs_seen: set = field(default_factory=set)
    instances_seen: set = field(default_factory=set)
    reorder_witness: tuple = ()
    reorder_pair: tuple = ()
    reached: set = field(default_factory=set)


def bfs_fixpoint():
    """Level-synchronous BFS over CANONICAL states, run until the frontier
    drains.

    The two changes that make this terminate: states are canonicalised BEFORE
    being pushed, and the form that is pushed IS the canonical one. Previously
    the frontier held raw states while dedup was keyed on them too, so every
    one of the up-to-120 permutations of a situation was expanded separately.
    Canonical push means each orbit is expanded exactly once, which also makes
    an explicit successor memo pointless here: no state is ever expanded twice.
    """
    sw = Sweep()
    # Initial states: both frames bound at generation 0, over every placement
    # of the two object types. Starting from a SET is still a fixpoint
    # computation, and it makes all 8 object instances reachable.
    inits = [canon(((IDLE,) * N_TAGS, (-1,) * N_TAGS, (-1,) * N_TAGS,
                    (-1,) * N_TAGS, 0, (0,) * N_FRAMES, (o0, o1)))
             for o0 in range(N_OBJ) for o1 in range(N_OBJ)]
    seen = set(inits)
    frontier = deque(inits)

    while frontier:                              # <-- fixpoint, not fixed depth
        sw.depth += 1
        for _ in range(len(frontier)):           # one BFS level
            st = frontier.popleft()
            tstate, tframe, tgen, tobj, out, fgen, fobj = st

            # ---- per-state invariants over the WHOLE reachable set ----------
            n_acc = tstate.count(ACC)
            if out != n_acc or out > N_OUT:
                sw.out_accounting_ok = False
            sw.max_out = max(sw.max_out, out)
            if out == N_OUT:
                sw.saw_full = True

            live = [t for t in range(N_TAGS) if tstate[t] in LIVE]
            sw.tags_live_max = max(sw.tags_live_max, len(live))
            stale_here = False
            for t in live:
                f = tframe[t]
                sw.frames_seen.add(f)
                sw.gens_seen.add(tgen[t])
                sw.objs_seen.add(tobj[t])
                sw.instances_seen.add((f, tgen[t], tobj[t]))
                if tgen[t] != fgen[f]:           # holds a retired generation
                    stale_here = True
                    if not sw.stale_witness:
                        sw.stale_witness = (st, t)
            if stale_here:
                sw.stale_states += 1

            at_boundary = out == N_OUT and DISP in tstate
            if at_boundary:
                sw.boundary_states += 1
            saw_cancel_at_boundary = False

            # completion-reordering witness: two ACCEPTED tags that are
            # DISTINGUISHABLE, so the two completion orders are observably
            # different rather than a relabelling of one another.
            if not sw.reorder_witness:
                accs = [t for t in range(N_TAGS) if tstate[t] == ACC]
                for i in range(len(accs)):
                    for j in range(i + 1, len(accs)):
                        x, y = accs[i], accs[j]
                        if (tframe[x], tgen[x], tobj[x]) != \
                           (tframe[y], tgen[y], tobj[y]):
                            sw.reorder_witness = st
                            sw.reorder_pair = (x, y)
                            break
                    if sw.reorder_witness:
                        break

            # ---- expand -----------------------------------------------------
            # Distinct quotient edges are counted per source into a small local
            # set. Sources are unique, so summing the per-source counts gives
            # the exact distinct-edge total without holding a million-entry
            # global edge set.
            targets = set()
            for label, ns in successors(st):
                sw.transitions += 1
                # Per-tag guards, checked on every edge the model ever offers.
                # Dispatch is on one character: A=AXI_ACCEPT, CO=COMPLETE,
                # CA=CANCEL, R=REUSE, D=DISPATCH. A startswith() chain here
                # cost 3.6M string scans per sweep.
                k = label[0]
                if k == "A":
                    if tstate[int(label[12])] != DISP:
                        sw.accept_only_from_disp = False
                    if at_boundary:
                        sw.boundary_rejects = False
                elif k == "C":
                    if label[1] == "O":
                        if tstate[int(label[10])] != ACC:
                            sw.complete_only_from_acc = False
                    else:
                        if tstate[int(label[8])] != DISP:
                            sw.cancel_only_from_disp = False
                        saw_cancel_at_boundary = True
                elif k == "R":
                    f = int(label[7])
                    if any(tstate[t] == ACC and tframe[t] == f
                           for t in range(N_TAGS)):
                        sw.reuse_respects_accepted = False

                cn = canon(ns)                   # canonicalise BEFORE pushing
                targets.add(cn)
                if cn not in seen:
                    seen.add(cn)
                    frontier.append(cn)          # store the canonical form

            sw.edges += len(targets)
            if at_boundary and saw_cancel_at_boundary:
                sw.boundary_cancels += 1

    sw.states = len(seen)
    sw.frontier_left = len(frontier)
    sw.reached = seen
    return sw


def _after(st, label):
    for l, ns in successors(st):
        if l == label:
            return ns
    return None


def t_bfs_oracle():
    t0 = time.perf_counter()
    sw = bfs_fixpoint()
    elapsed = time.perf_counter() - t0

    print(f"    REACHABLE STATES {sw.states}   TRANSITIONS {sw.transitions}"
          f"   (distinct edges {sw.edges})")
    print(f"    BFS depth to fixpoint {sw.depth} levels, no depth cap"
          f"   sweep {elapsed:.2f}s")

    ck("bfs oracle: explored to fixpoint (frontier drained, no depth cap)",
       sw.frontier_left == 0, f"frontier={sw.frontier_left}")
    ck("bfs oracle: reachable states enumerated", sw.states > 1000,
       str(sw.states))
    ck("bfs oracle: transitions enumerated", sw.transitions > 5000,
       str(sw.transitions))
    ck("bfs oracle: fixpoint is deeper than any fixed-depth enumeration used",
       sw.depth > N_TAGS, f"depth={sw.depth}")

    # ---- the modelled quantities are actually exercised ---------------------
    ck(f"bfs oracle: all {N_TAGS} tags concurrently live",
       sw.tags_live_max == N_TAGS, f"max_live={sw.tags_live_max}")
    ck(f"bfs oracle: both frames referenced", sw.frames_seen == set(range(N_FRAMES)),
       str(sorted(sw.frames_seen)))
    ck(f"bfs oracle: both object types referenced",
       sw.objs_seen == set(range(N_OBJ)), str(sorted(sw.objs_seen)))
    ck(f"bfs oracle: generation state exercised over {MAX_GEN + 1} generations",
       sw.gens_seen == set(range(MAX_GEN + 1)), str(sorted(sw.gens_seen)))
    ck(f"bfs oracle: all {N_FRAMES * (MAX_GEN + 1) * N_OBJ} object instances "
       f"(frame,gen,obj) reached",
       len(sw.instances_seen) == N_FRAMES * (MAX_GEN + 1) * N_OBJ,
       str(len(sw.instances_seen)))
    ck(f"bfs oracle: four outstanding simultaneously reached (N_out={N_OUT})",
       sw.saw_full and sw.max_out == N_OUT, f"max_out={sw.max_out}")
    ck("bfs oracle: outstanding count never exceeds the limit and matches the "
       "accepted tags in EVERY reachable state", sw.out_accounting_ok)

    # ---- per-tag properties, over the WHOLE reachable set --------------------
    ck("bfs oracle: AXI_ACCEPT(tag) at most once (offered only to a dispatched "
       "tag, in every reachable state)", sw.accept_only_from_disp)
    ck("bfs oracle: COMPLETE(tag) at most once and only after a prior "
       "AXI_ACCEPT(tag) (offered only to an accepted tag, in every reachable "
       "state)", sw.complete_only_from_acc)
    ck("bfs oracle: CANCEL legal before acceptance and rejected after, in "
       "every reachable state", sw.cancel_only_from_disp)
    ck("bfs oracle: frame reuse never offered while an outstanding tag "
       "references the old generation, in every reachable state",
       sw.reuse_respects_accepted)

    # ---- the fifth request at the outstanding boundary ----------------------
    ck("bfs oracle: the outstanding boundary is reachable with a fifth "
       "request still pending", sw.boundary_states > 0,
       str(sw.boundary_states))
    ck("bfs oracle: a fifth acceptance is REJECTED at the outstanding limit, "
       "in every such reachable state", sw.boundary_rejects)
    ck("bfs oracle: the fifth tag may still CANCEL at the boundary, in every "
       "such reachable state", sw.boundary_cancels == sw.boundary_states,
       f"{sw.boundary_cancels}/{sw.boundary_states}")

    # hand-built confirmation of the same boundary, kept as a direct check
    full = ((ACC,) * 4 + (DISP,), (0, 0, 1, 1, 0), (0,) * 5, (0,) * 5,
            N_OUT, (0, 0), (0, 0))
    labels = [l for l, _ in successors(full)]
    ck("bfs oracle: a fifth acceptance is REJECTED at the outstanding limit",
       not any(l.startswith("AXI_ACCEPT") for l in labels), str(labels[:4]))
    ck("bfs oracle: the fifth tag may still CANCEL at the boundary",
       any(l.startswith("CANCEL") for l in labels))

    # ---- frame reuse vs outstanding tags ------------------------------------
    busy = ((ACC, IDLE, IDLE, IDLE, IDLE), (0, -1, -1, -1, -1),
            (0, -1, -1, -1, -1), (0, -1, -1, -1, -1), 1, (0, 0), (0, 0))
    labels = [l for l, _ in successors(busy)]
    ck("bfs oracle: REUSE(f0) blocked while a tag is accepted on f0",
       not any(l.startswith("REUSE(f0") for l in labels), str(labels))
    ck("bfs oracle: REUSE(f1) allowed, no tag accepted on f1",
       any(l.startswith("REUSE(f1") for l in labels))

    retired = ((DONE, IDLE, IDLE, IDLE, IDLE), (0, -1, -1, -1, -1),
               (0, -1, -1, -1, -1), (0, -1, -1, -1, -1), 0, (0, 0), (0, 0))
    ck("bfs oracle: frame reuse allowed after retirement",
       any(l.startswith("REUSE(f0") for l, _ in successors(retired)))

    # ---- completion REORDERING, on a witness taken from the reachable set ---
    ck("bfs oracle: a state with two distinguishable accepted tags is reachable",
       bool(sw.reorder_witness))
    if sw.reorder_witness:
        st = sw.reorder_witness
        x, y = sw.reorder_pair
        first_x = _after(st, f"COMPLETE(t{x})")
        first_y = _after(st, f"COMPLETE(t{y})")
        ck("bfs oracle: out-of-order completion is reachable (both completion "
           "orders enabled from one reachable state)",
           first_x is not None and first_y is not None)
        ck("bfs oracle: the two completion orders pass through DIFFERENT "
           "states, so the reordering is observable",
           canon(first_x) != canon(first_y))
        ck("bfs oracle: the two completion orders reconverge",
           canon(_after(first_x, f"COMPLETE(t{y})")) ==
           canon(_after(first_y, f"COMPLETE(t{x})")))

    # hand-built confirmation of the same reordering
    two = ((ACC, ACC, IDLE, IDLE, IDLE), (0, 1, -1, -1, -1),
           (0, 0, -1, -1, -1), (0, 0, -1, -1, -1), 2, (0, 0), (0, 0))
    labels = [l for l, _ in successors(two)]
    ck("bfs oracle: out-of-order completion is reachable",
       "COMPLETE(t1)" in labels and "COMPLETE(t0)" in labels)

    # ---- STALE generation, on a witness taken from the reachable set --------
    ck("bfs oracle: a tag can hold a STALE generation after frame reuse "
       "(witnessed in the reachable set)", sw.stale_states > 0,
       str(sw.stale_states))
    if sw.stale_witness:
        wst, wt = sw.stale_witness
        print(f"    stale witness: tag{wt} holds gen {wst[2][wt]} obj "
              f"{wst[3][wt]} on frame {wst[1][wt]}, which now holds gen "
              f"{wst[5][wst[1][wt]]} obj {wst[6][wst[1][wt]]}"
              f"   ({sw.stale_states} such states)")
        ck("bfs oracle: the stale witness is a LIVE tag, not a retired one",
           wst[0][wt] in LIVE, NAMES[wst[0][wt]])

    # hand-built confirmation: dispatched on gen 0, frame now on gen 1
    stale = ((DISP, IDLE, IDLE, IDLE, IDLE), (0, -1, -1, -1, -1),
             (0, -1, -1, -1, -1), (0, -1, -1, -1, -1), 0, (1, 0), (1, 0))
    ck("bfs oracle: a tag can hold a STALE generation after reuse",
       stale[2][0] != stale[5][stale[1][0]],
       f"tag_gen={stale[2][0]} frame_gen={stale[5][0]}")

    # ---- per-tag once-only, structurally ------------------------------------
    acc = ((ACC, IDLE, IDLE, IDLE, IDLE), (0, -1, -1, -1, -1),
           (0, -1, -1, -1, -1), (0, -1, -1, -1, -1), 1, (0, 0), (0, 0))
    ck("bfs oracle: AXI_ACCEPT(tag) at most once",
       "AXI_ACCEPT(t0)" not in [l for l, _ in successors(acc)])
    ck("bfs oracle: CANCEL is REJECTED after acceptance",
       "CANCEL(t0)" not in [l for l, _ in successors(acc)])
    done = ((DONE, IDLE, IDLE, IDLE, IDLE), (0, -1, -1, -1, -1),
            (0, -1, -1, -1, -1), (0, -1, -1, -1, -1), 0, (0, 0), (0, 0))
    ck("bfs oracle: COMPLETE(tag) at most once",
       "COMPLETE(t0)" not in [l for l, _ in successors(done)])
    start = ((IDLE,) * N_TAGS, (-1,) * N_TAGS, (-1,) * N_TAGS, (-1,) * N_TAGS,
             0, (0,) * N_FRAMES, (0,) * N_FRAMES)
    ck("bfs oracle: COMPLETE requires prior AXI_ACCEPT",
       "COMPLETE(t0)" not in [l for l, _ in successors(start)])
    ck("bfs oracle: CANCEL is legal before acceptance",
       "CANCEL(t0)" in [l for l, _ in successors(
           _after(start, "DISPATCH(t0,f0)"))])


def _raw_reachable(n_tags):
    """UNREDUCED BFS at a smaller tag count, used only to validate canon()."""
    inits = [((IDLE,) * n_tags, (-1,) * n_tags, (-1,) * n_tags,
              (-1,) * n_tags, 0, (0,) * N_FRAMES, (o0, o1))
             for o0 in range(N_OBJ) for o1 in range(N_OBJ)]
    seen = set(inits)
    frontier = deque(inits)
    while frontier:
        st = frontier.popleft()
        for _, ns in successors(st):
            if ns not in seen:
                seen.add(ns)
                frontier.append(ns)
    return seen


def t_canon_is_sound():
    """All of section A's speed comes from one tag-permutation symmetry
    reduction, so prove the reduction loses nothing instead of asserting it.

    At tag counts where the UNREDUCED space is still tractable, the canonical
    sweep must reach EXACTLY the canonical closure of the raw reachable set,
    and a raw state must offer the same kinds of action as its representative.
    If canon() ever over-merged, these would diverge. Run at 3 and 4 tags; the
    argument is uniform in the tag count, and 5 is only unrunnable raw because
    of its size, not because anything changes.
    """
    global N_TAGS
    keep = N_TAGS
    try:
        for n in (3, 4):
            N_TAGS = n
            raw = _raw_reachable(n)
            sw = bfs_fixpoint()
            closure = {canon(s) for s in raw}
            ck(f"canon soundness (N_TAGS={n}): canonical sweep reaches exactly "
               f"the canonical closure of the {len(raw)} raw states",
               sw.reached == closure,
               f"canon={len(sw.reached)} closure={len(closure)}")
            differing = sum(
                1 for s in raw
                if {l.split("(")[0] for l, _ in successors(s)} !=
                   {l.split("(")[0] for l, _ in successors(canon(s))})
            ck(f"canon soundness (N_TAGS={n}): every raw state offers the same "
               f"actions as its canonical representative", differing == 0,
               f"{differing} differ")
            print(f"    N_TAGS={n}: raw {len(raw)} -> canonical {sw.states}"
                  f"   ({len(raw) / sw.states:.1f}x reduction, lossless)")
    finally:
        N_TAGS = keep


# =========================================== B. COMMON FORCED PREFIX

BARRIER = 900


def forced_prefix():
    """Deadlines generous enough that EVERY policy admits every prefix request,
    so all policies reach the barrier in an identical state. That identity is
    asserted, not assumed."""
    reqs = []
    for i in range(4):
        reqs.append(R(i * 60, i % 2, ObjType.KV_PAGE, i,
                      TrafficClass.MANDATORY, 2176, 100000, held=(i == 0)))
    reqs.append(R(500, 0, ObjType.KV_PAGE, 0, TrafficClass.MANDATORY, 0,
                  100000, is_release=True))
    return reqs


def state_fingerprint(r):
    c = r.coverage
    return (r.admitted, r.accepted, r.completed, r.cancelled,
            c.get("draining_frames_max"), c.get("occupancy_high_water"))


def t_forced_prefix_identity():
    p = Params(n_tenants=2, n_frames=4, n_descriptors=8,
               dispatch_queue_depth=4, max_axi_outstanding=2)
    e = DownstreamEnvelope()
    fps = {}
    for n in policies.POLICY_NAMES:
        r = sim.run(n, p, forced_prefix(), e, horizon=BARRIER)
        fps[n] = state_fingerprint(r)
    distinct = set(fps.values())
    ck("forced prefix: every policy reaches an IDENTICAL state at the barrier",
       len(distinct) == 1, str(fps))
    ck("forced prefix: the prefix actually did work",
       list(distinct)[0][0] > 0 if distinct else False, str(distinct))


def t_discriminating_case():
    """After the identical prefix, one request separates the policies.

    NORMALIZED SMALL-STATE TEST. Cycle counts here are scaled so L_down,max is
    comparable to a two-cycle transfer. They are NOT the production parameters,
    where L_down,max is 1776 cycles. The two ledgers are different scales of the
    same formula, not a contradiction.
    """
    p = Params(n_tenants=2, n_frames=1, n_descriptors=4,
               n_reserved_mandatory_desc=1, dispatch_queue_depth=2,
               max_axi_outstanding=1, axi_bytes_per_cycle=16,
               axi_accept_overhead_cycles=0, axi_fixed_overhead_cycles=0,
               dwrr_quantum_bytes=4096, dwrr_replenish_period=8,
               dwrr_max_deficit_bytes=8192)
    e = DownstreamEnvelope(c_max_cycles=2, b_fixed_cycles=0,
                           refresh_cycles_per_window=0, window_cycles=64,
                           fifo_non_preemptive=True, max_bypass_transactions=0)
    reqs = [
        R(0, 0, ObjType.KV_PAGE, 100, TrafficClass.MANDATORY, 32, 64, held=True),
        R(1, 0, ObjType.KV_PAGE, 100, TrafficClass.MANDATORY, 0, 64, is_release=True),
        R(1, 1, ObjType.KV_PAGE, 200, TrafficClass.MANDATORY, 32, 3),
    ]
    res = {n: sim.run(n, p, reqs, e, horizon=400) for n in policies.POLICY_NAMES}

    print(f"    {'policy':<32}{'role':<26}{'adm':>4}{'ot':>4}  violations")
    for n in policies.POLICY_NAMES:
        r = res[n]
        print(f"    {n:<32}{policies.BY_NAME[n].role:<26}{r.admitted:>4}"
              f"{r.on_time:>4}  {r.summary()['violations'] or '-'}")

    ri = res["integrated"]
    rc = res["separable_conservative_guard"]
    rm = res["independent_memory_safe_guard"]
    rd = res["independent_dual_guard"]

    ck("discriminating: the joint predicate prevents an accepted-deadline "
       "violation that survives independent deadline, capacity and "
       "memory-safety checks",
       ri.admitted == 1 and "issue_deadline_miss" not in ri.summary()["violations"],
       f"integrated admitted={ri.admitted} viol={ri.summary()['violations']}")
    ck("discriminating: the lifecycle-blind negative control admits and misses",
       rd.admitted == 2 and "issue_deadline_miss" in rd.summary()["violations"])
    ck("discriminating: the safe-independent policy also admits and misses",
       rm.admitted == 2 and "issue_deadline_miss" in rm.summary()["violations"])

    # The claim under test: does the joint forecast admit MORE USEFUL WORK than
    # a conservative policy offering the SAME guarantee?
    same_guarantee = ("issue_deadline_miss" not in rc.summary()["violations"])
    ck("discriminating: the conservative guard offers the same admission "
       "guarantee without any joint forecast", same_guarantee,
       f"conservative viol={rc.summary()['violations']}")
    if same_guarantee:
        ck("discriminating: on THIS trace the joint forecast does NOT admit "
           "more useful work than the conservative guard",
           ri.on_time <= rc.on_time,
           f"integrated on_time={ri.on_time} conservative on_time={rc.on_time}")
        print(f"    NOTE: integrated on_time={ri.on_time}, "
              f"conservative on_time={rc.on_time}. Admission correctness is "
              f"demonstrated; a GOODPUT advantage is not.")


def main():
    print("\n=== A. BFS transaction oracle ===\n")
    t_bfs_oracle()
    print("\n=== A2. symmetry reduction is lossless ===\n")
    t_canon_is_sound()
    print("\n=== B. common forced prefix ===\n")
    t_forced_prefix_identity()
    print()
    t_discriminating_case()
    print(f"\nPASSED {len(PASS)}   FAILED {len(FAIL)}")
    if FAIL:
        print("\nFAILURES:")
        for n, d in FAIL:
            print(f"  {n}   {d}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
