# TEST-a — independent verification of `d<N>`-prefix sub-orch & worker naming

Independent tester (own context, own verdict). Fleet has no test runner, so every
check below **exercises the real shipped code**: functions are extracted from
`bin/fleet` / `bin/fleet-dash` by exact line-range (no hand-copy → no drift) and
sourced, or driven through real `bin/fleet` verbs against a **throwaway** tmux
session `test-naming-a` (the live `pc`/`techweb2` sessions were never touched;
no real claude panes were spawned — windows were plain `sleep` shells with the
`@fleet_*` options set by hand). PROOF.md was **not** trusted; results re-derived.

Spec note: the task named `_reports/suborch-naming/{PLAN.md,SYNTHESIS.md}` as the
spec, but **those files do not exist** — only `PROOF.md` is present in that dir.
Spec was therefore taken from the 7 invariants in the test brief + PROOF's claims
(used only as a checklist to refute, not as ground truth). Not a code defect, but
flagged: there is no independent PLAN/SYNTHESIS to cross-check intent against.

Test harnesses live in the session scratchpad (`mod.sh`, `unit.sh`, `ledger.sh`,
`group.sh`, `gnum.sh`, `restore.sh`, `persist.sh`).

---

## ITEM 1 — THE CORE INVARIANT (must-fix #1): bare `@fleet_owner` survives rename — **PASS**

`@fleet_owner` stays the bare `so-d<N>` even after the window is renamed to
`so-d<N>-<slug>`, and all three consumers still resolve.

