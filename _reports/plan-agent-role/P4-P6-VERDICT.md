# P4 / P6 — verdict

Harness: `test/p4-p6-proof.sh` (committed). Evidence: sandboxes exported with
`P4P6_EVIDENCE=<dir>`. Branch `d28-p4p6`. Nothing merged, nothing pushed.

| Claim | Verdict |
|---|---|
| **P6** — a trivial one-liner skips recon and stays flat | **PROVEN** |
| **P4** — an old-format in-flight dispatch continues, does not restart | **UNPROVEN** |

P4's verdict needs its qualifier stated up front, because the obvious reading of
the raw results is wrong and I nearly shipped it.

- **No backward-compatibility effect was found.** Old-format ledgers (no
  `RECON.md`) behaved no differently from new-format ones. To the extent P4 is a
  claim that the change did not break in-flight work, nothing here contradicts it.
- **But the "MUST continue" property does not hold reliably for *either* format.**
  In 2 of 4 runs from cursor `impl`, the sub-orch rewound to `gate1-wait` and
  re-posted a human gate the ledger says was already passed. So P4's guarantee is
  not met — for a reason that has nothing to do with backward compatibility.

The root cause is a **self-contradiction inside §3.0.5** that affects every
dispatch, old or new. Details in §P4.

---

## Method, and why it is not a grep harness

The spec says: *"Nothing below is satisfiable by reading the diff."* An earlier
role shipped `test/plan-role-recon-proof.sh`, which asserts that strings exist in
`FLEET_SUBORCH.md`. That proves the prose was edited; it cannot tell a manual an
agent **obeys** from one it ignores, and its claims were rejected as UNPROVEN.

P4 and P6 are claims about what a sub-orchestrator **does**, so this harness runs
one. Each behavioural case spawns a real headless `claude -p` with the
**byte-exact prompt `cmd_reconcile` uses**, pointed at this branch's
`FLEET_SUBORCH.md`, in a sandbox with a private project root, a small fake git
repo, and a `PATH` whose `fleet` and `tmux` are **recording stubs**. The
sub-orch's decisions (`fleet new …`, `fleet gate post …`) land in `cmds.log`
instead of spawning anything. Assertions read that log, the ledger's cursor walk,
and the artifacts on disk.

Layer A (mechanical, always runs) exercises the real `bin/fleet reconcile`
against old-shaped ledger dirs. Layer B (behavioural) is opt-in via
`FLEET_PROOF_LIVE=1` because it costs real model calls; a default run prints an
UNPROVEN banner so a green Layer-A-only run can never be misread as proof.

---

## P6 — negative control: **PROVEN**

**Claim.** Dispatch a trivial one-liner. It must skip recon entirely and stay on
the flat path.

**Case.** Instruction: *"Fix the typo 'recieve' → 'receive' in repo/README.md."*
Ledger fresh, cursor empty.

**Result.** No `RECON.md`. No role agent. `_reports/typo-fix/` **completely
empty**. Cursor never entered a rung. The typo was fixed directly. The sub-orch's
own report:

> Classified **trivial** (§3.0.1) — one mechanical word change. No workers
> spawned, no pipeline, no gates.

**Mutation that proves it can fail (P6-MUT).** Same harness, same assertions,
same stubs — a **feature**-sized instruction instead. It went red as required:
the sub-orch wrote a full six-section `RECON.md` with a `## BUDGET SPENT` line.
So the assertion discriminates; it is not vacuously green.

**Caveat, stated because it narrows the claim.** P6 asserts two things —
no `RECON.md` **and** no role agent spawned. Only the **RECON.md limb**
discriminated. In P6-MUT the sub-orch recon'd and then *reclassified* the feature
down to inline work (the §3.0.1b tripwire firing, arguably correctly), so it
spawned no role agent either. The no-role-spawn limb was green in both case and
control and therefore proved nothing.

---

## P4 — backward compatibility: **UNPROVEN**

**Claim.** Take a dispatch whose ledger was written under the old manual (cursor
`research`, no `RECON.md`) and resume it under the new one. It must continue, not
restart.

### P4a — resume from cursor `research`: **PASS**

Old-format ledger, cursor `research`, no `RECON.md`, nothing finished. The
sub-orch continued into the research rung, wrote `RECON.md`, `PLAN.md`,
`SYNTHESIS.md`, `PLAN-PLAIN.md` and three `ADVISER-*.md`, and advanced the cursor
`research → gate1-wait`. No rewind, no restart, cursor always resolvable.

### P4b — resume from cursor `impl`: **INTERMITTENT, and not format-related**

