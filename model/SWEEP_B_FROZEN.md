# SWEEP B PRIMARY: FROZEN 2026-08-24T13:38:27Z

Run ID: `B-PRIMARY-20260824T133827Z`

Frozen AFTER resolving both blockers. Nothing below may change while the
run is in flight. If anything changes, a NEW run id and manifest are
required; the old one is not resumed.

## Blocker 1 resolved: RTL-realizable lifecycle handle

A descriptor carries `{lifecycle_slot, phys_idx, expected_generation,
transaction_tag}`, never a pointer. Resolution is exactly:
```
entry = lifecycle_ram[lifecycle_slot]
valid = entry.phys_idx == d.phys_idx and entry.generation == d.expected_generation
```
`obj_for()` never dereferences the debug-only `obj_ref`, proven by source
inspection in `tests/test_gm_handle.py`, which also proves the bounded
lookup agrees with pointer semantics on every descriptor and that a stale
descriptor resolves to None rather than reviving an evicted object.

## Blocker 2 resolved: primary depth frozen at N_out = 2

| N_out | conditional bound |
|---:|---:|
| 1 | 240 cycles |
| 2 | 784 cycles |
| 3 | 1392 cycles |
| 4 | 1936 cycles |

The tightest declared SLO class is inadmissible from depth 3 upward, so
running the primary at depth 4 would knowingly make it structurally
unservable. Depths {1,3,4} are a SEPARATE pre-registered sensitivity study.
**The depth is not selected after observing performance.**

## Gates, all green on THIS exact source

| gate | result |
|---|---|
| bounded lifecycle handle | 12 / 0 |
| critical-mutant suite | 67 / 0 |
| counterexample suite | 29 / 0 |
| fixpoint oracle + forced prefix | 47 / 0 |
| allocator regression (was 9/9 escaping) | 0 / 9 escape |
| escape rate at scale (was 23/216) | 0 / 216 |
| runner lock / interrupt / resume smoke | 36 / 36 records |

## Frozen inputs, sha256
```
1388d94719d1a1253734ae12c6fd91768115da4fb0c5184234e718a9f8089eb3  gm/checks.py
d4b443725478c5105f0fce881ca4d63d1fcbb0a7b85e2046616df833da3957f7  gm/control_plane.py
8eeb12e641ba09be1b6dde3f91a09b6fc76a4081864094aeb1b7b3606fb1810d  gm/coverage.py
51e8eecba1b2eeb557c36d7f95bb781f801c6e39defb72d23ecdf3f2f67f91b8  gm/data_plane.py
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  gm/__init__.py
0f5a3ee5addc60304d78d21553714a23bbb6e16be9e49d5669cad1c0c31f2e89  gm/policies.py
662c68d8fa5c83c3728024285e6e82a91ac52763ddd5a2e29c803997cfccab9b  gm/sim.py
72d21929afb1515cfce1e181a4ece678defc658cf5d3145ea7596de6809f19c2  gm/traces_b.py
51a60f8e9f79e2b1bdac95398bff8c66397959e8f3bbbf4312ac1d0cb9174d28  gm/types.py
89bd1ad46f81ae2463d8247b35600186770a0d8dd05730c90d5108a4039ac3bd  sweep_b.py
08867c3958a3a75a7aae872038977bd187fbeead97626ff61db1fe39700f8971  tests/test_gm_counterexample.py
0979e5d3fdf8b139d67494087c0eb2a42673800671e49adcfa49516b91aa2263  tests/test_gm_handle.py
bd0dafda89f004212e2218a1270ed9520c2316923d11328378222ef1bd9547eb  tests/test_gm_mutations.py
803b2fb52acf23a99321a8aa87c4ffe6ca2f2d108571dc44eb7bf92660ccaed1  tests/test_gm_pending_swap_defect.py
393e25241b90579e0a38e4d216d5c64d60badc0d4e69ba045b36dd78f1c9d55a  tests/test_gm_targeted.py
```

runtime: python 3.12.3 | Linux 7.0.0-28-generic

policies (9, frozen): fifo, edf_only, credit_only, tuned_axi_qos, lifecycle_edf, independent_dual_guard, independent_memory_safe_guard, separable_conservative_guard, integrated

envelope: C_max 512 B_fixed 32 refresh 64 window 1024 bypass 0 fifo True
primary N_out: 2  L_down_max(C_i=144) = 784

grid: frames(4,8,16) x ws(0.75,1.0,1.5,2.0) x nonevict(0,.25,.5,.75)
      x load(.70,.80,.90,.95) x spec(0,.25,.5) x slack(1.25,2.0,4.0) x seeds(1..5)
EXPECTED PRIMARY RECORDS: 8640 x 9 = 77760

launch: python3 sweep_b.py --run-id B-PRIMARY-20260824T133827Z --workers 24
