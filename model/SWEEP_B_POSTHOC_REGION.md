# POST-HOC: the 36 wins are NOT scattered. I was wrong to say so.

**This does NOT change the verdict.** The protocol was frozen before the run and
the gate failed. Nothing below reopens it. But "isolated, non-qualifying
observations" was a claim I made without checking, and checking overturns it.

## The 36 wins are tightly structured

Every single one of the 36:

- **frames = 4**, the smallest frame pool, i.e. maximum capacity pressure
- **load >= 0.90**, the two highest offered loads
- **nonevict >= 0.5**, high temporarily-non-evictable fraction
- **spec_share >= 0.25**, and 30 of 36 at 0.5
- **retained >= 90% throughput**, in fact 110 to 115%, so BETTER throughput

That is not scatter. That is exactly the intersection the mechanism was designed
to address: a small pool, under pressure, with pages pinned by outstanding work
and speculative traffic competing.

## And it nearly formed a region

| measure | count |
|---|---|
| distinct cells containing a win | 26 |
| cells with >= 2 winning seeds | 9 |
| **cells with >= 3 winning seeds** | **1** |
| axis-groups with wins at BOTH 0.90 and 0.95 (adjacent) | **8** |
| wins that also retained >= 90% throughput | **36 of 36** |
| wins that carried a safety violation | 4 |

The nearest miss is `frames=4, ws=2.0, nonevict=0.75, spec=0.5, slack=4.0`:
seeds {2,3} win at load 0.90 and seeds {2,3,5} win at 0.95. Adjacent loads, but
the region-wide shared-seed intersection is {2,3}, which is 2 and the gate needs
3. It missed by one seed.

## The overall median was hiding a real effect

Median relative gain by frame pool and load:

| frames | 0.70 | 0.80 | 0.90 | 0.95 |
|---|---|---|---|---|
| **4** | +0.00 | +0.00 | +0.00 (p90 **+4.0**) | +0.00 (p90 **+4.2**) |
| 8 | -0.50 | -0.50 | +0.00 | +0.00 |
| **16** | -1.00 | -2.27 | -2.60 | **-3.00** |

**The headline -0.50% median was dominated by frames=16, where the mechanism is
actively harmful at -3%.** With a large pool there is no capacity pressure, so
the joint forecast only adds conservatism and costs service.

Inside `frames=4, load >= 0.90`, by non-evictable fraction and speculative share:

| nonevict | spec | median gain | max |
|---|---|---|---|
| 0.25 | 0.5 | **+2.90%** | +9.2 |
| 0.50 | 0.5 | **+3.23%** | +12.8 |
| 0.75 | 0.5 | **+2.70%** | +15.0 |
| any | 0.0 | +0.00% | +1.1 |
| any | 0.25 | -0.5 to -1.0% | +14.6 |

There is a **consistent median gain of about +3%** in the small-pool,
high-load, high-speculation corner, and it is flat or negative everywhere else.

## The honest reading

The mechanism has a **real but small effect, roughly +3% median, confined to a
specific operating region**, and it is **harmful at -3% when the frame pool is
large**. The frozen gate was 10%, set before anyone knew the effect size, and
10% is far above what this mechanism delivers.

So the correct statement is not "it does nothing". It is:

> Within the frozen grid, the integrated policy failed its pre-registered 10%
> discovery gate. Post-hoc, its wins are not scattered: they concentrate
> entirely at frames=4, load >= 0.90, high non-evictable fraction and high
> speculative share, where the median gain is about +3%. The mechanism is
> harmful at larger frame pools. The 10% gate was set before the effect size was
> known and is roughly three times the observed effect.

## What this justifies, and what it does not

**Does NOT justify**: overturning the verdict, running the confirmation, or
building the rejected scheduler. The gate was frozen precisely so a post-hoc
cluster could not rescue it.

**DOES justify**: a NEW, separately pre-registered experiment restricted to
`frames in {2,4}`, `load in {0.90, 0.95}`, `nonevict >= 0.5`, `spec_share = 0.5`,
with a gate set to the observed effect size rather than an arbitrary 10%, and
enough seeds for actual statistical power. That is a different experiment with a
different question, and it must be frozen and run as such.

**Correction to my own wording:** "isolated, non-qualifying observations" is
withdrawn. They are non-qualifying under the frozen gate, but they are neither
isolated nor unstructured.
