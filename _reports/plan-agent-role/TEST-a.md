# TEST-a — plan-agent-role (d28), TESTER A: P1, P4, P6

Commit under test: `536b72f docs(suborch): add RECON pre-step, rename Role 1 RESEARCH -> PLAN`
Docs under test:
- `/home/red/proj/pc-tune/fleet/fleet_plan-agent-role-test/FLEET_SUBORCH.md` (verified byte-identical
  to the commit: `git diff --stat HEAD -- FLEET_SUBORCH.md` → empty)
- `/home/red/.claude_personal/skills/fleet-implementation-pipeline/SKILL.md` (out of git, edited in place)

Verdict summary: **P1 FAIL** (two independent defects) · **P4 PASS** · **P6 PASS**.

---

## Evidence validity — checked before relying on the prior worker's artifacts

The prior worker's two dispatches at `/tmp/tb28` are **valid evidence**: I confirmed from the
sub-orchestrator transcripts that both were seeded with the doc under test, not main's copy.

```
/home/red/.claude_personal/projects/-tmp-tb28-root/b87d8941-…jsonl  line 6 (seed prompt):
  FIRST, read and follow your operating manual:
  /home/red/proj/pc-tune/fleet/fleet_plan-agent-role-test/FLEET_SUBORCH.md
  THEN handle DISPATCH ID: p1
… line 12: TOOL_USE Read {"file_path": ".../fleet_plan-agent-role-test/FLEET_SUBORCH.md"}
```
Same in `3a342513-…jsonl` for p3. This mattered because `main/FLEET_SUBORCH.md` does **not** contain
§3.0.1b at all (`grep -c RECON` → 1, and that hit is `FLEET_RECONCILE_CAP`), and it has diverged
forward on an unrelated lineage (absolute `$reports` ledger key, §3.0.6 symlink farm) that the
536b72f branch does not carry. Anyone re-running this proof against `main` would be testing the
wrong file.

Incidental: the GATE 1 re-orient pointer in every posted message names
`/home/red/proj/pc-tune/fleet/main/FLEET_SUBORCH.md`, because `gate_post` derives it from
`$FLEET_DIR` of whichever `fleet` binary is on `PATH` (`bin/fleet:10`). In these test runs that
resolved to the host's `~/.local/bin/fleet` → `main`. Not a defect of this change (in production
`main` *is* the manual), but it means a sub-orch unparking from a gate during this branch's proof
would re-orient onto a manual **without** the RECON section. Flagging, not scoring.

---

## P1 — dispatch to gate 1 — **FAIL**

Evidence: `/tmp/tb28/root/_reports/{completion-reporting,fleet-lock-unlock}/`, ledgers
`/tmp/tb28/root/.fleet/dispatch/{p1,p3}/meta.tsv`, inbox `/tmp/tb28/root/.fleet/inbox/*.msg`,
transcripts under `/home/red/.claude_personal/projects/-tmp-tb28-root/`.

| # | Required observation | Result |
|---|---|---|
| a | `RECON.md` exists | **PASS** — both dispatches |
| b | within the line cap (**≤25**, `FLEET_SUBORCH.md:105`) | **FAIL** — 33 and 35 lines |
| c | has all six sections | **FAIL** — schema was never shipped (see below) |
| d | `## BUDGET SPENT` matches the transcript | **FAIL** — no such section exists anywhere |
| e | `PLAN.md` carries `## Corrections` | **PASS** — both, substantive |
| f | gate 1 posted, `PLAN-PLAIN.md` path resolves | **PASS** — both, `stat` confirmed |
| g | cursor walked `research → gate1-wait`, value still `research` | **PASS** — both |

### (b) FAIL — the ≤25-line RECON.md cap was breached in both dispatches

