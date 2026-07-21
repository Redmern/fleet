# EXPLORE-B — dispatch / sub-orchestrator lifecycle map (d25)

All citations `bin/fleet:<line>` unless marked `bin/fleet-dash`. Repo:
`/home/red/proj/pc-tune/fleet/main` (bin/fleet 5091 lines, bin/fleet-dash 1876).

---

## 1. `resolve_or_spawn_suborch` (bin/fleet:1631–1672)

Entry point is `cmd_dispatch` (bin/fleet:1766–1787):

```
1782:  wname="so-$id"                                    # one sub-orch per instruction
1783:  resolve_or_spawn_suborch "$sess" "$wname" "$id" "$root"
1784:  meta_set "$led" window "$wname"
1785:  meta_set "$led" state planning
```

So the **window name is always `so-<id>`** (`so-d7`, …), later possibly renamed to
`so-d7-<slug>` by `fleet dispatch rename` (display-only; see §3).

Full body (bin/fleet:1635–1672):

```
resolve_or_spawn_suborch() { # <sess> <wname> <id> <root>
  local sess="$1" wname="$2" id="$3" root="$4" led="$root/.fleet/dispatch"
  local d="$led/$id"
  acquire_lock "$led/.spawnlock-$id" || return 1        # lock on IMMUTABLE id, not name
  if suborch_live "$d" "$sess" "$wname"; then
    :                                                   # idempotent no-op
  else
    local widf="$led/.wid-$wname.$$"
    rm -f "$widf" 2>/dev/null
    FLEET_NEW_WID_FILE="$widf" FLEET_SESSION="$sess" FLEET_ROOT="$root" \
    FLEET_NEW_SUBORCH_ID="$wname" \
      cmd_new --scratch "$wname" -p "You are a fleet dispatch sub-orchestrator (so-$id). Your project root is your CWD ($root).
FIRST, read and follow your operating manual: $FLEET_DIR/FLEET_SUBORCH.md
THEN handle DISPATCH ID: $id — read your instruction at .fleet/dispatch/$id/instruction.txt"
    local wid; wid=$(cat "$widf" 2>/dev/null); rm -f "$widf" 2>/dev/null
    [ -n "$wid" ] && meta_set "$d" window_id "$wid"
  fi
  release_lock "$led/.spawnlock-$id"
}
```

### Env it sets (command-scoped prefix, NOT exported)

| var | purpose |
|---|---|
| `FLEET_NEW_WID_FILE` | temp file cmd_new writes the new `window_id` into (bin/fleet:1194) → pinned into ledger `meta window_id` |
| `FLEET_SESSION` / `FLEET_ROOT` | session + project root for the spawn |
| `FLEET_NEW_SUBORCH_ID="$wname"` | marks *this* spawn as the sub-orch **itself** (not an owned worker) |

