# TDD-RED — d5 / ls-popup-navigate

Proof that the interactive `fleet ls` picker behaviour is **absent** in the
pristine `bin/fleet` (before implementation).

## How to run

```sh
SELF=/home/red/proj/pc-tune/fleet/fleet_ls-popup-navigate/bin/fleet
bash .fleet/notes/tests/ls_pick_test.sh "$SELF"
```

The harness builds a throwaway `tmux -L lsnavtest` server with `FLEET_SESSION=sbx`
and an empty `XDG_RUNTIME_DIR` (forces the daemon-down `@agent_state` fallback in
`agents_tsv`, so `rpc fleet.list` can't reach the live `pc` daemon). Fake agents:
`repoA_feat`(blocked), `repoB_fix`(working), `repoC_idle`(idle), plus a parked
scratch agent in the `sbx_hidden` sibling session. The `--pick` fzf path is driven
through a real pty (`ptyrun.py`) with `FZF_DEFAULT_OPTS=--filter=<query>` so fzf
selects a row non-interactively; navigation is asserted via the sbx server's active
window id. Same-session jump uses `select-window` (works headless); `switch-client`
is a no-op without an attached client but is harmless.

## RED output (pristine bin/fleet)

```
== windows: A=@1(blocked) B=@2(working) C=@3(idle) ==
PASS  static print lists *_hidden agent
FAIL  --measure is not the static table (no tab header)
FAIL  --measure emits fzf prompt chrome line
FAIL  --measure drops *_hidden rows
PASS  --measure exits 0
PASS  ls --pick piped/non-tty returns (no hang)
PASS  ls --pick non-tty falls back to printed rows
FAIL  picking repoC_idle navigates to its window (@1==@3)
FAIL  picking repoB_fix navigates to its window (@1==@2)
PASS  *_hidden agent is not selectable (active stays @1)
PASS  no-match pick is inert (active stays @1)
PASS  fleet doctor reports ok fzf
== 7 passed, 5 failed ==
exit 1
```

## Why each FAIL proves the behaviour is missing

- **`--measure is not the static table`** — pristine `cmd_ls` ignores the unknown
  `--measure` flag and prints the normal static table, whose header is the
  tab-separated `STATE\tAGENT\tWINDOW\tIN-STATE`. The picker face must NOT be the
  static table → fails until `--measure` builds the fzf-row face.
- **`--measure emits fzf prompt chrome line`** — no `agent>` prompt placeholder
  exists in the static table; the sizer face needs it (mirrors `cmd_sessions
  --measure`).
- **`--measure drops *_hidden rows`** — pristine static print *shows* the
  `sbx_hidden` scratch agent (`scratchpad`); the picker face must drop `*_hidden`
  (teleport trap). Until the separate row-builder exists, `scratchpad` leaks into
  `--measure`.
- **`picking repoC_idle / repoB_fix navigates`** — pristine `ls --pick` ignores
  `--pick`, prints the static table, launches no fzf, runs no `switch-client` /
  `select-window`. The active window stays `@1` instead of moving to the picked
  agent's window → the core navigation is absent.

The PASS rows are guards that must STAY green after the change (static still lists
hidden; piped/non-tty never hangs; `*_hidden` never a jump target; cancel inert;
`fleet doctor` ok fzf). The empty-diff keystone (`ls` byte-for-byte unchanged) is
checked separately by the driver: `ls-static.PRISTINE.out` vs the post-impl capture.
