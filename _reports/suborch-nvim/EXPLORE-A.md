# EXPLORE-A — cmd_new bare vs nvim, hidden-session parking, tmux env plumbing

Repo: `/home/red/proj/pc-tune/fleet/main`. All citations `bin/fleet:<line>` unless noted.
`bin/fleet` = 5091 lines. Research only; no code written.

---

## 1. cmd_new control flow

`cmd_new()` starts at **bin/fleet:962**.

### 1.1 Locals + arg parsing (962-978)

```
cmd_new() {
  local repo="" branch="" prompt="" bare=0 base="" harness="" scratch=0 switch=0 mode="" self_merge=1 sm_flag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) prompt="$2"; shift 2 ;;
      --bare) bare=1; shift ;;
      --scratch) scratch=1; shift ;;
      --switch|-s) switch=1; shift ;;
      --base) base="$2"; shift 2 ;;
      --harness|-h) harness="$2"; shift 2 ;;
      --self-merge) sm_flag=1; shift ;;
      --no-self-merge) sm_flag=0; shift ;;
      --mode) mode="$2"; shift 2 ;;
      -*) die "unknown flag $1" ;;
      *) if [ -z "$repo" ]; then repo="$1"; elif [ -z "$branch" ]; then branch="$1"; else die "extra arg $1"; fi; shift ;;
    esac
  done
```

Note the positional collector (line 976): first positional → `repo`, second → `branch`.
Under `--scratch` the first positional is reinterpreted as a **window label** (see 998-1002).

Harness resolution 979-981:
```
  [ -n "$harness" ] || harness=$(harness_select)
  harness_load "$harness"
  [ -n "$mode" ] && H_START_MODE="$mode"   # --mode overrides the harness default start mode
```

Root/session 983-985: `fleet_root` / `session_name`, both `die` if not inside tmux.

Self-merge default 990-993: `self_merge=1`, `0` if `$root/.fleet/no-self-merge` exists, `$sm_flag` overrides.

### 1.2 `--scratch` branch — bare=1 is IMPLIED (994-1004)

```
  if [ "$scratch" = 1 ]; then
    # repo-less scratch agent: no repo, no branch, no worktree. Always a plain
    # agent pane (nothing to edit in nvim), launched at the project root. The
    # first positional, if any, is just a window label.
    bare=1
    dir="$root"
    wname=$(scratch_wname "$sess" "${repo:-scratch}")
    docs="$root/.fleet/notes/scratch/${repo:-scratch}"
    mkdir -p "$docs" 2>/dev/null || true
```

**`bare=1` is set two ways only**: explicit `--bare` (967) and implicitly by `--scratch` (**998**).
There is no other assignment. So `scratch ⇒ bare`, and a scratch agent can NEVER take the nvim path.
This is the load-bearing fact for the d25 question: sub-orchs are spawned via
`cmd_new --scratch` (1665), therefore they are always plain harness panes, never nvim.

### 1.3 Non-scratch branch — worktree resolution (1005-1069)

- 1006: usage `die` if repo+branch missing.
- 1007: `repo_base=$(resolve_repo "$root" "$repo")`.
- 1009-1013: plain working repo (`$repo_base/.git` and not bare) → `dir="$repo_base"`, no worktree.
- 1014-1069: container layout → `dir="$repo_base/$branchdir"`; if absent, pick `anchor`
  (bare container at 1016, else first subdir with `.git` at 1019-1022), `git fetch`,
  then `worktree add` existing branch (1029) or `worktree add -b` off the freshest base
  (1031-1057: prefers LOCAL `refs/heads/$from` when it is ahead of / diverged from origin).
- 1071: `wname="$(basename "$repo_base")/$branchdir"`.
- 1074-1075: `docs="$dir/.fleet/notes"`; mkdir.
- 1080-1086: appends `/.fleet/` to `$(git rev-parse --git-common-dir)/info/exclude` so
  fleet's per-worktree state is git-invisible with no tracked `.gitignore`.
- 1069 (`inject_secrets`) at 1090: `inject_secrets "$(basename "$repo_base")" "$dir" || true`.

### 1.4 Owner + d<N>- window prefix (1076-1090, code at 1083-1090)

```
  local _owner=""
  if [ -n "${FLEET_SUBORCH_ID:-}" ] && [ -z "${FLEET_NEW_SUBORCH_ID:-}" ]; then
    _owner="$FLEET_SUBORCH_ID"
    local _did="${FLEET_SUBORCH_ID#so-}"; _did="${_did%%-*}"   # so-d11[-slug] -> d11
    case "$_did" in d[0-9]*) wname="$_did-$wname" ;; esac       # d11-<repo>/<branchdir>
  fi
```