Comment at bin/fleet:1666–1668 is load-bearing: the `FLEET_*=…` line-continuations must
flow **straight into `cmd_new`** with no intervening comment, or they degrade from a
command-scoped prefix into leaked un-exported globals (fragile inside
`cmd_reconcile`'s per-dispatch loop). This was the fix in `630a43a`
("refactor(dispatch): scope sub-orch spawn env-prefix (no leak)").

### The pointer-seed bugfix (commit `ae61c81`, real fix `c4376dd`)

`ae61c81` = merge "compact pointer seed for sub-orch dispatch + loud spawn failures"
(2026-06-25). Content commit is `c4376dd` "fix(dispatch): compact pointer seed for
sub-orch + loud empty-win_id". Root cause per its message:

> The ~20KB FLEET_SUBORCH.md seed was inlined as a positional claude arg in one tmux
> new-window/new-session command, exceeding tmux MAX_IMSGSIZE (16384): "command too
> long" (rc=1), swallowed by `2>/dev/null` -> empty win_id -> no pane -> reconcile
> respawn loop.

Three changes:
1. deleted `suborch_seed() { cat "$FLEET_DIR/FLEET_SUBORCH.md"; }`; replaced
   `-p "$(suborch_seed)\nDISPATCH ID: $id"` with the ~200B imperative pointer above.
2. `cmd_new`: **loud failure on empty win_id** (bin/fleet:1178–1189) —
   `echo "fleet new: spawn FAILED for '$wname' — tmux returned no window id (over-cap
   seed prompt? look for 'command too long'). NOT spawned." >&2; return 1`, fail-silent
   retained only for genuinely-absent tmux (`return 0`).
3. reworded `FLEET_SUBORCH.md:9,:18` for the pointer model.

`$FLEET_DIR` is defined at bin/fleet:10 (`readlink -f $0/..`), so the pointer path
survives the `/usr/bin/fleet` symlink layout (note at bin/fleet:4719).

### What `cmd_new --scratch` does with it (bin/fleet:962–1240)

- `--scratch` (bin/fleet:968) → `scratch=1`; at bin/fleet:994–1004 scratch **forces
  `bare=1`**, `dir="$root"`, `wname=$(scratch_wname "$sess" "$repo")` (the first
  positional `so-<id>` is just a label), `docs="$root/.fleet/notes/scratch/<label>"`.
  **A sub-orch is therefore always a BARE pane running the harness directly — never
  the nvim layout.**
- Spawn env args (bin/fleet:1129–1130):
  ```
  local _eargs=(-e FLEET_ROLE=worker -e FLEET_DOCS="$docs" -e FLEET_SELF_MERGE="$self_merge")
  [ -n "${FLEET_NEW_SUBORCH_ID:-}" ] && _eargs+=(-e FLEET_SUBORCH_ID="$FLEET_NEW_SUBORCH_ID")
  ```
  `FLEET_ROLE=worker` is the fork-bomb gate (the sub-orch's own seed prompt can never
  re-enter the dispatch hook). `FLEET_SUBORCH_ID=so-<id>` is frozen into the new pane's
  **environment** — this is the whole owner mechanism (§3).
- The window is created in the **detached parking session `<sess>_hidden`**
  (bin/fleet:1131–1148), with a TOCTOU-tolerant `new-window`/`new-session` double
  fallback in both directions. `@fleet_root` mirrored onto the hidden session
  (bin/fleet:1153).
- Post-spawn stamps: `@fleet_harness` (1190), wid handback to `FLEET_NEW_WID_FILE`
  (1194), owner stamp gate (1204–1209), `@fleet_state_src` / `@fleet_busy_re`
  (1212–1213), `@fleet_hidden 1` (1223).
- **Scratch agents are not persisted**: bin/fleet:1238
  `[ "$scratch" = 1 ] || persist_agent ...` — so a sub-orch never appears in the saved
  agents file, which is why `cmd_reap` never sees it (§5).

---

## 2. `suborch_live` (bin/fleet:1601–1611) and `is_harness_cmd` (bin/fleet:1590–1594)

```
1592: is_harness_cmd() { # <pane_current_command>
1593:   case "$1" in claude|node|*claude*|nvim) return 0 ;; *) return 1 ;; esac
1594: }
```

```
1601: suborch_live() { # <dispatch-dir> <sess> <wname>
1602:   local d="$1" sess="$2" wname="$3" wid pane cmd
1603:   wid=$(meta_get "$d" window_id)
1604:   [ -n "$wid" ] || wid=$(suborch_find_wid "$sess" "$wname")
1605:   [ -n "$wid" ] || return 1
1606:   pane=$(tmux list-panes -t "$wid" -F '#{pane_id} #{pane_current_command}' \
1607:          2>/dev/null | head -1) || return 1
1608:   [ -n "$pane" ] || return 1
1609:   cmd=${pane#* }
1610:   is_harness_cmd "$cmd"
1611: }
```

Liveness probe = **tmux `#{pane_current_command}` of the FIRST pane of the recorded
window**, matched against the `is_harness_cmd` allowlist. No `pgrep`, no process-tree
walk, no `pane_pid`.

Resolution order: ledger `meta window_id` first (session-independent — required,
because a scratch sub-orch lives in `<sess>_hidden` and `"$sess:$wname"` can never
find it → false-dead → respawn loop), falling back to
`suborch_find_wid` (bin/fleet:1580–1588) which name-searches **both** `$sess` and
`${sess}_hidden`.

`suborch_has_live_workers` (bin/fleet:1619–1631) shares the same predicate:
```
1627:  done < <(tmux list-panes -t "=$s" -F '#{@fleet_owner} #{pane_current_command}' 2>/dev/null)
```

### If the pane's top-level command were `nvim`

**`nvim` is already in the allowlist** (bin/fleet:1593) — present since the original
dispatch-layer commit `6529107`. Consequences:

- **No false-dead.** An nvim-topped pane reads as LIVE, so reconcile
  (bin/fleet:1991) will not respawn it, and `suborch_has_live_workers` counts it.
- **But it is a FALSE-POSITIVE surface.** `is_harness_cmd` cannot distinguish
  "nvim hosting a claudecode.nvim harness terminal" from "a bare nvim with no agent
  in it" (or an nvim the user opened after the harness exited). A sub-orch whose
  harness died but whose nvim survives is *permanently* "live" ⇒ reconcile never
  re-animates it, the ledger never reaches a terminal state, and the pipeline stalls
  silently rather than being restored. The Layer-3 respawn cap
  (bin/fleet:1996–2010) is never reached because the `! suborch_live` branch is never
  entered.
- The probe only inspects `head -1` of `list-panes` — i.e. **pane index 0 only**.
  In an nvim-layout window the harness may not be in pane 0; and in a split window
  the first pane is whatever tmux enumerates first. Today's sub-orchs are always
  `--scratch` ⇒ `bare=1` ⇒ exactly one pane, so this is latent, not live.
- `node` and `*claude*` in the same list mean any stray node process (a dev server,
  an LSP) in the foreground also reads as "harness alive".

---

## 3. Owner edge: `@fleet_owner`, `record_pane_role`, `suborch_pane_for`

### Where `FLEET_SUBORCH_ID` is PRODUCED
Only one place: `cmd_new`'s scratch branch, bin/fleet:1130
`_eargs+=(-e FLEET_SUBORCH_ID="$FLEET_NEW_SUBORCH_ID")` — i.e. **only** when
`resolve_or_spawn_suborch` set `FLEET_NEW_SUBORCH_ID` (bin/fleet:1663). It is a tmux
`-e` pane environment var, frozen at spawn; `dispatch rename` never mutates it
(comment bin/fleet:1816).

### Where it is CONSUMED
1. **Worker window-name prefix + owner var** — bin/fleet:1084–1090:
   ```
   1084: if [ -n "${FLEET_SUBORCH_ID:-}" ] && [ -z "${FLEET_NEW_SUBORCH_ID:-}" ]; then
   1085:   _owner="$FLEET_SUBORCH_ID"
   1086:   local _did="${FLEET_SUBORCH_ID#so-}"; _did="${_did%%-*}"   # so-d11[-slug] -> d11
   1087:   case "$_did" in d[0-9]*) wname="$_did-$wname" ;; esac      # d11-<repo>/<branchdir>
   ```
   The double gate (`SUBORCH_ID` set AND `NEW_SUBORCH_ID` unset) is what excludes the
   sub-orch from owning itself.
2. **The `@fleet_owner` stamp + role registry** — bin/fleet:1204–1209:
   ```
   1203: local _wpane; _wpane=$(tmux list-panes -t "$win_id" -F '#{pane_id}' 2>/dev/null | head -1)
   1204: if [ -n "${FLEET_SUBORCH_ID:-}" ] && [ -z "${FLEET_NEW_SUBORCH_ID:-}" ]; then
   1205:   tmux set -w -t "$win_id" @fleet_owner "$FLEET_SUBORCH_ID" 2>/dev/null || true
   1206:   record_pane_role "$root" "$_wpane" "worker:$FLEET_SUBORCH_ID"
   1207: else
   1208:   record_pane_role "$root" "$_wpane" worker
   1209: fi
   ```
   Note `@fleet_owner` is a **window** option (`set -w`), while the role registry is a
   **pane**-keyed file. `_wpane` is again `head -1` of `list-panes` — **pane 0 only**.
3. **`cmd_watch`** — bin/fleet:1440 `local soid="${FLEET_SUBORCH_ID:-}"`, passed as a
   positional to the detached `watch-run` (bin/fleet:1442–1445); `cmd_watch_run`
   resolves argv → env → `so-*` window-name fallback (bin/fleet:1450–1458), and uses it
   for `suborch_ledger_active` / `wake_escalate` on pane death (bin/fleet:1466–1469).
4. **`cmd_restore`** — bin/fleet:761–765: re-exports the *persisted* bare owner so a
   restored worker re-derives the `d<N>-` prefix and gets re-stamped:
   `FLEET_SUBORCH_ID="$owner" cmd_new "${args[@]}"`.

### `record_pane_role` (bin/fleet:1569–1574)
```
record_pane_role() { # <root> <pane_id> <role>
  [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 0
  mkdir -p "$1/.fleet/roles" 2>/dev/null || return 0
  printf '%s\n' "$3" > "$1/.fleet/roles/$2" 2>/dev/null || true
}
```
Durable `<root>/.fleet/roles/<pane_id>` = `main` | `worker` | `worker:so-<id>`.
Read by `is_main_pane` (bin/fleet:163–171, authoritative over the window name) and by
the dispatch hook's env gate. Other writers: bin/fleet:3660 and bin/fleet:4455
(both stamp `main` on the command-center window's **first** pane).

### Reading the edge back: `@fleet_owner` consumers
- `inbox_put` (bin/fleet:2402–2408):
  ```
  2408: [ -n "${TMUX_PANE:-}" ] && owner=$(tmux show -wqv -t "$TMUX_PANE" @fleet_owner 2>/dev/null)
  ```
  Non-forgeable (window option set at spawn, not a message field).
- Inbox routing back to the owner (bin/fleet:2634–2650): resolves the owner name to a
  live pane via `suborch_pane_for "$owner"`.
- `suborch_has_live_workers` (bin/fleet:1627).

### `suborch_pane_for` (bin/fleet:1285–1296)
```
suborch_pane_for() { # <owner-bare-name> -> pane_id, or rc 1
  local owner="${1:-}" sess s w pane
  [ -n "$owner" ] || return 1
  sess=$(session_name 2>/dev/null) || return 1; [ -n "$sess" ] || return 1
  while IFS=$'\t' read -r s w pane; do
    { [ "$s" = "$sess" ] || [ "$s" = "${sess}_hidden" ]; } || continue
    case "$w" in "$owner"|"$owner"-*) printf '%s' "$pane"; return 0 ;; esac
  done < <(tmux list-panes -a -F $'#{session_name}\t#{window_name}\t#{pane_id}' 2>/dev/null)
  return 1
}
```
Prefix-tolerant (`so-d1` matches `so-d1-<slug>`; the trailing dash stops `so-d1`
matching `so-d11`). Hidden-session-aware. Contrast the exact-match
`window_pane_for` (bin/fleet:1269–1279).

**Layout assumption:** it returns the FIRST matching row from `list-panes -a`. For a
multi-pane sub-orch window (e.g. an nvim layout) the pane returned is whichever tmux
lists first — not necessarily the pane running the harness, so a gate-pop `send-keys`
could land in the editor pane. Today only bare panes are spawned, so this is latent.

---

## 4. Gate parking

"Parking" is **two orthogonal things** that share the word:

### (a) Ledger gate-parking (the pipeline sense)
`gate_park` (bin/fleet:1945–1954) — the sub-orch calls it right after posting and
verifying its gate message, then ends its turn:
```
1945: gate_park() { # park <dispatch-id> <1|2>
1951:   meta_set "$d" state "gate${gate}-wait"
1953:   echo "parked $id at gate${gate}-wait"
```
`gate_waiting` (bin/fleet:1958–1970) lists the **live window names** of parked
sub-orchs (`meta window` if the dispatch was renamed, else bare `so-$id`) for the
reap-skip set. Dispatched from `cmd_gate` (bin/fleet:1874–1876).

Effects of `gate{1,2}-wait`:
- `cmd_reconcile` (bin/fleet:1988) still treats it as **non-terminal** (only
  `done|failed|cancelled` are skipped at bin/fleet:1987), so a parked sub-orch whose
  pane died IS respawned. (This is the known "parked sub-orch revival" behaviour.)
- `cmd_reap` gate-wait guard, bin/fleet:3177–3179 (see §5).
- Terminal states are written by `cmd_dispatch_finish` (`done|fail|cancel`,
  bin/fleet:1797+), also invoked automatically by the dashboard teardown.

### (b) Physical window parking (the hidden-session sense)
The sub-orch's window physically lives in the **detached session `<sess>_hidden`**
from birth (bin/fleet:1131–1148) — it is never in the visible session's window bar and
is unreachable by `next-window`/`prev-window` (tmux has no per-window skip flag, so the
window must live outside the session; comment bin/fleet:1136–1142).

Functions moving windows in/out:
- IN (spawn): `cmd_new` scratch branch, bin/fleet:1140/1145 `new-window -t "=$hidden"`
  / `new-session -s "$hidden"`; marker `tmux set -w @fleet_hidden 1` (bin/fleet:1223).
- OUT on `--switch`: bin/fleet:1231–1233 `move-window -s "$win_id" -t "$sess:"` +
  `@fleet_hidden 0`.
- `ensure_hidden_session` (bin/fleet:3477–3486): tmux cannot create an empty session,
  so it spins a throwaway `_hold` placeholder window (`sh`), mirrors `@fleet_root`, and
  echoes the placeholder window id for the caller to kill **after** its move-window.
  LOAD-BEARING: caller must guard the kill on a non-empty id (an empty
  `kill-window -t ""` falls through to the current window).
- `cmd_hide` (bin/fleet:3508–3535): resolves among VISIBLE agents only, hard-refuses
  `main` by name AND `is_main_pane`, `move-window -s "$win" -t "=${sess}_hidden:"`,
  sets `@fleet_hidden 2` (2 = USER-hidden, still alerts on block), then
  `[ -n "$ph" ] && safe_kill_window "$ph"`.
- `cmd_unhide` (bin/fleet:3537–3552): searches both sessions,
  `move-window -s "$win" -t "$sess:"`, `@fleet_hidden 0`, `select-window`.
- Dashboard Enter / `h` — §6.

`@fleet_hidden` values: `0` surfaced, `1` spawn-parked scratch, `2` user-hidden.
fleetd suppresses notifications while parked (comment bin/fleet:1216–1222).
Session teardown kills both `$sess` and `${sess}_hidden` (bin/fleet:3838);
`cmd_sessions` excludes `*_hidden` (bin/fleet:3865).

---

## 5. Teardown: `cmd_reap` and `safe_kill_window`

### `safe_kill_window` (bin/fleet:186–202) — the single brake
```
186: safe_kill_window() { # <window-id-or-target>
187:   local win="${1:-}"
188:   [ -n "$win" ] || return 1                       # never kill the empty/current-window target
189:   local p
190:   while IFS= read -r p; do
191:     [ -n "$p" ] && is_main_pane "$p" && return 1   # main brake
192:   done < <(tmux list-panes -t "$win" -F '#{pane_id}' 2>/dev/null)
193:   local wsess cnt
194:   wsess=$(tmux display -p -t "$win" '#{session_name}' 2>/dev/null)
195:   if [ -n "$wsess" ]; then
196:     cnt=$(tmux list-windows -t "$wsess" -F x 2>/dev/null | grep -c x)
197:     [ "${cnt:-0}" -le 1 ] && return 1              # last-window brake
198:   fi
199:   tmux kill-window -t "$win" 2>/dev/null
200: }
```
Refuses: empty target; any window with an `is_main_pane` pane; the session's last
window. Fail-silent default is **refuse** (inverse of fleet's usual `|| true`).
Exposed as the internal verb `fleet safe-kill-window` (bin/fleet:5063) so fleet-dash
routes every kill through it.

**Pane assumptions:** it iterates **ALL** panes of the window (line 190–192) — this is
the one place in the codebase that does not do `head -1`. So a multi-pane window is
handled correctly, and a window containing the orchestrator pane in *any* position is
refused. `is_main_pane` itself uses window-name fast-path + role registry, not command.

**Last-window brake interaction with `<sess>_hidden`:** killing the only remaining
window in the hidden session is refused → an orphan sub-orch window can linger in
`<sess>_hidden` after teardown. Conversely `cmd_hide`'s `_hold` placeholder exists
precisely because tmux destroys a session when its last window dies.

### `cmd_reap` (bin/fleet:3095–3300)
Iterates the **persisted agents file** (`agents_file "$sess"`, bin/fleet:3102–3109),
skipping anything without `.fleet/ready` (bin/fleet:3115). Guards in order: target
label match, dir-gone → `cmd_forget`, not-a-linked-worktree, dirty tree,
unresolvable/unmerged base, unread needs-human inbox message, gate-wait, worktree lock.
Then archive notes → delete fleet-owned untracked markers → `git worktree remove` →
`safe_kill_window "$win"` (bin/fleet:3267) → `cmd_forget "$dir"`.

Window resolution (bin/fleet:3190–3195):
```
    while IFS=$'\t' read -r _rp _rpath _rwid; do
      [ "$_rpath" = "$dir" ] || continue
      is_main_pane "$_rp" && continue
      win="$_rwid"; break
    done < <(tmux list-panes -a -F '#{pane_id}'$'\t''#{pane_current_path}'$'\t''#{window_id}' ...)
```
By `pane_current_path` == worktree dir, skipping main panes, **first match wins**. In a
multi-pane window any pane whose cwd matches resolves the window — fine — but a
worktree shared by two windows resolves arbitrarily.

Gate-wait guard (bin/fleet:3173–3179):
```
    if [ -n "$wlive" ] && printf '%s\n' "$gatewait" | grep -qxF "$wlive"; then
      echo "skip   $lbl: sub-orch parked at a gate — pop its message first (use --force)"; continue
    fi
```
where `wlive` is derived at bin/fleet:3167–3169 from `pane_current_path == $dir`.

**Key finding — sub-orch panes are NOT torn down by `cmd_reap` at all.**
1. Scratch agents are never persisted (`[ "$scratch" = 1 ] || persist_agent`,
   bin/fleet:1238), so a `so-<id>` window never appears in the agents file `cmd_reap`
   iterates.
2. Even if it did, a sub-orch's cwd is `$root` (bin/fleet:997) and the
   not-a-linked-worktree guard (bin/fleet:3132) would skip it.
3. Consequently the gate-wait guard at 3177 can only ever fire on a **worker**
   worktree whose live window name happens to equal a `so-d<N>` name — which cmd_new
   never produces (owned workers are named `d<N>-<repo>/<branch>`, bin/fleet:1087).
   The guard therefore looks effectively unreachable in practice; worth confirming.

The only real sub-orch teardown paths are:
- the dashboard Close/Remove/Force actions (bin/fleet-dash:1657/1666, both via
  `safe-kill-window`, plus `dispatch cancel` — §6);
- `cmd_hide` moving it further out of sight (not a kill);
- whole-session kill (bin/fleet:3838).

---

## 6. `bin/fleet-dash` — move-in on Enter, move-out on `h`

### Enter (agents view) — bin/fleet-dash:1806–1820
```
1806:      (( N == 0 )) && continue
1807:      win=$(field "$sel" 3)
1810:      # A window parked in <sess>_hidden is not a member of $SESS, so a bare
1811:      # select-window only changes the active window of the OWNING session and the
1812:      # $SESS client never sees it. Re-derive the window's session ... move it onto the bar first.
1813:      wsess=$(tmux display -p -t "$win" '#{session_name}' 2>/dev/null)
1814:      if [ -n "$wsess" ] && [ "$wsess" != "$SESS" ]; then
1816:        tmux move-window -s "$win" -t "$SESS:" 2>/dev/null   # pull onto the bar + make navigable
1817:        tmux set -w -t "$win" @fleet_hidden 0 2>/dev/null    # surfaced: re-enable notifications
1818:      fi
1819:      tmux select-window -t "$win" 2>/dev/null
1820:      load_rows; last_load=$SECONDS ;;
```

### `h` (hide) — bin/fleet-dash:1824–1834
```
1824:    h)             # hide the selected agent off the bar (into <sess>_hidden); refuses main
1825:      [ "$MODE" = inbox ] && continue
1826:      (( N == 0 )) && continue
1827:      (( sel >= N )) && { status="orphans row — press e for messages"; continue; }
1828:      win=$(field "$sel" 3)
1833:      status=$("$FLEET_BIN" hide "$win" 2>&1 | tail -1)
1834:      load_rows; last_load=$SECONDS ;;
```
`h` **delegates to `fleet hide`** (bin/fleet:3508) so dash + CLI share one path
(main-guard, `@fleet_hidden 2`, `_hold` placeholder kill). It passes the raw window id,
which is `_resolve_agent`'s top-priority tier (bin/fleet:3496).

A third move-in exists in the inbox "jump to source agent" path,
bin/fleet-dash:800–810 — same `move-window` + `@fleet_hidden 0` pair.

Row hidden-ness is derived **physically**, not from the marker
(bin/fleet-dash:410–416): a window whose `session_name == ${SESS}_hidden` is hidden
(field 9 of `ROWS[]`), rendered as a ` (hidden)` label suffix
(bin/fleet-dash:979–982) and a `· N hidden` title segment (bin/fleet-dash:881).

### Layout assumptions in fleet-dash

- **Everything is WINDOW-granular, not pane-granular.** `field "$sel" 3` is a
  `window_id`; `move-window`/`select-window`/`safe-kill-window` all take window
  targets. So the move-in/move-out is layout-agnostic — a 2-pane nvim+harness window
  moves as a unit. Good.
- **But the ROW itself is pane-derived.** Rows come from `fleetd`'s pane list; each row
  carries a `pane_id` in field 6, used for `harness_of "$pane"` / permission-mode
  picking (bin/fleet-dash:1841–1848) and for the `m` key. A multi-pane window can
  therefore produce **multiple rows sharing one window_id**, so Enter/`h` on either row
  acts on the whole window while `m` acts on only one pane. `HIDDEN_N` is incremented
  per-**pane** (bin/fleet-dash:416), so a multi-pane hidden window over-counts.
- `tmux list-panes -s -t "${SESS}_hidden"` at bin/fleet-dash:601 likewise enumerates
  panes, not windows.
- `is_suborch_name "$_wn"` in the teardown menu (bin/fleet-dash:1645–1653) resolves the
  `so-d<N>` identity from `#{window_name}` of `$win` (not the path-derived label), then
  strips to the bare id (`_did="${_wn#so-}"; _did="${_did%%-*}"`) and calls
  `fleet dispatch cancel "$_did"` after `safe-kill-window` — **sticky**: it refuses to
  downgrade a ledger already at `done|failed|cancelled` (bin/fleet-dash:1648–1652).
  This is "Layer 2 of the zombie fix".

---

## Cross-cutting risks for an nvim-layout sub-orch (d25 relevance)

1. `is_harness_cmd` already accepts `nvim` (bin/fleet:1593) → liveness can never be
   false-dead, but is trivially false-**alive** for a bare/orphaned nvim.
2. Three `head -1` pane picks assume a single pane and would silently pick pane 0:
   `suborch_live` (1607), `cmd_new`'s `_wpane` role/owner stamp (1203),
   `main_window_id`/role stamps (3660, 4455).
3. `suborch_pane_for` (1285) returns the first listed pane of the matched window — a
   gate-pop `send-keys` could land in the editor rather than the harness.
4. `cmd_new --scratch` hard-forces `bare=1` (bin/fleet:998), so an nvim sub-orch is not
   reachable through the current spawn path at all without changing that line.
5. fleet-dash's per-pane rows would double-list a 2-pane sub-orch window and skew
   `HIDDEN_N`.
6. `safe_kill_window` is the one function already pane-count-correct (iterates all
   panes) — it needs no change.
