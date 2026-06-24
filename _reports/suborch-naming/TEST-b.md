# TEST-b — independent verification: d<N>-prefix sub-orch & worker naming

Independent tester (own context). **Did NOT trust PROOF.md** — re-derived every
claim against the REAL code by extracting verbatim function bodies and driving
real `bin/fleet` verbs against a throwaway tmux session `test-naming-b`.

> **Spec note:** the brief pointed at `_reports/suborch-naming/{PLAN.md,SYNTHESIS.md}`
> as the spec — **those files do not exist** (only `PROOF.md` is present; `git show`
> confirms the feature commit `81f6991` added only `PROOF.md`). Invariants were
> therefore derived from the commit message + the 7 mandated items + the code itself.

Method: pure-string logic exercised via functions extracted verbatim
(`bin/fleet:1653` `suborch_slug`, `bin/fleet-dash:205-213`, `group_rows`
`bin/fleet-dash:439-531`); tmux-dependent paths driven through real `bin/fleet`
with `FLEET_SESSION`/`FLEET_ROOT` overrides against dummy plain-shell windows with
hand-set `@fleet_owner` window options (no costly claude panes). `bash -n` clean on
both bins. Live `pc`/`techweb2` sessions never touched; `test-naming-b` torn down.

---

## ITEM 1 — CORE INVARIANT (must-fix #1): @fleet_owner stays bare after rename — **PASS**

Real `fleet dispatch rename d99 'New Project Create!!'` on a live window `so-d99`:
- window → `so-d99-new-project-create`; `meta window` → `so-d99-new-project-create`;
  ledger dir `d99` and `meta window_id` (`@122`) **unchanged**.
- **(c) NO re-stamp:** worker's `@fleet_owner` read back **`so-d99` (BARE)** after the
  rename. Code confirms: `cmd_dispatch_rename` (`bin/fleet:1460`) does only
  `tmux rename-window` + `meta_set window` — there is **no** `tmux set @fleet_owner`
  anywhere in the verb.
- **(a) GROUPING:** real `group_rows` with a worker `@fleet_owner=so-d99` (bare) and a
  live header `so-d99-new-project-create` → worker `ROW_GID=so-d99-new-project-create`,
  `role=1`, **annot empty**, `HAS_CARDS=1`. The bare→full `HDR_BY_ID` translation
  (`bin/fleet-dash:453,476`) resolves correctly. `card_meta_state('so-d99-new-project-create')`
  strips `-slug` → reads ledger `d99` state `running`.
- **(b) ROUTING:** real `fleet inbox route 'd99-myrepo/mybranch' 'so-d99'` →
  `dest=suborch submit=1 pane=%125`, and `%125` is the pane of window
  `so-d99-new-project-create` (verified pane→window map). The bare owner auto-submits
  back to the **renamed** sub-orch via `suborch_pane_for`'s prefix match
  (`bin/fleet:1047`).
- **d1-vs-d11 trailing-dash guard:** with `so-d1-real` + `so-d11-foo` live, owner `so-d1`
  → `so-d1-real` (`%129`), owner `so-d11` → `so-d11-foo` (`%130`) — **distinct panes, no
  leak**. The `"$owner"-*` (trailing dash) case in `suborch_pane_for` is load-bearing and
  proven.
- Dead/absent owner `so-d404` → `dest=main submit=0` (no spurious resolve).

## ITEM 2 — WORKER PREFIX derivation — **PASS**

Real `cmd_new` logic (`bin/fleet:861-864`): `so-d11`→`d11-…`, `so-d11-new-project`→`d11-…`,
`so-d7`→`d7-…`. The `${FLEET_SUBORCH_ID#so-}`+`%%-*` strip recovers `d<N>` whether or not
the env id carries a slug; `case d[0-9]*` gates it (a non-`d` id → no prefix, still owned —
graceful).

## ITEM 3 — the 4 dash tweaks — **PASS**

- **`is_suborch_name`** (`^so-d[0-9]+(-[A-Za-z0-9-]+)?$`): matches `so-d11`,
  `so-d11-new-project`, `so-d11-ipv6-fix`, `so-d404-x`; **rejects** worker
  `d11-myrepo/mybranch`, `so-foo`, and (bonus) `so-d11-` (bare trailing dash) and `so-`.
- **`suborch_ledger`/`card_meta_state` `%%-*` strip**: `so-d11`, `so-d11-new-project`,
  `so-d11-ipv6-fix` all recover dir `d11`.
- **GNUM**: `so-d11-ipv6-fix`→`11` (NOT `1116`), `so-d11-3d-render`→`11`, `so-d7`→`7`,
  `so-d11`→`11`. The digit-bearing slug does **not** slurp.