Gate: `FLEET_SUBORCH_ID` set (inherited from the spawning sub-orch's pane env) AND
`FLEET_NEW_SUBORCH_ID` unset (this spawn is not the sub-orch itself). Same gate is reused
verbatim for the `@fleet_owner` stamp at 1204.

`hbin=$(harness_bin)` at 1093. `rm -f "$dir/.fleet/ready"` at 1099 (reap-safety on worktree reuse).

### 1.5 THE FORK: `if [ "$bare" = 1 ]` at line 1101, `else` (nvim) at 1161

```
  local win_id
  if [ "$bare" = 1 ]; then
```

#### 1.5a bare argv construction (1102-1110)

```
    # bare pane: run the harness directly; prompt is one arg, via the flag (or
    # positional when H_PROMPT_FLAG is empty, e.g. claude).
    local argv=("$hbin")
    # shellcheck disable=SC2206
    [ -n "$H_ARGS" ] && argv+=($H_ARGS)
    [ -n "$H_START_MODE" ] && argv+=(--permission-mode "$H_START_MODE")
    if [ -n "$prompt" ]; then
      [ -n "$H_PROMPT_FLAG" ] && argv+=("$H_PROMPT_FLAG")
      argv+=("$prompt")
    fi
```

For claude, `harness.d/claude.conf:6` sets `H_PROMPT_FLAG=""` → the prompt is a bare
**positional argv element**. `H_START_MODE="auto"` (claude.conf:12) → `--permission-mode auto`.

#### 1.5b bare + scratch → hidden-session spawn (1116-1150)

```
      local hidden="${sess}_hidden"
      win_id=""
      local _eargs=(-e FLEET_ROLE=worker -e FLEET_DOCS="$docs" -e FLEET_SELF_MERGE="$self_merge")
      [ -n "${FLEET_NEW_SUBORCH_ID:-}" ] && _eargs+=(-e FLEET_SUBORCH_ID="$FLEET_NEW_SUBORCH_ID")
      if tmux has-session -t "=$hidden" 2>/dev/null; then
        win_id=$(tmux new-window -d -P -F '#{window_id}' -t "=$hidden" -n "$wname" -c "$dir" \
          "${_eargs[@]}" "${argv[@]}" 2>/dev/null)
        [ -n "$win_id" ] || win_id=$(tmux new-session -d -P -F '#{window_id}' -s "$hidden" -n "$wname" -c "$dir" \
          "${_eargs[@]}" "${argv[@]}" 2>/dev/null)
      else
        win_id=$(tmux new-session -d -P -F '#{window_id}' -s "$hidden" -n "$wname" -c "$dir" \
          "${_eargs[@]}" "${argv[@]}" 2>/dev/null)
        [ -n "$win_id" ] || win_id=$(tmux new-window -d -P -F '#{window_id}' -t "=$hidden" -n "$wname" -c "$dir" \
          "${_eargs[@]}" "${argv[@]}" 2>/dev/null)
      fi
      tmux set -t "$hidden" @fleet_root "$root" 2>/dev/null || true
```

TOCTOU note (1131-1138): `has-session||new-session` races two concurrent scratch spawns,
so BOTH primitives are tried in either direction. `=$hidden` exact-match so fnmatch can't
mis-target. Comment at 1149-1150: `set-option` on a SESSION target **rejects** the `=`
prefix ("no such session: =...") unlike has-session/move-window/kill-session — so plain
`"$hidden"` at 1151.

**Both spawn primitives suppress stderr (`2>/dev/null`)** — this is exactly how the
"command too long" failure used to be swallowed (see §4).

#### 1.5c bare, non-scratch (1157-1159)

```
    else
      win_id=$(tmux new-window -d -P -F '#{window_id}' -t "$sess" -n "$wname" -c "$dir" \
        -e FLEET_ROLE=worker -e FLEET_DOCS="$docs" -e FLEET_SELF_MERGE="$self_merge" "${argv[@]}")
    fi
```

Note: **no `2>/dev/null`** here — a failure is visible on stderr. Only 3 env vars; no
`FLEET_SUBORCH_ID` (see §5 gap).

#### 1.5d nvim path (1160-1173)

```
  else
    # nvim pane: claude autostarts via claudecode.nvim; other harnesses open in a
    # generic :terminal. Both seed the prompt + take FleetSend over the nvim RPC.
    local nsock="$RUNTIME_DIR/fleet/nvim-$(date +%s%N).sock"
    mkdir -p "$RUNTIME_DIR/fleet"
    win_id=$(tmux new-window -d -P -F '#{window_id}' -t "$sess" -n "$wname" -c "$dir" \
      -e FLEET_ROLE=worker -e FLEET_DOCS="$docs" -e FLEET_SELF_MERGE="$self_merge" \
      -e FLEET_AUTOCLAUDE="$([ "$H_NVIM_PLUGIN" = 1 ] && echo 1 || echo 0)" \
      -e FLEET_HARNESS="$H_NAME" -e FLEET_HARNESS_BIN="$hbin${H_ARGS:+ $H_ARGS}" \
      -e FLEET_TERM_MATCH="$H_TERM_MATCH" -e FLEET_PROMPT="$prompt" \
      -e FLEET_START_MODE="$H_START_MODE" \
      nvim . --cmd "lua pcall(dofile, '$FLEET_DIR/nvim/fleet.lua')" --listen "$nsock")
    tmux set -w -t "$win_id" @fleet_nvim_sock "$nsock"
  fi
```

**There is NO `split-window` in cmd_new.** The "editor + agent split" advertised in CLAUDE.md
is produced *inside* nvim, not by tmux: claudecode.nvim opens its own terminal window
(`nvim/fleet.lua:33` `terminal.open`), or for generic harnesses `botright vsplit` +
`:terminal` (`nvim/fleet.lua:45-46`). The only `split-window` in the file is the dashboard
pane at **bin/fleet:3582**.

Also **no `send-keys` in cmd_new at all** — prompt seeding is argv (bare) or env (nvim).
`send-keys` appears only in cmd_send (1405), cmd_mode fallback (3461), notify (2118-2119),
inbox paste (2726).

### 1.6 Post-spawn common tail (1174-1238)

- 1174-1189 loud-failure guard (§4).
- 1190: `tmux set -w -t "$win_id" @fleet_harness "$H_NAME"`.
- 1196: `[ -n "${FLEET_NEW_WID_FILE:-}" ] && printf '%s\n' "$win_id" > "$FLEET_NEW_WID_FILE"` —
  how `resolve_or_spawn_suborch` (1655-1673) captures the window id for the ledger.
- 1203-1209: `@fleet_owner` + `record_pane_role` (§6).
- 1212-1213: `@fleet_state_src "$H_STATE_SRC"`, `@fleet_busy_re "$H_BUSY_RE"` if set.
- 1214-1223: scratch → `@fleet_hidden 1`.
- 1224: `echo "spawned $wname ($H_NAME) in window $win_id"`.
- 1227-1234 `--switch`:
```
  if [ "$switch" = 1 ]; then
    if [ "$scratch" = 1 ]; then
      tmux move-window -s "$win_id" -t "$sess:" 2>/dev/null || true
      tmux set -w -t "$win_id" @fleet_hidden 0 2>/dev/null || true
    fi
    tmux select-window -t "$win_id" 2>/dev/null || true
  fi
```
  Comment 1225-1226: a parked window must be moved INTO the visible session first because
  "a bare select-window only changes the active window of the session that owns it."
- 1236: `[ "$scratch" = 1 ] || persist_agent "$sess" "$dir" "$(basename "$repo_base")" "$branch" "$bare" "$base" "$H_NAME" "$self_merge" "$wname" "$_owner"`
  — scratch agents are **not persisted** (repo-less + ephemeral), so `cmd_restore` (738-766)
  never brings a sub-orch back.
- 1237: `sync_main_tiles "$sess"`.

---

## 2. How the nvim path launches nvim

**Command** (1173): `nvim . --cmd "lua pcall(dofile, '$FLEET_DIR/nvim/fleet.lua')" --listen "$nsock"`

- **cwd**: `-c "$dir"` on `new-window` (1166) — the worktree dir (or `$repo_base` for a plain
  repo). `nvim .` therefore opens the worktree root as the netrw/oil buffer.
- **`--cmd`** runs before vimrc; `pcall(dofile, …)` so a missing/erroring fleet.lua can never
  block nvim. The user's own nvim config is untouched (`nvim/fleet.lua:3`).
- **`--listen "$nsock"`** where `nsock="$RUNTIME_DIR/fleet/nvim-$(date +%s%N).sock"` (1163);
  the socket path is stamped on the window as `@fleet_nvim_sock` (1174) and is the ONLY
  discriminator fleet uses to tell nvim panes from bare panes (comment 1384-1385, use 1386).

**Env — delivered exclusively via tmux `-e` flags on `new-window`.** No exported shell vars,
no send-keys. Eight `-e` pairs (1167-1172):

| var | value | consumer |
|---|---|---|
| `FLEET_ROLE` | `worker` | dispatch hook fork-bomb gate (§1 of the hook) |
| `FLEET_DOCS` | `$dir/.fleet/notes` | agent scratch-docs dir |
| `FLEET_SELF_MERGE` | `0/1` | worker merge/push permission |
| `FLEET_AUTOCLAUDE` | `1` iff `H_NVIM_PLUGIN=1` | `nvim/fleet.lua:21` |
| `FLEET_HARNESS` | `$H_NAME` | informational |
| `FLEET_HARNESS_BIN` | `$hbin${H_ARGS:+ $H_ARGS}` | `nvim/fleet.lua:40,46` (generic `:terminal` cmd) |
| `FLEET_TERM_MATCH` | `$H_TERM_MATCH` (claude → `claude`) | `nvim/fleet.lua:10-14` term_chan matcher |
| `FLEET_PROMPT` | `$prompt` | `nvim/fleet.lua:20` |
| `FLEET_START_MODE` | `$H_START_MODE` (claude → `auto`) | `nvim/fleet.lua:31-32` |

**Not passed on the nvim path**: `FLEET_SUBORCH_ID` — it is added only in the scratch
`_eargs` (1130) and only when `FLEET_NEW_SUBORCH_ID` is set. See §5.

**fleet.lua's launch sequence** (`nvim/fleet.lua:17-64`), on a one-shot `VimEnter`:
- `local prompt = vim.env.FLEET_PROMPT` (:20)
- if `vim.env.FLEET_AUTOCLAUDE == "1"` (:21): after `defer_fn(…, 300)`,
  `require("claudecode.terminal")`, `cmd_args = "--permission-mode " .. sm` from
  `vim.env.FLEET_START_MODE` (:31-32), `pcall(terminal.open, {}, cmd_args)` (:33).
- Prompt seeding (:34-38):
```
        -- Seed the prompt through the terminal channel (same path as FleetSend)
        -- — passing it as a CLI arg through terminal.open proved unreliable.
        if prompt and prompt ~= "" then
          vim.defer_fn(function() FleetSend(prompt) end, 3000)
        end
```
  i.e. **3-second delay**, then a `nvim_chan_send` into the claude terminal, plus a separate
  `\r` 80 ms later (`term_write`, :86-97 — the split write is deliberate: a combined write
  reads as a bracketed paste and the TUI swallows the CR).
- else if `FLEET_HARNESS_BIN` non-empty (:40-61): `botright vsplit` + `terminal <bin>` +
  `startinsert`, plus `<leader>cs` / `<leader>ca` parity maps, then the same deferred seed.

---

## 3. The hidden session `<sess>_hidden`

Naming is always `"${sess}_hidden"` — literal in cmd_new (1123), ensure_hidden_session (3477),
cmd_hide (3528), cmd_unhide (3549), and in every session-scoped filter
(324, 337, 407, 1258, 1274, 1290, 1342, 1581, 1623).

### 3.1 Creation — two paths

**(a) cmd_new --scratch (1139-1148)** creates it *implicitly* via `tmux new-session -d -P -F
'#{window_id}' -s "$hidden" -n "$wname" -c "$dir" …` — the agent window itself is the
session's first window, so no placeholder is needed.

**(b) `ensure_hidden_session`** (**3467-3486**), used by `cmd_hide` and the dash 'h' handler:

```
ensure_hidden_session() { # <sess>  -> echoes placeholder window id (or "")
  local sess="$1" hidden="${1}_hidden" ph=""
  if ! tmux has-session -t "=$hidden" 2>/dev/null; then
    ph=$(tmux new-session -d -P -F '#{window_id}' -s "$hidden" -n _hold sh 2>/dev/null)
    tmux set -t "$hidden" @fleet_root "$(tmux show -t "$sess" -v @fleet_root 2>/dev/null)" 2>/dev/null
  fi
  printf '%s' "$ph"
}
```

Header comment (3467-3475): tmux cannot create an EMPTY session, so a throwaway `_hold`
window running plain `sh` is spun up (no `@agent_state` → never flickers into the dash), the
caller kills it AFTER its move-window. **LOAD-BEARING** warning: the caller MUST guard
`kill-window` on a non-empty id — under a concurrent create the loser's `new-session` fails,
`ph` is EMPTY, and `kill-window -t ""` would fall through to killing the *current* window.

`@fleet_root` is mirrored onto the hidden session in both paths (1151 / 3479) so `fleet`
sub-commands run from inside a parked pane can still resolve the project root. Comment at
2288-2290 confirms this is what lets a parked sub-orch enqueue into the inbox.

### 3.2 Moving in / out — always `move-window`, never `link-window`

There is **no `link-window`** anywhere in the repo. Every transition is `tmux move-window`:

- **park (user)** — `cmd_hide` (3508-3536):
```
  local ph; ph=$(ensure_hidden_session "$sess")
  tmux move-window -s "$win" -t "=${sess}_hidden:" 2>/dev/null
  tmux set -w -t "$win" @fleet_hidden 2 2>/dev/null   # 2 = USER-hidden (still alerts on block)
  [ -n "$ph" ] && safe_kill_window "$ph"
```
  Main-guard first (3524-3527): refuses by name `main` AND by `is_main_pane "$pane"`.
- **surface** — `cmd_unhide` (3538-3554):
```
  tmux move-window -s "$win" -t "$sess:" 2>/dev/null   # pull onto the bar + make navigable
  tmux set -w -t "$win" @fleet_hidden 0 2>/dev/null     # surfaced: re-enable notifications
  tmux select-window -t "$win" 2>/dev/null
```
- **surface on `--switch`** — cmd_new 1230-1231 (same two calls, inline).
- The dashboard does the same on Enter (move-in) / 'h' (move-out) — comment 1121-1122.

Note the target-syntax asymmetry: `-t "=${sess}_hidden:"` (exact-match prefix, 3528) going
in, `-t "$sess:"` coming out (1230, 3549).

### 3.3 `@fleet_hidden` tri-state

| value | meaning | set at |
|---|---|---|
| `1` | parked-at-spawn (scratch) | 1222 |
| `2` | USER-hidden via `fleet hide` (still alerts on block) | 3529 |
| `0` | surfaced | 1231, 3550 |

Comment 1214-1221 is explicit that bar-hiding is achieved **by living in `<sess>_hidden`,
NOT by a `window-status-format` override** — "leaving one set would blank the window even
after it is surfaced into the visible session."

Why a separate session at all (1117-1122): "tmux has no per-window skip-in-next/prev flag, so
the window must live OUTSIDE the visible session." `fleetd` still sees them (`list-panes -a`
is server-global) so they remain in the dashboard.

