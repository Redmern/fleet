# P2 replacement proposal — d28 / plan-agent-role

**Status:** proposal, not ratified. Nothing here changes the pre-committed rule in `4ab4959`'s
body until the human says so. See §6, which exists specifically so that replacing a failing
test cannot become the way to escape its consequence.

**Author's stake, declared:** I ran the d28 test round that produced the P2 FAIL. A proposal
to replace the test I failed is exactly the kind of thing that should be read adversarially.
§3 is the part most likely to be self-serving, so it leads with the result that cuts against me.

---

## 1. What P2 was, and why it can no longer be run as written

PROOF DESIGN P2:

> Read the PLAN agent's transcript. Its explorer sub-agents must **not** be re-deriving the
> territory already listed in `RECON.md`. If they are, the handoff contract failed and the
> change bought nothing but overhead.

That test assumes the design in `PLAN.md` W3: *TERRITORY / PRIOR ART are trusted — do not
re-derive them.* **That design did not ship.** What shipped, and what has now been explicitly
ruled to stay, is the inverse: RECON is the untrusted side, every claim is a lead to verify,
the PLAN role overrules RECON and never the reverse.

Under the shipped-and-ruled design, an explorer re-walking RECON's territory is **correct
behaviour**. P2 as written now fires on conformance. It is not a failing test; it is a test of
a property the system no longer claims.

This matters for the record: P2's FAIL verdict was accurate *about the specified design* and
is not evidence of a defect in the shipped one. Neither is it a clean bill of health. It is an
untested claim, which is worse than either, and that is what this proposal is for.

## 2. The constraint that shaped everything below

PROOF DESIGN is explicit that P2 is

> checked by reading the transcript, not by asking the agent whether it complied.

Any replacement inherits that constraint. This rules out the obvious design — having explorers
tag each claim `INHERITED` vs `DERIVED` — because a self-declared tag *is* asking the agent
whether it complied. Every check below is either a mechanical property of artifact text or a
decision recorded by a different actor than the one being judged.

## 3. Attempted salvage: mine the artifacts. It failed. Here is the data.

Before proposing anything, I tried to rescue P2's original question from artifacts alone, by
measuring overlap between explorer reports. Corpus: every `_reports/<slug>/` with ≥2
`EXPLORE*.md`, pre- and post-RECON (n=4 — small, and that is part of the finding).

Metric: pairwise overlap of referenced repo paths between each pair of explorer reports,
`|A∩B| / min(|A|,|B|)`.

| dispatch | RECON | overlap (full text) | overlap (first 4000 chars) |
|---|---|---|---|
| completion-reporting | yes | 0.85 | 0.83 |
| fleet-lock-unlock | yes | 0.95 | 1.00 |
| plan-agent-role | no | 0.33 | 0.33 \* |
| suborch-nvim | no | 0.50 | **0.83** |

\* only 3874 chars, so never truncated — i.e. the one apparently-clean data point is not
actually size-controlled.

On full text this looks like a strong result *against* the change: post-RECON explorers overlap
far more. **It does not survive.** Post-RECON reports run 3–10× longer, and overlap-by-mention
scales with length. Size-controlled, `suborch-nvim` (no RECON) moves 0.50 → 0.83, landing among
the RECON dispatches. With n=4 and length dominating the signal, the metric does not
discriminate, and the apparent finding was an artifact of my own measurement.

**Conclusion: P2's original question is not recoverable by post-hoc text mining.** Reporting
the full-text row as a finding would have been the same failure this dispatch already caught in
the `[7]` assertion — a number that looks decisive because the measurement was built to fit it.

One sub-result did survive and is worth keeping: **anchor-level (`file:line`) overlap is ~0.00
across every dispatch**, RECON or not. Explorers essentially never cite the same line. Whatever
duplication exists is at the level of *which files get opened*, never *which facts get
extracted*.

## 4. The replacement

Two checks. Both artifact-only, both mechanical, neither a self-report.

### P2a — Corrections density (does RECON supply leads worth verifying?)

The shipped design's actual claim is not "RECON saves the explorers work". It is "RECON gives
the PLAN role a cheap starting position that it then overrules". The artifact that records
whether that happened already exists and is already mandatory: `## Corrections` in `PLAN.md`.
It is also the only check on `RECON.md`, which no adversary ever reviews.

Make it measurable by requiring each entry to carry both halves:

- the RECON claim being corrected, quoted or referenced;
- the `file:line` that settles it.

Then compute, from artifacts alone:

- `checked` — number of RECON claims with a Corrections entry;
- `wrong` — number found wrong, missing, or misleading;
- `unchecked` — RECON claims with no entry either way.

**Passes when:** every RECON claim is accounted for (`unchecked == 0`), and entries cite a
resolving `file:line`. **Fails when:** `## Corrections` is present but vacuous — the empty-case
string shipped while RECON made checkable claims nobody checked. That is the real failure mode
here, and unlike P2-as-written it is detectable without a transcript.

Existing evidence suggests this will pass on merit rather than by construction: 12 substantive
corrections in one dispatch, an 18-row wrong-anchor table in the other.

### P2b — Assigned-scope partitioning (does RECON let the sub-orch carve non-overlapping work?)

The benefit that plausibly *does* exist is partitioning — RECON lets the sub-orch hand each
explorer a distinct territory. §3 shows this cannot be recovered after the fact from report
text. So record the decision instead of mining its consequences.

Require the sub-orch, when it spawns explorers, to write each explorer's **assigned scope**
into the artifacts dir (one line per explorer: name + the RECON territory it owns). Then:

- overlap between *assigned scopes* is directly computable;
- it is written by the **sub-orch**, not by the explorer being judged, so it is a dispatch-time
  decision rather than a compliance claim — satisfying §2;
- it costs one short write, and it makes the sub-orch state its partition explicitly, which is
  independently useful when a dispatch has to be resumed.

**Passes when:** assigned scopes are present for every explorer and pairwise scope overlap is
low — proposed threshold ≤0.34, matching the only uncontaminated pre-RECON observation (0.33).
**Fails when:** scopes are absent, or identical, i.e. the sub-orch fanned out without using
RECON to divide the work — in which case RECON bought nothing on this axis either.

The threshold is a starting number chosen from one data point and should be treated as
provisional until there are enough post-instrumentation dispatches to calibrate it. Stated
plainly so it is not mistaken for a measured value.

## 5. What remains unprovable from artifacts, permanently

**The counterfactual.** Whether the explorers would have found the same ground without RECON
cannot be recovered from any artifact, because the artifact set contains only the run that
happened. Establishing it needs either a surviving transcript or a genuine A/B — the same
instruction dispatched with and without the recon step. No amount of text mining substitutes,
and any proposal claiming otherwise (including §3's, which was mine) should be disbelieved.

If the counterfactual matters enough to pay for, the A/B is the honest instrument, and it is a
separate piece of work from this proposal.

## 6. Effect on the pre-committed failure condition — read this before ratifying

The rule recorded in `4ab4959`: **if P2 or P3 fails, revert it and keep only the rename.**

Replacing a test that failed with tests that are expected to pass is the single most obvious
way to launder a bad result, and this proposal must not be allowed to function that way.
Therefore:

1. **P2's FAIL is not vacated by this proposal.** It stands as: the shipped design was never
   the specified one, and the specified property was never tested.
2. **The rule transfers, it does not lapse.** P2a and P2b inherit it. If P2a fails (RECON's
   claims go unchecked) or P2b fails (no partitioning), then RECON is costing a sub-agent and a
   full re-verification pass for no demonstrated benefit, and the correct response is still to
   revert `4ab4959` and keep only the rename.
3. **P3 is untouched.** It still requires one live observation. `72055cd` hardened its
   mechanism by moving the cap to the recon sub-agent's output boundary, but a hardened
   mechanism is not an observed one.
4. **This is a scope reduction and should be logged as one.** P2-as-written asked whether RECON
   *prevents duplicated work*. P2a/P2b ask whether RECON *supplies verified leads* and *enables
   partitioning*. Those are weaker claims. Ratifying this means accepting that the original
   anti-duplication claim goes untested — permanently, per §5 — not that it was satisfied.

If that trade is not acceptable, the alternative is the A/B in §5, or reverting on the strength
of the P2 failure as it already stands. Both are defensible. Choosing between them is the
human's call, not the test author's.

## 7. Implementation cost

- `FLEET_SUBORCH.md` §3.0.1b / §3.0.2 and the pipeline skill: state the two new requirements
  (Corrections entries cite a resolving `file:line`; sub-orch records assigned scopes). Doc-only.
- `test/plan-role-recon-proof.sh`: assert both requirements are stated. Grep-level, same as the
  rest of that harness — it proves the docs say it, not that a run obeyed it.
- The measurements themselves (`unchecked`, `wrong`, scope overlap) run against a real
  dispatch's `_reports/<slug>/`, so they land with the next genuine dispatch rather than a
  staged one — consistent with the decision to defer P1/P2/P5.
- No `bin/fleet` change.
