# SWEEP B: THE INTERPRETATION IS VOID

Every figure below was recomputed by me directly against the frozen file and
against `gm/policies.py` source. Not taken on trust from an agent.

## 1. The "primary baseline" was FIFO wearing a label

`gm/policies.py`:

    class Fifo(Policy):
        def feasible(self, req, cycle, cp, dp, d_issue): return True

    class TunedAxiQos(Policy):
        def feasible(self, req, cycle, cp, dp, d_issue): return True

**Identical bodies.** Verified in the data: `fifo` and `tuned_axi_qos` produce
byte-identical summary rows in **8,640 of 8,640 runs**. Mean S_p 0.903421 for
both.

There is no arbitration, no priority class, no bandwidth regulation and no
deadline term anywhere in it. **Every headline comparison I published was
against FIFO, i.e. against no admission control at all**, while calling it a
tuned QoS baseline. The question the gate existed to answer was never asked.

## 2. The candidate finishes EIGHTH of nine

Mean S_p over the full grid:

| rank | policy | mean S_p | median |
|---:|---|---|---|
| 1 | fifo | 0.903421 | 0.9550 |
| 1 | tuned_axi_qos (same thing) | 0.903421 | 0.9550 |
| 3 | credit_only | 0.903360 | 0.9550 |
| 4 | lifecycle_edf | 0.899525 | 0.9450 |
| 4 | independent_memory_safe_guard | 0.899525 | 0.9450 |
| 4 | independent_dual_guard | 0.899525 | 0.9450 |
| 4 | edf_only | 0.899525 | 0.9450 |
| **8** | **integrated** | **0.896126** | **0.9400** |
| 9 | separable_conservative_guard | 0.760291 | 0.7950 |

It loses to the **negative control**. I never printed a ranked table of the
metric the entire study is about.

**And my claim from earlier today that "integrated beats
separable_conservative_guard in 69% of runs" is worthless**: that policy is dead
last at 0.760 against everyone else's ~0.90. Beating it is not an achievement.

## 3. The mechanism is inert in 94% of the grid, and does nothing where it fires

`feasible_until_lifecycle > 0`, i.e. the joint forecast actually changed a
decision, in **511 of 8,640 runs = 5.91%**. Zero at frames=16.
Only **96 of 1,728 cells** have the 3 engaged seeds the gate would need.

The decisive number:

| | median gain vs baseline | n |
|---|---|---|
| where the mechanism ENGAGED | **-0.52%** | 511 |
| where it did NOT engage | **-0.50%** | 8,129 |

**Indistinguishable.** When the joint forecast fires, it produces no benefit.

## 4. My post-hoc "+3% real effect" was not the mechanism

In the sub-region I celebrated (frames=4, load>=0.90, spec_share=0.5), only
**25 of 480 runs (5.2%)** had the mechanism engaged. Whatever produced that
+2.5 to +3% came from somewhere else. I attributed an effect to a mechanism that
was switched off in 95% of the runs showing it.

## 5. "Missed by one seed" was false

Under the real two-baseline gate the maximum passing-seed count in ANY of the
1,728 cells is **2**, and the gate needs 3. The best region-wide shared-seed
intersection in the entire grid is size **1**. I computed seed sets against one
baseline and narrated them in two-baseline language.

The published "36 wins" also silently included **4 runs disqualified for
candidate safety violations**.

## 6. Nine policies are seven behaviours

`lifecycle_edf` and `independent_memory_safe_guard` produce byte-identical rows
in **8,640 of 8,640 runs**, as do `fifo` and `tuned_axi_qos`. The 77,760-record
count was real; the nine-way comparison was not.

---

## What this does and does not change

**The verdict is UNCHANGED and now over-determined.** The mechanism did not
work: it ranks eighth, and it is no better in the runs where it actually fires.
`DISCOVERY_NO_GO_BRANCH_CLOSED` stands.

**Everything I said about WHY is void.** The "-0.50% against a tuned baseline",
the "+3% real effect in a specific region", the "cheapest safe policy", the
"missed by one seed" — all of it rested on a baseline set with two duplicate
pairs and a mechanism that was off almost everywhere.

**The experiment cannot be repaired by reanalysis.** A rerun would need distinct
baselines, a grid where the mechanism can engage in more than 6% of runs, and a
gate calibrated to a measured effect size.

## My errors today, in order

1. "scattered noise" - asserted with no computation
2. "isolated observations" - asserted with no computation; they were structured
3. never computed the second required baseline
4. never checked that the baselines were distinct policies
5. never ranked the policies on the primary metric
6. never checked whether the mechanism engaged
7. attributed a +3% effect to a mechanism that was off in 95% of those runs
8. said "missed by one seed" when it missed by two
9. presented beating the worst policy as a result
10. nearly published "0% engagement" from the wrong key path, minutes ago

The pattern is one thing: **I reported what a tool handed me and never checked
whether the tool was measuring what I claimed.**