### 3.4 Consumers that must union both sessions

`cmd_ls` filter 324 (`$3==s || $3==s"_hidden"`), agent resolution 1258 / 1274 / 1290 / 1342,
`suborch_find_wid` 1581, `suborch_has_live_workers` 1623, `_resolve_agent` call in cmd_unhide 3544.
Conversely, `*_hidden` is deliberately EXCLUDED from the session switcher (337, 407) — comment
329-331/403-406: a `switch-client` into the hidden session is "a teleport into the bare hidden
session", which the picker must never do.

---

## 4. MAX_IMSGSIZE / "command too long"

### 4.1 The guard in cmd_new (1175-1189)

```
  # LOUD FAILURE on empty win_id. An empty id means tmux created NO window — e.g.
  # an over-cap seed prompt overflowed MAX_IMSGSIZE so new-window/new-session died
  # with "command too long" (rc=1) and 2>/dev/null ate it. Historically we fell
  # through and printed "spawned … in window " with a blank id, leaving the dispatch
  # layer to respawn forever. A real spawn failure must be VISIBLE + debuggable, so
  # error to STDERR and return non-zero. Stay fail-silent ONLY for genuine
  # tmux-missing (the documented degrade-to-subset path) — a successful spawn always
  # yields a non-empty id, so normal worker/scratch/nvim spawns are unaffected.
  if [ -z "$win_id" ]; then
    if command -v tmux >/dev/null 2>&1; then
      echo "fleet new: spawn FAILED for '$wname' — tmux returned no window id (over-cap seed prompt? look for 'command too long'). NOT spawned." >&2
      return 1
    fi
    return 0   # tmux absent: degrade silently, as elsewhere
  fi
```

