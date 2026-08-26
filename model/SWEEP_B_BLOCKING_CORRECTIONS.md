# Sweep A is EXPLORATORY. Three blocking corrections before any confirmatory run.

Sweep A is preserved unchanged as the frozen record of a targeted DISCOVERY
sweep. **No GO, no RTL approval and no real-world performance claim may be
issued from it alone.** The three blockers below must be closed first, and each
must be checked as a possible MODEL DEFECT before the branch is closed on
Sweep A's evidence.

---

## B1. 144 cycles is not automatically `L_downstream_max`

An isolated transfer latency is a valid maximum **only if** issuing means
entering service immediately and every issued transfer completes within exactly
144 cycles. Our own model has AXI queueing after issue: `tick_issue` computes
`start = max(cycle + overhead, port_free)`, so a transfer issued while the port
is busy completes later than 144 cycles after issue. **144 is therefore not the
maximum and the value used in Sweep A is wrong.**

A negative latest-issue deadline means the request is infeasible. It is not a
reason to shrink the downstream bound, which is what I did.

Correct form, per request:

    D_issue,i  =  A_i + SLO_i - L_down,max,i

Service times of PRECEDING requests still affect when request i can issue and
must stay in the feasibility test. Only request i's OWN downstream latency must
not be counted twice. Sweep A removed the fill term from the tests, which is
right, but paired it with an under-stated `L_down,max`, which is not.

**Action:** derive `L_down,max` from the declared service envelope, not from the
isolated transfer time, and make it per-request. Re-check whether bin 6 is still
reachable once it is correct; if it is not, that is a finding about the
mechanism, not a licence to shrink the bound again.

## B2. Coverage validity must be POLICY-INDEPENDENT

Sweep A computed the six coverage bins from the **integrated policy's own
resulting state**, then filtered to "fully valid" configs and compared policies
only on those. That is selection bias: the filter is correlated with the
candidate's behaviour.

**Action:** qualify traces by either

- a **common forced prefix** that drives every policy into the identical state
  before measurement begins, or
- a **policy-neutral trace oracle** evaluated before any policy runs.

Policy-specific coverage stays in the report, but it must not decide which
comparisons are retained.

## B3. `independent_dual_guard` is a NEGATIVE CONTROL, not a fair baseline

Its capacity check is deliberately lifecycle-blind, which can be intentionally
unsafe. That makes it the right instrument for reproducing the counterexample
and the wrong instrument for a performance comparison.

**Action: add `independent_safe_guard`.** It receives the same refcount,
inflight and capacity information and obeys the same eviction-safety rules, but
makes its deadline and capacity decisions **independently**, without the
integrated joint forecast. That is the honest performance comparator. Keep the
dual guard as the negative control and label it as such.

---

## State semantics: one explicit table, no overloading of "reference"

| counter | incremented by | decremented by |
|---|---|---|
| `logical_refcount` | ACQUIRE | RELEASE |
| `inflight_count` | ISSUE | COMPLETION |
| `reservation_count` | ADMIT | CANCEL or ISSUE |
| `fill_pending` | FILL_START | FILL_COMPLETE |

A **draining** page is exactly:

    logical_refcount == 0  AND  inflight_count > 0

**Admission must NOT create a logical reference.** Sweep A's `admit()` does
`obj.refcount += 1`, which conflates admission with acquisition and is why the
held-reference semantics needed two corrections. Eviction requires ownership,
inflight, reservation and fill state to all permit release.

Speculative tokens:

- charge on **actual AXI acceptance**, not at selection
- **pre-issue** cancellation consumes no token
- **post-issue** cancellation gets no refund
- do not return the descriptor until outstanding activity retires

---

## Experimental integrity

**Sweep A is exploratory, not confirmatory.** The pre-freeze coverage probe
influenced the deadline and release distributions, which is legitimate
calibration but disqualifies the same sweep from being confirmatory.

**8,640 configurations is a large discovery surface. Three of five seeds is not
adequate protection against an accidental winning region.**

Decision rule, binding:

1. If Sweep A yields **no** qualifying region: close the branch, **after**
   confirming B1, B2 and B3 are not model defects that suppressed the effect.
2. If it yields a qualifying region: **freeze that region** and validate on
   **fresh, previously unused seeds, at least 20**, with a **paired confidence
   interval on the improvement that excludes zero**, and **no further parameter
   changes**.

**Fixed measurement horizons across policies.** Sweep A lets each policy run to
its own drain, so a policy that rejects more work and terminates earlier can
show inflated utilisation or throughput. All policies must be measured over the
same horizon.

## Corrected wording, replacing "the narrowness is itself a result"

> Within this synthetic generator and parameter grid, all six activation bins
> were reached in 4 of 96 probed cells. This establishes **mechanism
> reachability**, not real-workload prevalence.

## The 96 denominator, defined

96 is not a subset of the 8,640-config grid. It is a separate **pre-freeze
corner probe**: the 2-level projection of the 6 grid axes onto their extremes,
`frames {4,8,16} x ws {0.75,2.0} x nonevict {0.0,0.75} x load {0.70,0.95} x
spec {0.0,0.5} x slack {1.25,4.0}` = 3 x 2 x 2 x 2 x 2 x 2 = 96 cells, one seed
each. It samples the corners of the design space, not its interior, and it was
run to decide whether the intersection was reachable at all before committing to
the full grid.