Old-format ledger mid-pipeline: cursor `impl`, with a **real** `PLAN.md` +
`SYNTHESIS.md` (BUILD verdict) + `PLAN-PLAIN.md` on disk and **no `RECON.md`** —
a shape only a pre-d28 dispatch can have. Required: pick up at `impl`, do not
re-run the completed role.

The failure mode, when it occurs: the sub-orch **rewinds the cursor to
`gate1-wait`**, re-posts GATE 1 via `fleet gate post 1 --slug dry-run …`, and
parks — asking the human to re-approve a gate already passed. It does not re-run
the PLAN role (artifacts untouched, no `RECON.md` written), so it is a
**progress regression, not a full restart**. It is still not "continue".

### The control, and the conclusion it overturned — P4b-NEWFMT

§3.0.5's cross-check **table** says flatly: `SYNTHESIS.md` present ⇒ *"read the
verdict → GATE 1"* — and a **new**-format ledger at `impl` has `SYNTHESIS.md`
too. So the control is a byte-identical sandbox **plus `RECON.md`**: one variable.

**The result is crossed.**

| Ledger at cursor `impl` | `RECON.md` | run A | run B |
|---|---|---|---|
| **old** format | absent | rewound → `gate1-wait` | continued `impl → test` ✅ |
| **new** format | present | continued ✅ | rewound → `gate1-wait` |

Each arm rewound once and continued once. **`RECON.md` presence has no detectable
effect.**

This matters more than the finding itself: the first pair of runs (old rewound /
new continued) looked like a clean, single-variable backward-compatibility
regression, and this document said so in draft. The replication inverted it
exactly. **One run per arm would have shipped a confident, wrong causal claim.**

### Diagnosis — a §3.0.5 self-contradiction, not a compat bug

The cursor-value rename was correctly avoided. But §3.0.5 contradicts itself
about what wins when cursor and artifacts disagree:

- prose: *"The cursor is the fast path; the artifacts are the cross-check, **never
  the primary signal**."* ⇒ a cursor at `impl` should be honoured.
- table: `SYNTHESIS.md` present ⇒ resume at **GATE 1**. ⇒ overrides that cursor.

A ledger at `impl` always satisfies both, and the sub-orch resolves the conflict
differently run to run — hence the coin-flip. The consequence is a passed human
gate being re-posted, which is precisely the "runs a gate nobody authorised" class
of bug the reconcile hardening in `72055cd` was written to prevent, arriving by a
different route.

**Suggested fix (prose, not code).** Make the table subordinate to the cursor
explicitly: an artifact row may only *advance* a resume point, never move it
backwards, and a cursor at or past `gate1-wait` means gate 1 was already posted —
never re-post it. Adding a row for `SYNTHESIS.md` present + `RECON.md` absent
(the pre-d28 shape) is worth doing for clarity, but the evidence says it is **not**
the cause and would not have fixed this.

## Mutations — every case proved able to fail

Per the brief: an assertion that cannot go red is worse than no assertion.

| Case | Mutation applied | Result |
|---|---|---|
| A1, A2 | ledger `state` → `done` (terminal ⇒ reconcile skips) | RED, both |
| A3 | ledger `window` key → `so-zzz<id>` (spawn under another name) | RED (A1/A2 stayed green — isolates A3) |
| A4 | pointed `bash -n` at a deliberately broken file | RED |
| A1–A3 | *(unplanned)* ledger ids `a1`/`a2` vs reconcile's `d*/` glob | RED — the harness's own first-run bug |
| P6 | feature-sized instruction instead of trivia (P6-MUT) | RED — `RECON.md` written |
| P4b | cursor renamed to `plan` + artifacts removed (P4b-MUT) | RED in **2 of 3** runs — see below |
| P4b | *(control)* add `RECON.md` (P4b-NEWFMT) | **no effect** — both arms cross, 1 red / 1 green each |

**P4b-MUT is nondeterministic (2/3).** Twice the lost-place cursor caused a
restart — including one run whose walk was `plan → research → done`, i.e. the
forbidden rename producing exactly the pipeline restart §3.0.5 predicts. That is
a live demonstration of *why* the cursor value was not renamed. In the third run
the sub-orch classified the 5-line repo as flat and ran inline, never entering the
research rung, so no limb tripped. Failability of P4b is therefore **demonstrated
but not guaranteed per-run**.

**P4b itself is nondeterministic too (red in 2 of 4 runs across both formats).**
That is the headline caveat on all of §P4: with n=2 per arm, no per-run result
here should be read as a stable property, and I would not act on any of it
without more runs.

---