This detects failure **indirectly** (empty `win_id`), because the scratch spawn primitives
themselves are `2>/dev/null` (1141/1143/1145/1147).

### 4.2 The second guard — a compact seed instead of the inlined manual (1653-1661)

```
    # Compact IMPERATIVE pointer (not the ~20KB manual inlined): a small seed
    # avoids overflowing tmux's MAX_IMSGSIZE (16384) — the inlined manual would
    # blow the cap, the new-window cmd would fail with "command too long" (rc=1,
    # swallowed by 2>/dev/null), and the sub-orch would never spawn. The pointer
    # makes reading the manual the sub-orch's FIRST action; CWD=project root keeps
    # the relative .fleet/dispatch/<id>/... refs valid. Ends with the dispatch id.
    # NB: the FLEET_*=… line-continuations must flow straight into cmd_new with NO
    # intervening comment, or they degrade from a command-scoped prefix to leaked
    # un-exported globals (fragile inside cmd_reconcile's per-dispatch loop).
```
followed by the actual ~200-byte seed (1662-1667):
```
    FLEET_NEW_WID_FILE="$widf" FLEET_SESSION="$sess" FLEET_ROOT="$root" \
    FLEET_NEW_SUBORCH_ID="$wname" \
      cmd_new --scratch "$wname" -p "You are a fleet dispatch sub-orchestrator (so-$id). Your project root is your CWD ($root).
FIRST, read and follow your operating manual: $FLEET_DIR/FLEET_SUBORCH.md
THEN handle DISPATCH ID: $id — read your instruction at .fleet/dispatch/$id/instruction.txt"
```