```
$ wc -l /tmp/tb28/root/_reports/*/RECON.md
33 completion-reporting/RECON.md
35 fleet-lock-unlock/RECON.md
```
`FLEET_SUBORCH.md:105` — *"Write that digest, verbatim or tightened, to `_reports/<slug>/RECON.md`
— **≤25 lines**, then stop."* Breached by 32% and 40%, **2 out of 2 runs**. This is not a one-off
slip: the transcript audit shows why the cap cannot bind as written. The `≤15-line digest` cap is
described as *structural* (it is what the sub-agent returns), but **the sub-orch, not the sub-agent,
writes `RECON.md`** — in both runs, ~20s after the digest returned:

- p1: `Write → _reports/fleet-lock-unlock/RECON.md`, `uuid 6c50d511-…`, `isSidechain: false`,
  ts `05:02:39.645Z`, digest returned `05:02:16`.
- p3: `Write → _reports/completion-reporting/RECON.md`, `uuid 612b35cd-…`, `isSidechain: false`,
  ts `05:02:41.345Z`.

So the ≤25-line cap on the artifact is an ordinary self-restraint rule in the sub-orch's own
context — exactly the "rule the model has to remember to obey" that `PLAN-PLAIN.md:46-48` says the
design exists to avoid — and it was disobeyed both times. Only the ≤15-line digest is structural,
and even that was breached once (see below).

### (c) FAIL — the six-section schema was never implemented

`PLAN.md` W1 (`:35-44`) specifies `RECON.md` sections as **fixed**: `## TASK`, `## SLUG`,
`## TERRITORY`, `## PRIOR ART`, `## OPEN QUESTIONS`, `## BUDGET SPENT`. The shipped doc contains
**none** of them:

```
$ grep -rn "BUDGET SPENT\|## TASK\|## SLUG\|## TERRITORY\|PRIOR ART\|OPEN QUESTIONS" \
    FLEET_SUBORCH.md ~/.claude_personal/skills/fleet-implementation-pipeline/SKILL.md
NONE FOUND
$ awk '/^### 3\.0\.1b /{f=1} f&&/^### 3\.0\.2 /{f=0} f' FLEET_SUBORCH.md | grep -c '^## '
0
```
The shipped §3.0.1b prescribes only free-form content ("which files/dirs … with `file:line` anchors,
what already exists …, the one or two facts that would change how the work is framed"). Predictably,
the two artifacts share no structure with each other: `completion-reporting/RECON.md` invented three
headings of its own, `fleet-lock-unlock/RECON.md` used **zero** headings (a numbered list).

This is a genuine spec→implementation divergence, not a technicality. `PLAN.md:39` calls the SLUG
section *"the artifact that makes the choice reviewable"* — the slug rationale is the single item
`PLAN-PLAIN.md:13-17` identifies as the change's core justification, and it is recorded in neither
artifact.

### (d) FAIL — the audit clause is unimplementable as shipped

`PLAN-PLAIN.md:120-121` makes this the *point* of the section: *"Its `## BUDGET SPENT` line matches
what the transcript actually shows — this is the audit, and it is the reason that section exists."*
There is no `## BUDGET SPENT` line in either artifact, and no requirement to write one in either
doc. There is nothing to reconcile against the transcript. **The audit designed into P1 cannot be
performed on the shipped docs.**

I therefore ran the audit directly against the transcripts instead, to establish whether the
budgets were honoured in substance (delegated forensic pass over the four session JSONLs):

| Rule (`FLEET_SUBORCH.md:101-121`) | p1 | p3 |
|---|---|---|
| exactly one read-only recon sub-agent | PASS (1, `subagent_type: Explore`) | PASS (1) |
| no second recon sub-agent before PLAN | PASS | PASS |
| returned digest ≤15 lines | PASS (12 lines) | **FAIL (22 lines)** |
| writes limited to `RECON.md` | PASS | PASS (+ `mkdir -p` of its parent) |
| no PLAN.md / SYNTHESIS.md / PLAN-PLAIN.md, no code | PASS | PASS |

p3's breach is instructive: the sub-orch's own sub-agent prompt granted *"a digest of AT MOST 15
lines… Then at most 3 extra lines naming the one or two facts…"* — it **budgeted past the cap by
construction**. The cap binds the sub-agent's output but nothing binds the sub-orch's prompt-writing,
so the "structural" cap is one prompt away from being advisory. Combined with (b), the sub-orch
overran a recon budget in 2 of 2 dispatches.

### Sub-checks that PASSED

**(e)** `## Corrections` present and substantive in both — not a token "none":
`completion-reporting/PLAN.md:116` (RECON's channel count rebutted: seven producers, not four);
`fleet-lock-unlock/PLAN.md:398` (18 wrong line anchors, 3 wrong claims, 7 omissions). The
handoff/trust asymmetry is working.

**(f)** Both gates posted, and the path in the popped body resolves:
```
$ cd /tmp/tb28/root && stat -c '%n %s' _reports/fleet-lock-unlock/PLAN-PLAIN.md \
                                       _reports/completion-reporting/PLAN-PLAIN.md
_reports/fleet-lock-unlock/PLAN-PLAIN.md 11589
_reports/completion-reporting/PLAN-PLAIN.md 9189
```
No dead link — the rename regression `PLAN-PLAIN.md:123-124` warns about did not occur.

**(g)** Cursor value unchanged. `.fleet/dispatch/p1/meta.tsv`:
```
role-phase	research
role-phase	gate1-wait
state	gate1-wait
```
(p3 identical.) Literal `research`, never `plan`, no `recon` rung.

---

## P4 — backward compatibility with an in-flight old-manual ledger — **PASS**

Run live in a fully isolated throwaway environment (see Isolation below), dispatch `p4`.

**Fixture** — a ledger as the *old* manual would have left it: cursor `research`, **no `RECON.md`**,
old-style worker key `agent-idle-badge-research` in `workers.tsv`, and a completed old-manual
RESEARCH role (`PLAN.md` **without** a `## Corrections` section, `SYNTHESIS.md` = BUILD,
`PLAN-PLAIN.md`) in `/tmp/tbA/root/_reports/agent-idle-badge/`.

```
$ cat /tmp/tbA/root/.fleet/dispatch/p4/meta.tsv     # before
state	active
window	so-p4-agent-idle-badge
role-phase	research
$ cat /tmp/tbA/root/.fleet/dispatch/p4/workers.tsv
scratch	agent-idle-badge-research
```

**Result — resumed, did not restart.**
```
$ cat /tmp/tbA/root/.fleet/dispatch/p4/meta.tsv     # after
role-phase	research
window_id	@2
window	so-p4-agent-idle-badge
reports	/tmp/tbA/root/_reports/agent-idle-badge
role-phase	gate1-wait
state	gate1-wait
$ ls /tmp/tbA/root/_reports/agent-idle-badge/
PLAN-PLAIN.md  PLAN.md  SYNTHESIS.md          # no RECON.md created → no re-recon
$ tmux list-windows -a -F '#{window_name}'
zsh / so-p6 / so-p4-agent-idle-badge          # no respawned PLAN role window
$ cat /tmp/tbA/root/.fleet/dispatch/p4/workers.tsv
scratch	agent-idle-badge-research             # untouched, old key preserved
```
GATE 1 posted (`/tmp/tbA/root/.fleet/inbox/1784532555.585084401.2.msg`, sev=warn,
`[FLEET-GATE:1 slug=agent-idle-badge action=implement]`) and parked. The sub-orch's own account:

> *Ledger said `role-phase research`, but `_reports/agent-idle-badge/SYNTHESIS.md` on disk → PLAN
> role already finished. Cross-check beat cursor (§3.0.5). Did not re-run PLAN, did not re-recon.*
> *Caveat worth flagging: PLAN.md has no `## Corrections` section and no RECON.md exists — it was
> written under the old manual. Not re-running for that alone.*

This is the strongest form of the test: `SYNTHESIS.md` present with `RECON.md` **absent** is the
state the new §3.0.5 cross-check table could most plausibly have misread as "recon never ran ⇒ start
the rung over". It did not. The added `RECON.md` row did not invert the table's precedence, the
mandatory-`## Corrections` rule did not retroactively invalidate an old-manual artifact, and one
sub-check also survived incidentally: `meta_compact` preserved `role-phase research` through the
respawn. Note the `research` cursor value is the *reason* this works, exactly as `PLAN.md:60` argues.

---

## P6 — negative control, trivial one-liner — **PASS**

Live, same isolated environment, dispatch `p6`.
Instruction (`/tmp/tbA/root/.fleet/dispatch/p6/instruction.txt`):
> *Add a one-line comment directly above the `fleet_root()` function in bin/fleet saying what it
> returns. Nothing else.*

**Recon did not fire; the flat path held.**
```
$ find /tmp/tbA/root/_reports -type d
/tmp/tbA/root/_reports
/tmp/tbA/root/_reports/agent-idle-badge      # p4's only — nothing for p6
$ cat /tmp/tbA/root/.fleet/dispatch/p6/meta.tsv
window_id	@1
window	so-p6
state	done                                  # no role-phase cursor ever written
$ ls /tmp/tbA/root/.fleet/dispatch/p6/
instruction.txt  meta.tsv  STATUS.md          # no workers.tsv → zero agents spawned
```
No `RECON.md`, no `_reports/<slug>/` dir, no `role-phase` rung, no worker windows, no sub-agents. The
sub-orch did the edit itself in one shell command and posted an info-sev summary
(`1784532544.415312655.1.msg`): *"Classified trivial (mechanical one-liner) — no role pipeline, no
workers."* The edit landed at `bin/fleet:94`. The classifier's cheap-bias (`FLEET_SUBORCH.md:51-57`)
is intact; §3.0.1b's feature-path-only scoping held.

---

## Extra verification (as instructed — not taken on the prior worker's word)

**1. The three rewritten assertions in `test/plan-role-recon-proof.sh` — substance NOT weakened.**
`git log --oneline -- test/plan-role-recon-proof.sh` shows a **single** commit (536b72f); the file is
clean against HEAD, so the rewrite was folded in pre-commit rather than layered on top. Reading the
three:
- *cursor-rationale check* — `tr '\n' ' ' | grep -qEi 'rung is still spelled .?research|value stays
  the literal string .?research|(stays|remains) the (literal )?string .?research'`. Flattening is
  legitimate (the explanation genuinely wraps across `FLEET_SUBORCH.md:261-268`); the assertion still
  requires the doc to state the rung stays `research`.
- *artifact-triple check* — `tr '\n' ' ' | grep -qE 'PLAN\.md.{0,300}SYNTHESIS\.md.{0,300}PLAN-PLAIN\.md'`.
  Flattening legitimate; **ordering is still enforced**. The `.{0,300}` windows are loose but the
  three filenames must still co-occur in order.
- *`## Corrections` mandatory check* — `'## Corrections.{0,600}(MUST|mandatory|required|always)|…'`
  run through line-based `grep -E`, i.e. **not** flattened, so it only passes because `MUST` and
  `## Corrections` happen to land on the same source line (`:138`). Fragile to a reflow, but not
  weakened.
Judgement: all three are honest accommodations of markdown wrapping. **No assertion was loosened to
convert a red into a green.** The harness's real limitation is categorical, not sneaky — it is
grep-level and proves only do-not-break contracts, as the task brief already states; nothing in it
would have caught the (b)/(c)/(d) failures above.

**2. `FLEET_SUBORCH.md` and `SKILL.md` DO agree.** Budgets (`≤15`-line digest, `≤25`-line
`RECON.md`, `≤8` inline read-only calls), the artifact name `RECON.md`, the cursor value `research`
with recon folded into that rung, `## Corrections` mandatory with the `None — RECON verified
accurate.` empty case, and the three gate filenames all match — `SKILL.md:67-96` vs
`FLEET_SUBORCH.md:90-143`. They also agree in their **omission**: neither ships the six-section
schema or `## BUDGET SPENT`. So W7 (ship both, no contradiction) holds; the divergence in P1(c)/(d)
is uniform across both docs, i.e. a deliberate-looking scope reduction from `PLAN.md` W1, not a
half-applied edit.

**3. The harness SKIP is a genuine skip, not a silent pass.**
```
$ FLEET_SKILL_MD=/nonexistent/SKILL.md bash test/plan-role-recon-proof.sh | tail -6
[10] SKILL.md agrees (shipped in the same change; lives outside this repo)
  SKIP(SKILL.md assertions): /nonexistent/SKILL.md not present on this machine
```
`skip()` prints a distinct `SKIP(...)` line and — unlike `fail()` — does not set `FAILED`; it also
does not emit `PASS`. So a missing `SKILL.md` is reported as skipped and cannot masquerade as a
passing assertion. Minor cosmetic gripe: the run still ends `ALL PASS` with a skip outstanding, which
slightly overstates coverage; the skip line is visible immediately above it. With `SKILL.md` present
the full run is `ALL PASS` (7/7 SKILL assertions execute).

---

## Isolation (mandatory-isolation compliance)

Every live dispatch I ran (P4, P6) used a throwaway environment modelled on `/tmp/tb28`:

```
TMUX_TMPDIR=/tmp/tbA/tmuxtmp      # socket /tmp/tbA/tmuxtmp/tmux-1000/default (verified)
XDG_RUNTIME_DIR=/tmp/tbA/xdg      # child fleet cannot reach the real fleetd
XDG_CONFIG_HOME=/tmp/tbA/conf
FLEET_ROOT=/tmp/tbA/root
FLEET_SESSION=proofA
tmux set -t proofA @fleet_root /tmp/tbA/root   # satisfies fleet_root() bin/fleet:94-100,
                                               # which consults @fleet_root BEFORE $FLEET_ROOT
```
Repo under test copied to `/tmp/tbA/root/fleetcopy` and re-`git init`ed; dispatches driven with
`/tmp/tbA/root/fleetcopy/bin/fleet` so `FLEET_DIR` (`bin/fleet:10`) resolved to the copy and the
sub-orchs read the doc under test.

Post-run safety checks, all clean:
```
$ grep -rl "p4\|p6\|tbA\|agent-idle-badge" /home/red/proj/pc-tune/.fleet/inbox/   → no match
$ ls /home/red/proj/pc-tune/.fleet/dispatch/                                      → d1…d28 only
$ TMUX_TMPDIR=/tmp tmux ls   → pc: 4 windows (attached) · techweb2: 5 windows (attached)
$ git status --short          → only the 3 pre-existing modified test/ files (baseline)
```
No writes to `/home/red/proj/pc-tune/.fleet/`, the default socket `/tmp/tmux-1000/default` was never
addressed, both live sessions confirmed alive afterwards, and the isolated server was killed at
teardown. I did not merge, push, edit any doc under test, or alter any assertion.

---

## Bottom line

**P4 and P6 pass cleanly on live behavioural evidence** — the two properties most likely to have
been broken by this change (in-flight ledger compatibility, and recon carpet-bombing the cheap path)
are sound, and the cursor-value decision at `PLAN.md:60` is vindicated.

**P1 fails on the budget and on its own audit mechanism.** Three concrete defects:

1. The **≤25-line `RECON.md` cap was breached in 2 of 2 dispatches** (33, 35), and once at the
   digest layer too (22 vs ≤15). The artifact cap is not structural — the sub-orch writes the file
   itself — so it is precisely the kind of remember-to-obey rule `PLAN-PLAIN.md:46-48` argues against.
2. The **six-section schema was never shipped**, so `RECON.md` has no fixed shape and the two real
   artifacts share none. The `## SLUG` rationale — the reviewability the change is largely justified
   by — is recorded nowhere.
3. **`## BUDGET SPENT` does not exist**, so the self-report-vs-transcript audit that
   `PLAN-PLAIN.md:120-121` designates as the reason the section exists **cannot be run at all**. I
   substituted a direct transcript audit; it found the p3 digest breach that no artifact would have
   disclosed.

Defects 2 and 3 are a divergence between `PLAN.md` W1 and what was committed, applied consistently
across both docs. Defect 1 is a live behavioural failure of the shipped rule. None of the three is
detectable by `test/plan-role-recon-proof.sh`, which greps for the budget *numbers* being present in
the prose, not for them being *obeyed*.
