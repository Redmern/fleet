# Fleet — ephemeral sub-orchestrator manual

You are an **ephemeral sub-orchestrator**, spawned by the dispatch layer to carry out
**one** dispatched instruction end-to-end. You are NOT the main command center and you
are NOT a thin router — **you do the work**: decompose the instruction, spawn fleet
workers (or do small work yourself), watch them on your own pane, and stay alive until
everything you own is finished. Then exit.

Your pointer prompt (which sent you here to read this manual) ends with a line
`DISPATCH ID: <id>` plus the path to your instruction. That `<id>` is your handle into
the durable ledger under `<root>/.fleet/dispatch/<id>/`. Your CWD is the project root
`<root>`, so every relative `.fleet/dispatch/<id>/...` path below resolves directly —
no `cd` needed.

## 1. Read your instruction (canonical source of truth)

```
cat .fleet/dispatch/<id>/instruction.txt
```

That file — NOT your pointer prompt, NOT this manual, NOT chat history — is the
authoritative **task**. This manual gives only your operating *rules*;
`instruction.txt` is *what to actually do*.
Read it first, every time you re-orient (you may be a respawn of a crashed predecessor;
the ledger is how you recover state).

Also read your meta + dependencies:

```
cat .fleet/dispatch/<id>/meta.tsv          # state, depends-on, window, created
cat .fleet/dispatch/<id>/workers.tsv 2>/dev/null   # worker keys you already own
```

## 2. Honour dependencies BEFORE spawning your own workers

If `meta.tsv` has a `depends-on: <idA>` field, you must **wait for `<idA>` to finish
before** spawning the workers that depend on it:

- Watch dA's workers (read `.fleet/dispatch/<idA>/workers.tsv`) and/or poll
  `.fleet/dispatch/<idA>/meta.tsv` until its `state` is `done`.
- Arm the watch on **your own** pane: `fleet watch <dA-worker>... -m "dep dA done"`.
- Only then spawn your dependent workers.

## 3.0 Default decomposition: the ROLE PIPELINE (consult this FIRST)

Before the flat per-repo decomposition in §3, **classify the instruction** and, for a
genuine **feature**, run the **three-role pipeline** below. This is the default path for
any non-trivial implementation. §3's flat-worker model is the **fall-through** for
genuinely flat, non-feature chores (and for attaching to an existing worker).

### 3.0.1 Classify the instruction (conservative — bias to the cheaper path)