### 4.3 The measured limit (prior dispatch's evidence, `_reports/dispatch-seed-fix/`)

- `PROOF-DESIGN.md:33-36` — empirically bisected:
```
plain n=16000 : OK      plain n=16240 : command too long
plain n=16200 : OK      plain n=16260 : command too long
two-args 8190+8190 (=16380 total) : command too long   # cap is TOTAL, not per-arg
```
  `PROOF-DESIGN.md:40`: "Conclusion: tmux imsg `MAX_IMSGSIZE` (16384) total-command cap.
  Not ARG_MAX."
- `TEST-b.md:35-36` — old inline seed (`FLEET_SUBORCH.md`) = **20318 bytes** > 16384.
- `PLAN.md:74` — "tmux refuses: `command too long`, rc=1. `2>/dev/null` hides it; `win_id=""`."
- `PROOF.md:50-54` / `TEST-b.md:76-82` — post-fix behaviour: over-cap `-p` now prints the
  loud stderr line and returns 1.

### 4.4 Prompt delivery: argv vs env — same cap, different budget

| | bare path | nvim path |
|---|---|---|
| mechanism | prompt is an **argv element** of the harness command (1108-1109) | prompt is `-e FLEET_PROMPT="$prompt"` (1170), read by `nvim/fleet.lua:20` and replayed via `FleetSend` after 3 s |
| where it lands in the tmux command | trailing `"${argv[@]}"` | an `-e` flag |
| cap | **the same MAX_IMSGSIZE=16384 TOTAL**, since it is one `new-window`/`new-session` imsg either way | same |
| overflow | `new-window` rc=1 "command too long", no window; scratch swallows stderr → caught only by the empty-`win_id` guard (1184) | `new-window` rc=1; here stderr is NOT suppressed (1166 has no `2>/dev/null`), plus the same guard |
| delivery reliability | claude receives it as its initial positional prompt, synchronously | asynchronous: 300 ms + 3000 ms deferred chan_send; comment `nvim/fleet.lua:34-35` says CLI-arg delivery "proved unreliable" through `terminal.open` |