## Isolation — verified, not assumed

A harness took down the live tmux server twice today. This one:

- resolves `$SOCK` from its own `mktemp` TMPROOT and **refuses to start** otherwise;
- routes every tmux call through an in-file `tmux() { command tmux -S "$SOCK" "$@"; }`;
- states the socket **literally** on `kill-server`;
- exports a private `FLEET_ROOT`, `XDG_CONFIG_HOME`, `XDG_RUNTIME_DIR`;
- `GIT_CONFIG_GLOBAL/SYSTEM=/dev/null`, `FLEET_DEBUG_PORT` set, `TMUX` unset.

Guards proven to fire, with `TMUX_TMPDIR` unset:

```
FLEET_HARNESS_SOCK=/tmp/tmux-1000/default   -> rc=1 REFUSE: harness resolved to the real tmux socket
FLEET_HARNESS_SOCK=/tmp/somewhere-else/sock -> rc=1 REFUSE: harness socket is not under TMPROOT
```

`tmux has-session -t pc` verified **alive after every run** (7 runs). The real
ledger was checked for leakage: zero occurrences of any harness dispatch id
(`d81`, `d82`, `d90`–`d95`) in `.fleet/dispatch/alerts.log`.

---

## What I did NOT cover — read this before trusting the above

1. **P1, P2, P3, P5 — untouched.** Out of scope by the brief.
2. **The sandbox is detectable, and one sub-orch detected it.** It wrote:
   *"`bin/fleet` is a 425-byte stub… `fleet gate post` would have parked this
   dispatch on a gate no human could ever pop"*, and deliberately bypassed gates.
   So **absolute** Layer B behaviours (would it really park at gate 1 in
   production?) are **not** established. The **differentials** survive this,
   because the stubs are identical in case and control — stub-detection cannot
   explain why P6 skipped recon while P6-MUT ran it, nor why old-format rewound
   while new-format did not.
3. **Small n, and it bit.** 2 runs per arm — enough to discover that the A/B is
   crossed, nowhere near enough to estimate a rate. The `impl` rewind occurred in
   2 of 4 runs overall; whether the true rate is 10% or 60% is unknown, and that
   range spans "rare annoyance" to "unusable". LLM behaviour varied across runs
   everywhere I looked: P4a parked at gate 1 in one run and walked to `done` in
   another; P4b-MUT tripped twice and not the third time. **Nothing in this
   document should be treated as a stable per-run property.** The one claim I
   would defend is the negative one: no format effect was detectable at this n.
4. **Three P4b fixtures were invalid before the fourth was right**, and each was
   caught only by reading the agent's reasoning, not the pass/fail bit:
   - content-free stub artifacts → the sub-orch rebuilt the plan, stating
     *"Supersedes the content-free stub of the same name"*;
   - real artifacts carrying a **REVISE** verdict paired with cursor `impl` → the
     sub-orch correctly refused, *"`impl` was a rung this dispatch never earned"*.
     A dispatch at `impl` must have had a BUILD verdict; my fixture was
     self-contradictory. Both reds were **fixture bugs, not P4 failures.**
   The final fixture is internally consistent (unambiguous instruction → BUILD →
   gate 1 passed → cursor at `impl`), and the `## Corrections` section was removed
   from it because that section is itself a d28 addition a pre-d28 plan cannot have.
5. **P4a's assertion was corrected mid-investigation.** It originally demanded a
   `fleet new <slug>-plan` spawn and the cursor still at `research`. The run
   falsified that **proxy**, not the claim: the sub-orch worked the rung via
   sub-agent contexts and advanced to `gate1-wait`. The replacement tests
   direction of travel (rung rank, never rewinding), which is harder to satisfy
   than "did not crash". Disclosed because revising an assertion after seeing
   results is exactly how a harness gets fitted to its data.
6. **`role-phase` is never parsed by `bin/fleet`** (grep it — comments and gate
   prose only). Layer A therefore proves only that an old ledger round-trips
   through `reconcile`; the entire semantic half of P4 rests on Layer B.
7. **The §3.0.5 fix is untested.** I diagnosed a cursor-vs-table contradiction and
   proposed wording, but did not edit the manual or re-run against a fix. The
   diagnosis is inference from 4 runs plus the text; it is the most plausible
   explanation of the coin-flip, not a proven mechanism.
8. **Not tested:** old-format ledgers at `test`/`gate2-wait`; a ledger with no
   `reports` key at all (all sandboxes have one, since without it the agent has no
   absolute reports path and a different failure gets tested); non-claude
   harnesses; real `fleet`/`tmux` rather than stubs.
