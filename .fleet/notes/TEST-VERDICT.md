# TEST-VERDICT — zombie-reconcile fix (commit de13b6b)

**VERDICT: done** — fix proven, no real defects. **118/118 assertions pass**, all
three test files exit 0 and reproduce cleanly.

| Test file | Scope | Result |
|---|---|---|
| `test-layer1-2.sh` | Layer 1 terminal verb + Layer 2 teardown stickiness | **42/42** |
| `test-layer3-reconcile.sh` | Layer 3 reconcile respawn cap / generation guard | **52/52** |
| `test-adversary.sh` | break attempts (injection, set -u, owner-stamp, race) | **24/24** |

## Harness / isolation (critical, learned the hard way)

`fleet_root()` prefers the tmux `@fleet_root` option over the `$FLEET_ROOT` env
var, so a **naked `fleet dispatch …` run from inside the fleet tmux pane mutates
the REAL ledger** at `/home/red/proj/pc-tune/.fleet/dispatch`. (Discovered during
the initial smoke test — it wrote `state=done` into the live `d1`; restored to its
original 3 lines immediately.) All tests isolate with:

```
T=$(mktemp -d)                       # fresh per scenario, asserted under /tmp
FLEET_SESSION=__nope__ FLEET_ROOT="$T" "$FLEET_BIN" dispatch …
```

`FLEET_SESSION=__nope__` makes `session_name` return a non-existent session →
`tmux show -t __nope__ -v @fleet_root` is empty → the `$FLEET_ROOT` fallback wins →
`fleet_root == $T`. Unit-level scenarios instead `sed`-extract the real functions
(`meta_get/meta_set/meta_compact/cmd_reconcile`, `is_harness_cmd`,
`suborch_has_live_workers`, `is_suborch_name`, `card_meta_state`) and override the
tmux/spawn/liveness dependencies with stubs. Post-run check: real `d1` content
unchanged; no fixture/junk dirs leaked into the live project.

## Tester A — Layers 1+2 (42/42)

- **Layer 1 `cmd_dispatch_finish`:** all verbs map (`done`→done; `fail`/`failed`→
  failed; `cancel`/`cancelled`→cancelled), each prints `dispatch <id> → <st>` rc 0.
  Last-wins/idempotent (done→fail flips; done→done holds). Die-loud (rc≠0) on
  missing id and unknown dispatch dir (`no such dispatch`). Terminal state reads
  back equal — what reconcile's skip predicate honours.
- **Layer 2 stickiness (`confirm_teardown` guard):** a torn-down sub-orch already
  `done`/`failed`/`cancelled` keeps its state (cancel never fires); a
  `running`/no-state sub-orch is flipped to `cancelled`. `is_suborch_name` rejects
  normal window names, accepts slugged `so-d11-new-project`; `card_meta_state`
  strips the slug to `d11`.

## Tester B — Layer 3 reconcile cap (52/52)

Over-cap+responsive+no-worker → **failed + alert + no spawn**. Under-cap →
respawn (n+1). Cap reached but **live worker owned → re-animate, not fail** (the
false-positive guard). tmux unresponsive → **never mass-fail** (respawn instead).
Live sub-orch → untouched. Already-terminal → skipped. Cap boundary honoured for
`FLEET_RECONCILE_CAP=2`. Non-numeric/empty `respawns` coerced to 0. Multiple
dispatch dirs handled independently in one sweep.

## Adversary — break attempts (24/24, no defects)

- **Injection (A1):** CRLF/whitespace/padded/path-traversal ids all die-loud via
  the `[ -d "$d" ]` guard — **no junk dir fabricated, no traversal write**. A
  trailing-space verb (`'done '`) does not match the terminal case and falls
  through to the bare-spawn die — never silently mapped to `done`.
- **set -u (A3):** `suborch_has_live_workers` with zero panes → no unbound-variable
  abort (the deliberate split `local id=…; local owner="so-$id"` holds).
- **Owner-stamp (A4):** exact `[ "$o" = "$owner" ]` — `so-71` does **not** collide
  with id `7`; dead-shell/wrong-owner/empty-owner all correctly read non-live;
  idle-but-unfinished harness counts live (errs toward keeping pipeline alive).
- **Classifier (A5):** shells→dead, claude/node/nvim→live.

### Accepted-by-design footguns (documented, not defects)

1. **`FLEET_RECONCILE_CAP=0`** → `0>=0` true → abandons on the very first dead
   sweep with zero grace (still gated on tmux-responsive + no-live-worker, so it
   can't mass-fail). `CAP=""`→defaults to 1; `CAP="abc"`→`[: integer expected` on
   stderr, guard short-circuits, degrades to respawn (no crash, no `set -u` abort).
2. **Raw terminal verb is unconditional last-wins.** Stickiness lives ONLY at the
   dash `confirm_teardown` call site; a direct/racing `fleet dispatch cancel <id>`
   *can* downgrade a clean `done`→`cancelled`. `meta_set` is atomic-per-write
   (tmp+mv) but has no compare-and-swap, so a TOCTOU window exists between the
   dash's state read and its cancel write. Consistent with the commit's stated
   "last-wins/idempotent, operator-explicit" contract — flagged for awareness.

### Minor spec-wording note (not a defect)

The task described "die-loud on **bad verb** → usage". A truly unknown verb
(`fleet dispatch bogus d1`) is not caught by `cmd_dispatch_finish`'s verb `case`;
it falls through to the generic dispatch-id path and dies with
`no such dispatch bogus …`. Still rc≠0 and loud — just a different (generic-path)
error string than the finish-verb usage line.