Key point: the env route gives **no extra headroom** — the cap is on the total command
string, and `-e FLEET_PROMPT=<prompt>` is part of it. The nvim path in fact spends *more*
of the budget (8 `-e` pairs + the nvim/`--cmd`/`--listen` argv) than the bare path.

---

## 5. Pane env inheritance through nvim into claudecode.nvim

**Mechanism.** `tmux new-window -e VAR=val` sets the variable in the **new pane's**
environment (pane-local, not the global/session environment), so it is in the environ of the
pane's initial process — here `nvim`. Any child nvim spawns (`:terminal`, and hence
claudecode.nvim's terminal job) inherits nvim's environ. So **yes: `-e` vars do propagate
into the claude process started later inside nvim's terminal.**

**Evidence in-repo:**
1. nvim itself reads them: `vim.env.FLEET_TERM_MATCH` (`nvim/fleet.lua:11`),
   `vim.env.FLEET_PROMPT` (:20), `vim.env.FLEET_AUTOCLAUDE` (:21),
   `vim.env.FLEET_START_MODE` (:31), `vim.env.FLEET_HARNESS_BIN` (:40, :46). This proves the
   `-e` → nvim leg.
2. The nvim→child leg is exercised by `vim.cmd("terminal " .. vim.env.FLEET_HARNESS_BIN)`
   (:46) and by `terminal.open` (:33) — plain nvim job spawns, which inherit environ.