**(a) Grouping (bare→full HDR_BY_ID map).** `group_rows` (real, `fleet-dash:439-529`)
driven with a renamed live header `so-d99-new-project` (ledger `d99`) and a worker
whose `@fleet_owner` is the **bare** `so-d99`:
```
row gid=so-d99-new-project role=1 :: d99-myrepo/mybranch   ← worker groups under RENAMED header
HAS_CARDS=1 ; orphan-annotations=0 ; CARD_STATE[so-d99-new-project]=running
```
The bare→full translation is `fleet-dash:453-454` (`HDR_BY_ID[so-d99]=so-d99-new-project`)
+ `:476-478` (worker's bare owner → `_ofull` → groups under full header). Verified PASS.

**(b) Inbox routing to the owner resolves to the renamed window (prefix-tolerant).**
Real `fleet inbox route` (→ `inbox_route` → `suborch_pane_for`, `fleet:1047-1056`)
in session `test-naming-a`:
```
before rename:  route d99-myrepo/mybranch so-d99  → dest=suborch submit=1 pane=%131
after  rename (window so-d99 → so-d99-myslug, same pane %131):
                route d99-myrepo/mybranch so-d99  → dest=suborch submit=1 pane=%131  ✓
```
The bare owner still auto-submits into the renamed sub-orch via the
`"$owner"|"$owner"-*` case (`fleet:1053`). PASS.

**(c) NO re-stamp.** After `tmux rename-window` (and after the **real**
`fleet dispatch rename d77 'IPv6 Fix!!'` verb), the worker's `@fleet_owner` reads
back **bare `so-d99` / `so-d77`** — unchanged. Code-confirmed: `cmd_dispatch_rename`
(`fleet:1460-1474`) contains **zero** `@fleet_owner` / `FLEET_SUBORCH_ID` mutation;
the only `tmux set … @fleet_owner` write in the whole file is `fleet:967` inside
`cmd_new`'s spawn path. PASS.

## ITEM 2 — Worker `d<N>-` prefix derivation — **PASS**

Real `cmd_new` lines `fleet:861-865` (`_did="${FLEET_SUBORCH_ID#so-}"; _did="${_did%%-*}"`):
| FLEET_SUBORCH_ID      | wname out          | _owner out            |
|-----------------------|--------------------|-----------------------|
| `so-d11`              | `d11-repo/branch`  | `so-d11`              |
| `so-d11-new-project`  | `d11-repo/branch`  | `so-d11-new-project`* |
| `so-d99-ipv6-fix`     | `d99-r/b`          | `so-d99-ipv6-fix`*    |
| `so-d7`               | `d7-r/b`           | `so-d7`               |
| sub-orch itself (FLEET_NEW_SUBORCH_ID set) | unprefixed | "" (no stamp) |

Prefix strips `so-` then cuts at first `-` → always recovers `d<N>` regardless of
slug. PASS. *(\*Note: `_owner` persisted is whatever `FLEET_SUBORCH_ID` held in env.
In the live spawn path that env value is the bare `so-d<N>` frozen at sub-orch
creation — `dispatch rename` never mutates pane env — so the persisted owner is bare.
The derivation itself is slug-tolerant either way.)*

## ITEM 3 — The 4 dash tweaks — **PASS**

- **`is_suborch_name`** (`fleet-dash:205`, `^so-d[0-9]+(-[A-Za-z0-9-]+)?$`): matches
  `so-d99`, `so-d99-myslug`, `so-d11-ipv6-fix`, `so-d1-real`; **rejects**
  `d11-myrepo/mybranch`, `so-foo`, `so-d`, `so-dxx`, `so-d11-bad/slash`, ``, `main`. PASS.
- **`suborch_ledger`** (`:208`) & **`card_meta_state`** (`:210-213`): both `${id%%-*}`
  strip the slug to recover `d<N>`. `so-d99-new-project` and bare `so-d99` both resolve
  to dir `d99` / `state=running`; `so-d11-ipv6-fix`→`d11`; `so-d404-x` misses. PASS.
- **GNUM** (`fleet-dash:492`, `num=${gid#so-}; num=${num%%-*}; num=${num#d}`): a
  digit-bearing slug does **not** slurp. `so-d11-ipv6-fix`→`11`, `so-d11-3d-render`→`11`
  (the old `//[^0-9]/` gives `113` — confirmed), `so-d100`→`100`. Sharp ordering check:
  `so-d11-3d-render`(11) sorts **before** `so-d100`(100); a slurp (113) would invert it.
  Driven through real `group_rows`: header order `so-d2` before `so-d11-3d-render`. PASS.

## ITEM 4 — Slug sanitizer (`suborch_slug`, `fleet:1653-1662`) — **PASS**

`'New Project Create'`→`new-project-create`; `'IPv6  Fix!!'`→`ipv6-fix`;
`''` & `'!!! @@@'`→`''` (empty → rename is a no-op, stays bare — verified live:
`rename d55 '!!! @@@'` → "empty slug — keeping so-d55", window unchanged);
7-word input length-caps to `one-two-three-four-five-six` (len 27 ≤ 28, partial
trailing word dropped, no trailing `-`); 28-char boundary passes unchanged;
digit-lead `'3D Render Pipeline'`→`3d-render-pipeline`. Output is `[a-z0-9-]` only. PASS.

## ITEM 5 — Globs survive — **PASS**

`so-d77-ipv6-fix` matches `so-*` (case). The ledger `d*/` glob lists
`d1 d11 d2 d7 d77 d99` (slugs never enter ledger dir names — dirs are bare `d<N>`).
A worker window `d77-r/b` is **not** a `so-*` target (no collision: it is a window
name, never a ledger dir). PASS.

## ITEM 6 — No-regression (un-renamed `so-d<N>`) — **PASS**

- Grouping: a worker owned by un-renamed `so-d11` groups under header `so-d11`
  (no-slug path), zero annotations.
- Routing: real `route x so-d98` → `dest=suborch submit=1 pane=%133` (exact match).
- `dispatch rename` with empty slug is a no-op (stays `so-d55`).
- **d1-vs-d11 trailing-dash guard** (load-bearing `-` in `"$owner"-*`): with only
  `so-d1-real` and `so-d11-foo` live, `route x so-d1` → `pane=%134` (so-d1-real),
  does **not** leak to `so-d11-foo` (`%135`). PASS. (Grouping is even safer here:
  `HDR_BY_ID` is an exact assoc-key lookup, so `so-d1` can never mis-key to `so-d11`.)

## ITEM 7 — Restore round-trip — **PASS**

Real `persist_agent` (`fleet:537-546`) writes a 9-col TSV line for a sub-orch-owned
worker: `…\td11-myrepo/mybranch\tso-d11` (cols 8=wname, 9=owner). The real
US-separated read loop (`cmd_restore`, `fleet:713-719`) parses it back:
`matchname="${wname:-…}"` = `d11-myrepo/mybranch` (the persisted prefixed name, so the
running window matches → no duplicate respawn), and `owner=so-d11` is non-empty →
the `FLEET_SUBORCH_ID="$owner" cmd_new …` branch fires (`fleet:731-732`) so the worker
comes back **prefixed AND owner-stamped**. A legacy 6/7-col line (no wname/owner) reads
back empty → falls back to reconstructed `legrepo/legbr` match, no owner re-export.
Backward-compatible. PASS.

---

## Cross-cutting

- `bash -n` clean on both `bin/fleet` and `bin/fleet-dash`.
- Live `pc`/`techweb2` sessions untouched; `test-naming-a` was the only session
  created and was killed on completion. No real claude panes spawned.

## Residual (accepted, documented — not a blocker)

`cmd_reap`'s needs-human skip-guard (`fleet:2620-2624`) catches a sub-orch-owned
worker by its **live** window name `wlive` (correctly prefixed `d<N>-…`) while the
window lives, but the **reconstructed** fallback `wrecon="${repo}/${branch//\//_}"`
is **unprefixed**. So a *dead* sub-orch-owned worker (window already gone) whose
unread needs-human `from=d<N>-repo/branch` sits in the inbox could slip the guard and
be reaped, orphaning that message. Severity **low** (requires dead worker + unread
needs-human + non-`--force` reap); `--force` overrides regardless. This is exactly
the residual PROOF.md §D documents — accurately characterized, not understated.

## Verdict

All 7 core invariants **PASS** under independent re-derivation against the real
code. The must-fix #1 invariant (bare owner survives rename; grouping + routing +
no re-stamp) is solid; the GNUM digit-slug slurp is genuinely fixed; restore and
the d1/d11 guard hold.

**DONE.**

Single most important gap: not a code bug but a **process gap** — the named spec
(`PLAN.md` / `SYNTHESIS.md`) is missing from the report dir, so intent could only be
cross-checked against the implementer's own PROOF + the test brief, never an
independent design doc. The one real code residual (reap `wrecon` unprefixed
fallback, low-severity, `--force`-overridable) is accepted and accurately documented.
