# SPEC.md v0.2 adversarial review: NOT SAFE TO BUILD AGAINST

Five lenses, 83 findings raised (23 BLOCKING, 46 MAJOR, 14 MINOR). 33 refuters
and the editor agent died on a session limit, so most findings were never
machine-adjudicated. **The findings below were therefore verified by hand,
arithmetically, against the spec text.** All five reproduce.

**Verdict: v0.2 must not be used as an RTL basis. The headline number is wrong.**

---

## B1. THE HEADLINE CEILING IS 1.5x, NOT 1.25x. Found independently by 4 lenses.

Section 5.1 states, as non-negotiable, "no DDR transaction below 128 B", and
invariant 7 asserts `n_burst_lt_128 == 0`. Section 5.2 sets the compact page at
64 B.

**64 B < 128 B.** So the design's primary mechanism violates the design's own
non-negotiable rule on its first compact fetch. Invariant 7 is satisfiable only
by a PageGuard that never takes the compact path, which is exactly degenerate
policy 1 from red team attack 6: the switched-off design.

Once the compact fetch is padded to the 128 B floor, `r = 128/256 = 0.5`:

| exact page | burst-legal compact | r | ceiling | break-even m |
|---|---|---|---|---|
| **256 B** | **128 B** | **0.500** | **1.500x** | **m < 0.500** |
| 512 B | 256 B | 0.500 | 1.500x | m < 0.500 |
| 1024 B | 448 B | 0.438 | 1.438x | m < 0.562 |
| 2048 B | 832 B | 0.406 | 1.406x | m < 0.594 |

Two consequences, both material:

1. **The ceiling at the default page size is 1.5x, not 1.25x.** Every place the
   number 1.25 appears in the spec, the posts, and DECISION_001 is wrong.
2. **Break-even moves from `m < 0.75` to `m < 0.5`.** That is a far harder
   requirement on predictor quality and it shrinks the winning regime by half.

The project's own red team file already printed both constants ("1.25x at INT4,
1.50x at INT8") and I carried the wrong one forward into a burst-constrained
design.

## B2. The compact page cannot be 64 B under the spec's own INT4 format

Section 5.3 specifies group size 32, a per-group FP16 scale, and an outlier
bitmap retaining up to 2 FP16 values per group. Recomputed for a 256 B FP16
exact page (128 elements, 4 groups):

    INT4 payload   64 B
    scales          8 B   (4 groups x FP16)
    outlier bitmap 16 B   (1 bit per element)
    outlier values 16 B   (2 per group x FP16)
    TOTAL         104 B   against a claimed 64 B

The claimed 64 B is achievable only by deleting the scales and the outlier
mechanism, which are the parts that make INT4 numerically usable. **r = 0.406
before the burst floor, 0.5 after it.**

## B3. Prefix sharing as specified CANNOT FIRE

Section 5.1 puts `seq_id` (12 b) inside the logical key. Section 6.3 claims two
sequences with a shared prompt prefix "map the same logical prefix key".

They cannot. Different sequences have different `seq_id`, so different keys,
so different tags, so never a hit. **Section 6.3 is unimplementable as written**,
and with it go `n_share_hit`, CTRL bit 3, invariant 11's purpose and the entire
reference-counting justification for calling this a cache manager.

## B4. The page table tag is 10 bits too narrow

44-bit logical key, 16,384 sets, so 14 index bits, so the tag must be **30 bits**.
Section 6.1 specifies 20. That is **1,024-way aliasing**: 1,024 distinct logical
keys collide on every tag and the lookup returns another sequence's page while
reporting a hit.

Cheap to fix and it still fits: `1 + 30 + 20 + 2 + 8 + 8 = 69 bits of 72`.

## B5. There is no fill path, and allocator addresses do not match host addresses

Section 5.2 has the host write pages at `EXACT_BASE + phys_idx * 256` at
trace-load time. Section 6.2 has the hardware allocator pop `phys_idx` from a
free list at runtime. **Nothing relates the two.** A page table miss allocates a
physical page whose DDR contents were written for a different logical key, so
the fetch returns another page's bytes and the scoreboard fails.

The spec has no mechanism to install a translation and no miss-fill path at all.

---

## Further BLOCKING findings, recorded, not yet hand-verified

- Invariant 10 (at most one exact refetch) contradicts the section 9 watchdog,
  which "issues the exact fetch unconditionally" and is never made one-shot per
  request. The mechanism named as the enforcer of the ceiling is the one that
  can breach it.
- Invariant 11 either makes eviction unreachable (no resident page ever reaches
  refcount 0) or licenses evicting a live page, depending on whether allocation
  sets refcount to 0 or 1. The spec does not say.
- Invariant 12 is vacuous in the attack-6 sense: a design that leaks every page
  satisfies it. It also never says which side of the ledger a refcount>1 page
  sits on, and is false at reset under the only names the spec defines.
- `n_req` counts four op types (LOOKUP_FETCH, ALLOC, RELEASE, PIN) but only one
  moves bytes, which falsifies invariants 6, 8 and 9 and reopens the vacuity hole.
- Section 4 omits three papers whose citation was the stated condition for
  closing the project's only prior BLOCKING red-team finding. Cross-check
  against `docs/research/kv_precision_sweep.md` required.
- A claim that two published designs already achieve a strictly tighter 1.0x
  bound with zero capacity overhead, and that section 3.3 misreads Token-Picker.
  **This one must be verified before any publication.**
- Section 6.1's "single URAM read, one lookup per cycle, fixed latency" is
  reported unbuildable as written, with post-route Fmax around 207 to 211 MHz
  and the URAM288's two ports unable to carry lookup, refcount update and LRU
  update in the same cycle. Above the 200 MHz target, so not fatal, but the
  claim of a single-cycle combined access is not sustainable.

---

## What this changes

The review did what it was built to do. It caught a wrong headline number
before RTL, before a bitstream, and before a public claim. Under the project's
own rule that a disproven claim is a result, the 1.25x figure is now retired and
must not appear in any post, deck or artifact.

SPEC.md goes to v0.3 with the ceiling restated as `(1 + r)` derived from the
burst-legal compact size, the page size chosen deliberately against the table in
B1, prefix sharing either fixed or removed, and a real fill path added.