3. Fleet **relies** on the propagation architecturally: `FLEET_ROLE=worker` is passed by `-e`
   on every cmd_new spawn (1159, 1167, 1129) with the comment at 1111-1115:
   "every cmd_new pane (scratch sub-orch OR code worker) is non-main, so its seed prompt must
   hard pass-through the dispatch hook (§1)". That hook runs **inside the claude process**,
   i.e. inside nvim's terminal child on the nvim path — it can only read `FLEET_ROLE` if the
   var made the whole trip.
4. The converse is documented at 3649-3653 for the main pane:
```
    # FLEET_ROLE=main via tmux -e (pane-local env, NOT inherited by sibling
    # new-window panes, NOT a global tmux env) — this is the load-bearing fork-bomb
    ...
    win=$(tmux new-window -P -F '#{window_id}' -t "$sess" -n main -c "$root" \
      -e FLEET_ROLE=main "$ORCH_BIN")
```
   i.e. `-e` is *pane-local and not sibling-inherited*, but is child-inherited.

**GAP relevant to d25.** `FLEET_SUBORCH_ID` is passed by `-e` in exactly **one** place —
line 1130, inside the scratch branch, and only when `FLEET_NEW_SUBORCH_ID` is set:
```
      [ -n "${FLEET_NEW_SUBORCH_ID:-}" ] && _eargs+=(-e FLEET_SUBORCH_ID="$FLEET_NEW_SUBORCH_ID")
```
Neither the bare-non-scratch spawn (1158-1159) nor the nvim spawn (1166-1173) passes it.
Consequences:
- A sub-orch (scratch pane) gets `FLEET_SUBORCH_ID=so-d<N>` in its pane env → when it shells
  `fleet new <repo> <branch>`, cmd_new inherits it and stamps `@fleet_owner` (1204-1206).
  That works on both paths, because the stamp is a *window option*, not env.
- But the spawned worker's own env does **not** carry `FLEET_SUBORCH_ID`. So a worker cannot
  itself spawn owned grandchildren, and any code inside a worker that reads
  `$FLEET_SUBORCH_ID` sees empty. The designed substitute is the `@fleet_owner` window option,
  read back at 2408 (`inbox_put`):
```
  [ -n "${TMUX_PANE:-}" ] && owner=$(tmux show -wqv -t "$TMUX_PANE" @fleet_owner 2>/dev/null)
```
  with the rationale at 2402-2406: "a WINDOW OPTION cmd_new set at spawn from the
  env-inherited FLEET_SUBORCH_ID, NOT a message field, so a worker cannot forge it."

**Also note** `harness.d/claude.conf:5` `H_BIN="claude-profile claude"` — the bare path
execs whichever is first on PATH; on the nvim path `hbin` is only used to fill
`FLEET_HARNESS_BIN` (1169) which claude *ignores* (`H_NVIM_PLUGIN=1` → the claudecode branch
runs instead, and claudecode.nvim launches its own `claude` binary from its own config).
So on the nvim path, `H_BIN`/`H_ARGS` are effectively dead for claude; only
`FLEET_START_MODE` reaches the process, as `--permission-mode` (`nvim/fleet.lua:32`).

---

## 6. record_pane_role / @fleet_owner / pane+window options

### 6.1 `record_pane_role` (1568-1573)

```
# Record an optional pane-role registry entry (cross-check for the hook's env gate).
record_pane_role() { # <root> <pane_id> <role>
  [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 0
  mkdir -p "$1/.fleet/roles" 2>/dev/null || return 0
  printf '%s\n' "$3" > "$1/.fleet/roles/$2" 2>/dev/null || true
}
```
Writes `<root>/.fleet/roles/<pane_id>` containing the role word. Fail-silent.

### 6.2 The call site — identical for BOTH paths (1202-1209)

```
  local _wpane; _wpane=$(tmux list-panes -t "$win_id" -F '#{pane_id}' 2>/dev/null | head -1)
  if [ -n "${FLEET_SUBORCH_ID:-}" ] && [ -z "${FLEET_NEW_SUBORCH_ID:-}" ]; then
    tmux set -w -t "$win_id" @fleet_owner "$FLEET_SUBORCH_ID" 2>/dev/null || true
    record_pane_role "$root" "$_wpane" "worker:$FLEET_SUBORCH_ID"
  else
    record_pane_role "$root" "$_wpane" worker
  fi
```

