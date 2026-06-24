# TEST-VERDICT — dash-inbox-styling (GATE 2)

## Verdict: **DONE**

Two INDEPENDENT testers (`dis-test-a`, `dis-test-b`), separate contexts, both
re-derived the proof (not trusting the implementer's PROOF, which had a botched
byte-identity check) and **converged on DONE**.

### Confirmed by both
- **Alignment**: trailing `│` rail in exactly one column across every scope —
  wide triage (all sev), marked row, empty, per-agent/orphan(⌫)/system(⚙),
  no-from e-view, 70-col + the full narrow drop-ladder (age→from→clamp).
  `base + LW == cw` holds at every rung.
- **Sev pills** red/yellow/cyan via the **shared `sev_pcol`** (inbox `blocked` =
  same red as the agents `✉` pill); one marker column `◉`/`·` (triage) / dim `·`
  (other scopes), never `*`/empty.
- **CLI byte-identity done correctly** (the gap the implementer's proof missed):
  `bin/fleet` diff vs merge-base = 0 lines; CLI `inbox list` md5-identical.
- Diff scoped to `bin/fleet-dash` only. Cyan info-wall judged acceptable (the
  frame-gated escape hatch is NOT triggered).

### Adversary check on the DONE verdict
Both residual gaps attacked and found genuinely non-blocking:
1. Pills overflow at panes **cols ≤18** — pathological; the *old* `[sev]` code
   broke at ≤22, so this is a strict improvement, not a regression. Dashboard
   panes are never that narrow.
2. Age column `%*s` pad-no-clip breaks only at an age string ≥6 chars
   (≥10,000 days) — unreachable.

Neither is a regression or a reachable break. No blocking gap survived. → **DONE.**

Optional follow-ups (not blocking): a one-char `.AGEW` precision on the age field;
a sub-20-col guard if tiny panes ever become a target.