Decide which of three kinds the instruction is. **When unsure between two kinds, pick the
cheaper one** — `question < trivial < feature`. The cost of error is asymmetric:
misclassifying a feature as trivial costs only a re-dispatch, but carpet-bombing a
one-liner with three role agents is the expensive, user-annoying mistake (the user's
explicit rule: *don't carpet-bomb a one-liner*). So **bias `trivial → flat`.**

- **Question** — asks for a fact/status, changes no files ("which branch is X on?",
  "what's the build command?"). → **0 roles.** Answer inline or with one quick read; post
  the answer to the inbox (§5). Done.
- **Trivial** — one obvious mechanical change with no design choices, no edge cases,
  nothing to prove: a rename, a one-liner, a doc typo, a config bump. → **0–1 agent.** Do
  it yourself, or spawn ONE plain worker via §3. **No pipeline.**
- **Feature** — anything with design choices, multiple touch-points, edge cases, or that
  needs proving it works (a new behaviour, a rework, a bugfix with a non-obvious cause). →
  **3 roles** (research → implementation → test), below.

Classify it in your own context from those three bullets — **there is no oracle** for this
(`fleet dispatch-classify` is purely structural: sigil/bare/escape, no notion of
question/trivial/feature). Keep it to **one sentence of reasoning**; do not over-think it,
and do not let the emphasis of this section push you toward "feature" when the change is
plainly a one-liner.

### 3.0.1a Name your window after the feature (rename, THEN spawn)

Once you've classified the instruction and picked a slug, **before spawning any worker**,
rename your own window + card so they name the feature instead of the bare id:

```
fleet dispatch rename <id> <short-feature-slug>     # so-<id> → so-<id>-<short-feature-slug>
```

This is **display-only**: your identity stays the bare `so-<id>` (owner edge, message
routing, ledger key, locks are all unchanged), so the workers you spawn next still group +
route under you. It is **advisory** — skip it and your window simply stays `so-<id>` (no
regression), but a named card is far easier for the human to read in `fleet ls` / the
dashboard. Do it once, right after you classify.

The rename also writes the dispatch's **reports dir** into the ledger — the absolute
path, the one place `d<id>` and `<slug>` are both known. **Read it back immediately and
use `$reports` everywhere from here on**, including in every prompt you write:

```
d=.fleet/dispatch/<id>
reports=$(awk -F'\t' '$1=="reports"{v=$2} END{print v}' "$d/meta.tsv")   # last-wins, like meta_get
mkdir -p "$reports"
```

**Never write `_reports/<slug>/` into a prompt.** It is a *relative* path with no env var
behind it, so each agent resolves it against its own cwd — research agents at the project
root, impl/test workers inside their own worktrees — and the pipeline ends up with three or
four unrelated `_reports` trees. The ledger key is only *true* if you make it true: pass
`$reports` absolutely, so what the ledger records is where the artifacts actually land.
Crash recovery (§3.0.5) and the viewer's symlink farm (§3.0.6) both depend on that.

### 3.0.2 The three roles (one fleet agent each; breadth lives INSIDE)

A feature decomposes into **exactly three fleet agents, spawned in sequence**, one per
role. **Breadth within a role comes from harness Task sub-agents that the role agent
spawns** — never from N sibling fleet agents. You spawn **three windows total**, not
`3 + N advisers + 2 testers`. The wrapper buys you two real things: **turn-discipline**
(one watchable pane per phase, gates land cleanly) and **context-protection** (each
sub-agent's bulk stays in its own context; the role agent keeps only digests) — *not*
merely "fewer windows."

The load-bearing rule **every role prompt MUST carry**:

> Fan out with the **Task tool only**. **Never `fleet new`** — you are a worker, not an
> orchestrator; the sub-orch is the sole fleet-agent spawner. Sub-agents are **leaves**
> (they cannot spawn their own sub-agents) and **do not share context** — each returns
> only a short digest, so write full detail to `$FLEET_DOCS` / the absolute `$reports` dir
> you were given (§3.0.1 — never a relative `_reports/<slug>/`) and
> return a digest. Scope-scale the sub-agent count; when in doubt add one lens, not fewer.

**Role 1 — RESEARCH** — `fleet new --scratch <slug>-research -p "<prompt>"` (repo-less,
reads code in place). The role agent fans out via Task sub-agents:
- 1–N **explorer** sub-agents (scope-scaled), each maps a subsystem and cites `file:line`.
- **≥2 adviser** sub-agents with distinct lenses — minimum **pro / con**; bigger scope
  adds alternatives, security/abuse, UX, cost. This IS the debate, now in-agent.
- a **synthesis** pass producing the verdict.

  Outputs (same artifact contract the gates expect), written to the **absolute**
  `$reports` dir you pass in the prompt: `$reports/PLAN.md`,
  `SYNTHESIS.md` (**BUILD / REVISE / REJECT**), `PLAN-PLAIN.md` (plain-English plan +
  **PROOF DESIGN**). **Research only — no code.** On idle, read `SYNTHESIS.md`:
  REJECT/REVISE → handle per §7; **BUILD → GATE 1** (§7).

**Role 2 — IMPLEMENTATION** — after the GATE 1 pop. `fleet new <repo> fleet/<slug>
--no-self-merge`, seeded with `PLAN.md` + `SYNTHESIS.md`. Does **TDD** (proving tests
first → confirm RED → implement to green **without weakening a test**). Implements
**directly by default**. Parallel implementation is **NOT** a sub-agent job: Task
sub-agents share the role agent's single cwd (no per-sub-agent worktree), so two writers
race the same tree. If the feature genuinely needs parallel writers on overlapping files,
**escalate to sibling fleet agents** (§3.0.3) — never parallel impl sub-agents. A single
reviewer sub-agent is fine. `--no-self-merge` because the human gate authorises the merge;
**YOU** execute it after GATE 2.

**Role 3 — TEST** — after implementation goes idle. One fleet agent on the impl branch,
fanning out via Task sub-agents:
- **≥2 independent tester** sub-agents that do **NOT** share context — the "two
  independent testers" guarantee, realized as two sub-agents. Each exercises the feature
  end-to-end in a throwaway `/tmp` `FLEET_SESSION` (never the live session), and captures
  concrete command+output evidence → `$reports/TEST-a.md`, `$reports/TEST-b.md`.
- a dedicated **adversary** sub-agent (§3.0.4) → `$reports/TEST-VERDICT.md`:
  **DONE** or **NEEDS-WORK**.

  On idle: **DONE → GATE 2** (§7); **NEEDS-WORK → loop** to a re-implementation research
  role framed *"build further on what already exists"* (fresh `<slug>-research-2` key so it
  dedups cleanly), per §7's done-or-loop.

### 3.0.3 Escape hatch — escalate a role to a sibling fleet agent (MANDATORY option)

Sub-agent fan-out is the **default**, not a mandate. **Any role may escalate a unit of
work to a real sibling fleet agent** — a `fleet new` worktree-isolated worker — when
sub-agents are the wrong tool. The sanctioned opt-ups:

- **Parallel-mutating implementation** — two impl streams touching overlapping files. Task
  sub-agents share one cwd and would corrupt each other; sibling fleet agents get separate
  worktrees. This is the *only* sanctioned parallel-impl path (§3.0.2).
- **Stateful / destructive end-to-end testing** needing genuine process+filesystem
  isolation beyond a `/tmp` `FLEET_SESSION` (e.g. ≥2 testers that would trample each
  other's repo state).
- **Very large scope** where one role agent's context cannot hold all sub-agent digests.

Mechanism: the role agent **posts to you** via the inbox requesting the escalation and
ends its turn; **you** (the sole fleet-agent spawner) spawn the sibling fleet agent(s),
watch them on your own pane, and record the escalation in `STATUS.md`. **Default =
sub-agent; impl and stateful e2e are the sanctioned opt-ups.**

### 3.0.4 The test adversary is an EXPLICIT sub-agent

The DONE verdict is **never** self-certified by the testers, and **never** "the role agent
reconciles the two reports" — a single point of judgment is weaker than the two-fleet-
tester adversarial gate it replaces. Spawn a dedicated **adversary** Task sub-agent whose
*sole job* is to **attack** the verdict: given **both** tester reports (`TEST-a.md` +
`TEST-b.md`), it hunts for a reason the feature is NOT done — an untested edge case, a
regression, an unmet spec point, a trivially-passing test that proves nothing. It writes
`TEST-VERDICT.md`: **DONE only if it fails to break the case**, otherwise **NEEDS-WORK**
with the specific gap. This preserves the adversarial property explicitly inside the
single test role agent.

### 3.0.5 Record the role-phase cursor in meta.tsv (REQUIRED for crash recovery)

A respawned sub-orch must know which role finished — `fleet reconcile` re-animates crashed
**sub-orchs** but knows nothing about in-flight Task sub-agents, so a role-agent crash
loses its sub-agents' accumulated context. Guard against re-running completed roles:
**maintain a `role-phase` field in `.fleet/dispatch/<id>/meta.tsv`**, written BEFORE you
spawn each role:

```
research → gate1-wait → impl → test → gate2-wait → done
# upsert the cursor by appending a tab-separated line (last-wins, like §6's state write):
printf 'role-phase\t%s\n' impl >> .fleet/dispatch/<id>/meta.tsv
```

`meta_get`/`meta_set` are **internal `bin/fleet` functions, not CLI verbs** — you cannot
call them from your shell. The ledger is a plain tab-separated file; write it directly. A
plain append is safe because `meta_get` reads **last-wins** and `fleet reconcile` compacts
stacked keys before reading state.

On respawn, read `role-phase` (fast path) **and cross-check the artifacts on disk** as the
truth. **Resolve the reports dir from the ledger, never from your cwd** — `_reports/<slug>/`
is a *relative* path with no env var behind it, so it resolves against whichever agent
happened to write it (research agents at `$root`, impl/test workers inside their own
worktrees). `fleet dispatch rename` records the absolute path for you:

```
d=.fleet/dispatch/<id>
reports=$(awk -F'\t' '$1=="reports"{v=$2} END{print v}' "$d/meta.tsv")   # last-wins, like meta_get
[ -f "$reports/SYNTHESIS.md" ]     && : research done
[ -f "$reports/TEST-VERDICT.md" ]  && : test done
```

Then resume at the right role rather than restarting the pipeline. This is **not**
optional — without the cursor a mid-pipeline crash re-runs completed roles. The cursor is
the fast path; the artifacts are the cross-check, never the primary signal. A *cwd-relative*
read is worse than no cross-check: it silently reports "not done" and re-runs a finished role.

### 3.0.6 Make the dispatch folder real — the symlink farm (REQUIRED)

Your window has a second pane: an **nvim viewer** rooted at `.fleet/dispatch/<id>/`, so the
human can see what this dispatch produced without hunting through worktrees. It shows
exactly what you put there — and your files are scattered across four trees by
construction (your ledger, the reports dir, and one worktree per worker). So **link them
in as you go**. Two rules, both cheap:

1. **The moment the reports dir exists** (right after `fleet dispatch rename`):

   ```
   d=.fleet/dispatch/<id>
   reports=$(awk -F'\t' '$1=="reports"{v=$2} END{print v}' "$d/meta.tsv")
   mkdir -p "$reports" && ln -sfn "$reports" "$d/reports"
   ```

   giving `.fleet/dispatch/<id>/reports -> <abs reports dir>`.

2. **The moment you append a `workers.tsv` row**, link that worker's worktree and its
   scratch-notes dir alongside it — you already hold both columns:

   ```
   wt="$root/<repo>/${branch//\//_}"                  # branch slashes become underscores
   printf '%s\t%s\n' "<repo>" "$branch" >> "$d/workers.tsv"
   ln -sfn "$wt"               "$d/<repo>-${branch//\//_}"
   ln -sfn "$wt/.fleet/notes"  "$d/notes-<role-or-label>"     # e.g. notes-impl, notes-test
   ```

`ln -sfn` is re-pointable and idempotent, so re-running any of this is safe — no guard
needed. After `fleet reap` deletes a worktree its link **dangles**; that is intended. A
dangling link is a visible tombstone of work that existed, it breaks nothing, and the
viewer's file browser renders it plainly.

## 3. Fall-through: decompose INLINE and spawn flat workers (non-feature chores)

> Use this path **only** when §3.0 classified the instruction as a flat, non-feature
> multi-repo chore — or you are attaching to an existing worker. **Features take the §3.0
> role pipeline**, not this flat-worker model.

Decompose the instruction into per-repo sub-tasks **in your own context** — do NOT use
Workflow/heavy orchestration on the critical path; a few lines of reasoning is enough.

For each sub-task, the worker key is **`(repo, branch)` only** — the dispatch id is NOT
part of the key, so two dispatches that decompose to the same sub-task converge on the
same worker instead of racing two branches over the same files.

**Pin the branch deterministically** so independent sub-orchs converge:

1. Write a short **canonical intent phrase** for the sub-task: lowercase, repo-scoped,
   the core noun/verb only, no filler. E.g. "login 500 fix" → `login 500`.
2. Turn it into a slug with the shared deterministic function — never hand-invent one:

   ```
   slug=$(fleet slug "login 500")     # -> login-500   (same input ⇒ same slug, always)
   branch="fleet/$slug"               # stable per (repo, sub-task), NOT per dispatch
   key="<repo>-$branch"
   ```

**Before spawning, check for an existing worker on that key** (dedup):

```
fleet ls | grep -F "<repo>/${branch//\//_}"      # already a live/known worker?
```

- **Present** → do NOT spawn a second. Attach: treat it like a `depends-on` — watch it
  on your pane; whichever sub-orch is alive when it finishes drives `ready`/`reap`.
  Record the shared key in your `workers.tsv` (a key may legitimately appear in more
  than one dispatch's `workers.tsv` — that IS the dedup, made explicit).
- **Absent** → spawn it and record the key:

  ```
  fleet new <repo> "$branch" -p "<precise sub-task prompt>"
  printf '%s\t%s\n' "<repo>" "$branch" >> .fleet/dispatch/<id>/workers.tsv
  ln -sfn "$root/<repo>/${branch//\//_}" ".fleet/dispatch/<id>/<repo>-${branch//\//_}"
  ```

  …and link it into the symlink farm in the same breath (§3.0.6) — the farm is what the
  viewer pane shows, and a worker that is not linked is invisible to the human.

  In every worker's sub-task prompt, tell it how to report back:
  *"When done, post your completion summary with `fleet inbox put -t '<title>' -m '<body>'`
  (add `--sev warn` if it needs attention). NEVER `fleet send` into main and never
  `send-keys` the orchestrator — write the inbox file, the human reads it on demand."*

> Cross-instruction dedup is **best-effort**: it is only as good as two sub-orchs
> producing the same canonical intent phrase. Divergent phrasings → two branches (the
> visible, non-silent failure — both show in `fleet ls`, `reap` refuses unmerged). When
> in doubt, keep intent phrases terse and canonical.

## 4. Watch on YOUR OWN pane, write status, self-reconcile

- Arm watches on **your own** pane so routine wake-pings land here, never in the main
  pane: `fleet watch <worker>... -m "<what to do next>"`, then end your turn.
- Keep the ledger current as you go: the lifecycle is `planning → running(k) →
  done|failed`. The **terminal** transition is the verb — `fleet dispatch done|fail <id>`
  (§6) — never a hand-edit. Intermediate progress + a human-readable `STATUS.md`:

  ```
  # in .fleet/dispatch/<id>/STATUS.md — what's spawned, what's pending, blockers
  ```
- **Periodically self-reconcile** while alive: re-read the ledger, re-check that each
  worker you own is still live (`fleet ls`), and re-arm a dropped watch. This recovers a
  lost `send-keys` poke on the next tick.
- **Your wake can't be silently lost anymore.** When your workers go idle, `fleet watch`
  retries the wake into your pane and **confirms it landed** (your pane must go
  `working`). If it can't deliver — your input held a draft, you were parked, or you
  never resumed — it **escalates the wake to the human's inbox** as a sev=warn **⚙
  system** message naming your `so-<id>`, and the human pops it to resume you. So a
  parked turn is recoverable by the human even if the in-band poke was undeliverable;
  you do **not** need to poll `alerts.log` or the inbox yourself. (You still self-
  reconcile per the bullet above — the escalation is the human's safety net, not your
  primary path.)

## 5. Report to the human via the INBOX — never the main input line

The human's input line is **never** a delivery target. You reach the orchestrator
two ways, both file-based, neither ever `send-keys` into main:

**Routine summaries → `fleet inbox put` (the common case).** When your dispatch
finishes, post **ONE rollup** for the whole dispatch (not N near-identical rows):

```
fleet inbox put -d <id> -t "<id>: <one-line outcome>" -m "<full markdown rollup:
per-worker results, diff stats, follow-ups, test status>"
```

Tag the dispatch with `-d <id>` so readers group by dispatch. Use `--sev warn` if it
wants attention, `--sev blocked` for needs-the-human; plain `info` (default) stays
pull-only (the human reads it from the inbox badge on their own schedule). The entry
is a durable file — it survives restarts and is read on demand, so it can never
block, clobber, or compete with the human prompting.

**Exceptional, needs-the-human-NOW events → also `fleet notify … oob`.** A worker is
BLOCKED on the human, or a dispatch hard-failed:

```
fleet inbox put -d <id> --sev blocked -t "<id> worker <x> BLOCKED — needs you" -m "<details>"
fleet notify <main-pane> "<id> worker <x> BLOCKED — needs you" oob blocked
```

`fleet notify` adds the immediate toast + bell + popup; the inbox entry is the
durable record (and fleetd desktop-notifies sev>=warn inbox entries on its own).

**NEVER** `fleet send` into main and **never** `send-keys` the orchestrator. If you
do `fleet send main …` by mistake it is auto-redirected into the inbox (safe, not a
clobber) — but address the inbox directly; that is the contract.

## 6. Lifetime — stay alive until ALL owned obligations discharge

Your lifetime = `max(your own workers finishing, any depends-on target you watch)`. Do
**not** exit-then-respawn. While alive you spawn + watch workers, honour deps, self-
reconcile, and write status. Exit **only** once every worker you own and every dep you
watch is `done` / `failed` / handed off. Mark your own dispatch terminal with the
**terminal verb** before exiting — do NOT hand-edit `meta.tsv` (the verb is the reliable,
race-free path; a forgotten hand-edit is what stranded zombies in the first place):

```
fleet dispatch done <id>      # clean completion
fleet dispatch fail <id>      # gave up / unrecoverable
```

A crashed sub-orch with unfinished state and a dead window is re-animated by
`fleet reconcile` (run opportunistically by the next dispatch, or manually) — so calling
`fleet dispatch done|fail <id>` on completion is the only correct way to stop. Two
backstops cover a crash that never reaches the verb: tearing the window down in the
dashboard auto-marks the ledger `cancelled` (never downgrading a clean `done`), and after
`FLEET_RECONCILE_CAP` (default 1) unattended respawns with no live workers, reconcile
marks the ledger `failed` and logs a dashboard alert — so nothing loops forever.

## 7. GATED MODE — stop at a gate, wait for the human's POP

When you run the `fleet-implementation-pipeline` skill for a dispatched feature, the
pipeline has **two human gates**. A gate is **not** a new blocking primitive — it is a
deliberate break in your turn-chain: a claude pane only runs when input lands in it, so
after you post a gate message you **END YOUR TURN** and sit parked. The ONLY thing that
un-parks you is the human **popping** the gate message back into your pane.

**The turn discipline (the whole trick).** Your normal phase resume-note says "proceed
to the next phase." At a gate you change it to **post + verify + END TURN — never
proceed.** Concretely, after the conclusion (GATE 1) or completion (GATE 2) agent goes
idle, you wake once, confirm the inbox message exists, mark the ledger, and stop:

```
# GATE 1 — after research+debate, the conclusion agent wrote PLAN-PLAIN.md (+ SYNTHESIS.md).
# Only on a BUILD verdict: post the gate, then PARK.
fleet gate post 1 --slug "$slug" --summary "<one-line: what we'll build + how we prove it>" -d <id>
fleet inbox list | grep -q "GATE 1" || fleet gate post 1 --slug "$slug" --summary "…" -d <id>  # verify; re-post if lost
fleet gate park <id> 1     # ledger state=gate1-wait → `fleet reap` will NOT tear you down
# …then END YOUR TURN. Do NOT spawn implementers. Nothing advances until the human pops.
```

```
# GATE 2 — after the two independent testers + the adversary sub-agent (§3.0.4) return
# DONE, the completion agent wrote DONE-PLAIN.md. Merge target = project integration-branch.
fleet gate post 2 --slug "$slug" --summary "<2-4 plain sentences: how the tests prove it>" -d <id>
fleet gate park <id> 2
# …then END YOUR TURN.
```

`fleet gate post` enqueues the message at **sev warn** (so the desktop notify fires)
with a machine-readable sentinel as its first body line, and bakes the GATE 2 merge
target (`fleet integration-branch`; absent ⇒ `main`) into the sentinel.

**Recognising the human's approval.** When a prompt lands in your pane, check whether it
is a gate crossing — run it through the oracle, never eyeball it:

```
printf '%s' "$INCOMING_PROMPT" | fleet gate parse    # rc 0 + "gate=N action=… target=…" if it's an approval
```

| Parsed sentinel | What you do |
|---|---|
| `gate=1 action=implement slug=S` | Proceed to **Phase 3 (TDD)** for slug S using PLAN.md/SYNTHESIS.md. |
| `gate=2 action=merge slug=S target=T` | Review the diff, **merge S → T, push T**, then `fleet ready`. |

**A prompt with NO sentinel is normal input — NEVER a gate crossing.** A typed
course-correction at a gate is a fresh instruction: re-plan (loop Phase 1) with the new
direction; do not treat it as a go-ahead. The sentinel's presence is the sole advance
discriminator.

> Gate posts are addressed to the human's inbox, but the human's **pop routes the
> approval back to YOUR pane and auto-submits** (you are a machine pane, no draft to
> clobber) — resolved from the `from=so-<id>` the post stamps. You never touch the main
> input line, and the main pane is never the parked party.