This sits in the **common tail**, after the bare/nvim fork rejoins — so bare, scratch and
nvim panes are stamped identically. `_wpane` is the window's **first** pane; on the nvim path
that is the nvim pane (nvim's internal splits are not tmux panes, so `head -1` is exact).

Comment 1197-1201: `@fleet_owner` is the "live fast-path for inbox_put" plus the durable
roles-file backstop `worker:so-<id>` that "survives daemon/tmux restart"; the roles value
"stays `worker[:…]`, never `main`, so the fork-bomb role gate is intact."

### 6.3 Full option table set by cmd_new

| option | value | line | path |
|---|---|---|---|
| `@fleet_nvim_sock` | `$nsock` | 1174 | **nvim only** — the nvim/bare discriminator (1385-1386) |
| `@fleet_harness` | `$H_NAME` | 1190 | both |
| `@fleet_owner` | `$FLEET_SUBORCH_ID` (bare `so-d<N>`) | 1205 | both, gated |
| `@fleet_state_src` | `$H_STATE_SRC` (claude → `hook`) | 1212 | both |
| `@fleet_busy_re` | `$H_BUSY_RE` if non-empty (claude → empty, skipped) | 1213 | both |
| `@fleet_hidden` | `1` | 1222 | scratch only |
| `@fleet_hidden` | `0` | 1231 | scratch + `--switch` |
| `@fleet_root` (session opt) | `$root` | 1151 | scratch only, on `<sess>_hidden` |

All are **window** options (`set -w`) except `@fleet_root` which is a session option.
`@fleet_owner` is read as `#{@fleet_owner}` in `suborch_has_live_workers` (1627) and via
`tmux show -wqv -t "$TMUX_PANE"` in `inbox_put` (2408) — the latter works because a window
option is visible from any pane in the window.

### 6.4 Owner is deliberately the IMMUTABLE bare id

1078-1082 and 1814-1817: `dispatch rename` slugs the window name (`so-d11` → `so-d11-foo`)
but "the owner identity stays the bare so-<id> (frozen in the pane's env; rename-window never
mutates pane env), so there is NO @fleet_owner re-stamp". `suborch_pane_for` (1285-1295) is
therefore **prefix-tolerant** when matching owner → live window.

### 6.5 persist_agent / restore round-trip

`persist_agent` signature at 569: `session dir repo branch bare base harness [self_merge] [wname] [owner]`.
`cmd_restore` (741-766) replays it, and 760-764:
```
      FLEET_SUBORCH_ID="$owner" cmd_new "${args[@]}" >/dev/null 2>&1 && n=$((n+1))
```
with comment 760-762: "Re-export the saved bare owner so cmd_new re-derives the d<N>- window
prefix AND re-stamps @fleet_owner — restore runs in main with no FLEET_SUBORCH_ID". Restore
passes `--bare` iff the saved field is `1` (753). Scratch/sub-orch panes are never persisted
(1236) and so are never restored.

---

## 7. Summary of the load-bearing facts for d25

1. `--scratch` forces `bare=1` at **1101/998** — a sub-orch is structurally incapable of
   taking the nvim path today.
2. The two spawn sites are **1140/1145 (scratch → `<sess>_hidden`)**, **1158 (bare, visible)**,
   **1166 (nvim, visible)**. cmd_new never uses `split-window` or `send-keys`.
3. Hidden-session parking is `move-window` only; creation needs a `_hold sh` placeholder
   (`ensure_hidden_session`, 3476) unless the agent window itself creates the session.
4. `MAX_IMSGSIZE = 16384`, a **TOTAL** per-command cap; over-cap → rc=1 "command too long",
   no window, detected via empty `win_id` (1184). The nvim path spends MORE of that budget
   than the bare path (8 `-e` pairs incl. the whole prompt).
5. tmux `-e` vars DO reach a program launched later inside nvim's `:terminal` (proved by the
   `FLEET_ROLE` fork-bomb gate working on nvim panes), but `FLEET_SUBORCH_ID` is passed to
   **scratch spawns only** (1130) — an nvim worker would need that `-e` added if the sub-orch
   identity must live in the worker's env rather than in `@fleet_owner`.
6. `record_pane_role` + `@fleet_owner` are in the shared tail (1202-1209) and are already
   path-agnostic — no change needed there to move a sub-orch onto the nvim path.