## ITEM 4 — SLUG SANITIZER — **PASS**

`suborch_slug`: `New Project Create`→`new-project-create`; `IPv6  Fix!!`→`ipv6-fix`;
`''`→`''`; `!!!@@@`→`''` (empty ⇒ rename no-op, stays bare); `3D Render Pipeline`→
`3d-render-pipeline` (digit-lead survives); 8-word input length-caps to
`one-two-three-four-five-six` (27 chars ≤28, partial trailing word dropped, no trailing
`-`); a single 36-char word with no dash hard-cuts to 28 chars. Output is `[a-z0-9-]`
only (safe to interpolate into `tmux rename-window`).

## ITEM 5 — GLOBS SURVIVE — **PASS**

`so-*` case-globs match **both** bare `so-d99` and slugged `so-d99-new-project-create`
(routing/anti-forgery branches `bin/fleet:2112,2125,1860`). `"$led"/d*/` ledger globs
(`gate_waiting` 1601, `cmd_reconcile` 1621, 2479) match dir keys `d11/d98/d99` — the slug
never touches the dir, so the immutable `d<N>` key is unaffected.

## ITEM 6 — NO-REGRESSION (un-renamed so-d<N>) — **PASS**

Un-renamed `so-d98`: worker `@fleet_owner=so-d98` groups under header `so-d98` (`role=1`,
no annot); `fleet inbox route 'd98-rep/br' 'so-d98'` → `dest=suborch submit=1 pane=%127`
(exact match, `so-d98`'s pane). `gate waiting` with no `meta window` set falls back to
bare `so-d98`. Orphan-owner case (`so-d404`, no live header, no ledger) → unowned +
`(owner so-d404 gone)` annotation — unchanged behaviour.

## ITEM 7 — RESTORE round-trip — **PASS**

Real `persist_agent` writes a 9-col line `…\twname\towner` (`d11-myrepo/mybranch` +
`so-d11`); a plain worker persists empty owner; a hand-injected legacy 7-col line reads
back with empty `wname`/`owner`. Real `cmd_restore`:
- matches by **persisted `wname`** (`matchname="${wname:-$repo/${branch//\//_}}"`):
  open `d11-myrepo/mybranch` → d11 worker skipped (no duplicate); legacy line falls back
  to reconstructed `legrepo/legbr` and skips when that name is open.
- **re-exports the bare owner**: captured `cmd_new` invocations show the d11 worker
  respawned with `FLEET_SUBORCH_ID=so-d11` (→ re-derives prefix + re-stamps owner), while
  plain/legacy workers get empty owner (no spurious stamp). The exact self-merge grant is
  preserved (`--self-merge`/`--no-self-merge` per persisted col 7).

---

## Adversarial note (not a blocker)

The **`from=so-*` gate-resume branch** (`inbox_route`, `bin/fleet:2125`) uses the EXACT
`window_pane_for`, **not** the prefix-tolerant `suborch_pane_for`. This is safe in the
documented pipeline because `from=` auto-derives the caller pane's **live** window name at
post time (`inbox_put` `bin/fleet:1879`), and `gate_post` passes no `--from` — so a gate
posted by an already-renamed sub-orch stamps `from=so-d99-new-project-create`, which
exact-matches. **Latent fragility:** a gate posted while still bare (`so-d99`) and popped
*after* a later rename would `window_pane_for('so-d99')`-miss and fall through to `main`.
§3.0.1a fixes rename to occur right after classify (before any gate), so this ordering is
not reachable in the documented flow — but the from= branch is the one resolver in the
feature that was left exact rather than prefix-tolerant, relying on an external invariant
(rename-before-gate) rather than being robust by construction.

The `cmd_reconcile`/`resolve_or_spawn_suborch` double-spawn guard (reads `meta window`
slugged, lock re-keyed on immutable `.spawnlock-$id`) was **code-reviewed only**, not
exercised end-to-end — `suborch_live` needs a real harness-alive check that would require
spawning a costly claude pane. The code path is consistent with the rest of the feature.

## Verdict

All 7 mandated items **PASS** with concrete cited evidence. Core must-fix #1 invariant
(@fleet_owner stays bare across rename; grouping + routing both bare-owner-tolerant) holds
end-to-end through the real functions. No regression on un-renamed sub-orchs.

**DONE.**

Single most important gap (non-blocking): the `from=so-*` gate-resume branch is the lone
resolver left exact rather than prefix-tolerant; it stays correct only by relying on the
external "rename-before-gate" ordering (§3.0.1a) instead of being robust by construction —
worth a one-line hardening (route it through `suborch_pane_for` too) to remove the latent
ordering dependency.
