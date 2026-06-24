# Proof — fix scratch `fleet ready` bleed

## Bug

A scratch/repo-less agent (cwd = project root) running bare `fleet ready` wrote a
marker into the **shared** project-root `.fleet/ready`. Once that scratch agent
died, the read-side suppression (`marker_pane in live_panes`) stopped applying,
so the marker bled onto **every** root-cwd sibling (`main`, `claude`, sub-orchs
like `so-d8`), falsely flagging them `done`/`ready` in `fleet ls` and dashboard.

## Fix (two layers)

1. **Write side** (`cmd_ready`, self-path only): refuse to write a marker when the
   resolved git root equals the **project root** (`fleet_root`). Scratch/root
   agents have no worktree to ready → friendly no-op, exit 0, no marker. The
   `<target>` orchestrator path and the real-worker-in-worktree path are
   unchanged. `--clear` still runs (cleans a stray root marker).
2. **Read side** (`agents_tsv` python): a **dead** writer-pane marker no longer
   bleeds onto siblings when the cwd has **2+ live occupants** (the shared root).
   The single-occupant reused-worktree stale-pane restore case (count == 1) still
   keeps its pill — no regression.

`cmd_reap` is untouched (reads the marker file directly, ignores `pane=`).

---

## Evidence

### (a) self-path from a fake PROJECT ROOT cwd → NO marker + friendly message

```
$ ( cd $T/projroot && FLEET_SESSION=fake FLEET_ROOT=$T/projroot TMUX_PANE=%99 fleet ready )
fleet ready: no worktree here (scratch/root agent) — nothing to mark for reaping
marker exists? -> NO-GOOD
```

### (b) self-path from a fake WORKTREE cwd → marker IS written, with `pane=`

```
$ ( cd $T/repo/featbranch && FLEET_SESSION=fake FLEET_ROOT=$T/projroot TMUX_PANE=%42 fleet ready -m "done" )
marked ready for deletion: /tmp/.../repo/featbranch (done)
marker exists? -> YES-GOOD
marker contents:
ts=2026-06-24T13:35:35+02:00
by=worker
pane=%42
reason=done
```

### (c) shared root marker `pane=%DEAD`, 3 LIVE siblings share root cwd → NO bleed

```
=== (c) shared root marker pane=%DEAD, 3 LIVE siblings share root cwd ===
  win/pane/ready: main	%1	
  win/pane/ready: claude	%2	
  win/pane/ready: so-d8	%3	
  any sibling flagged ready? -> NONE-GOOD
```

### (d) single-occupant worktree, stale (dead) writer pane → KEEP ready (no regression)

```
=== (d) single-occupant worktree, stale (dead) writer pane -> KEEP ready ===
  win/pane/ready: repo/feat	%9	ready
  single occupant keeps ready? -> YES-GOOD
```

### (e) sanity — live writer pane keeps its OWN pill, siblings still suppressed

Proves the read-side change is *targeted*, not a blanket clear.

```
=== (e) writer pane %2 LIVE: only %2 keeps ready, siblings suppressed ===
  win/pane/ready: main	%1	
  win/pane/ready: claude	%2	ready
  win/pane/ready: so-d8	%3	
```

### syntax

```
$ bash -n bin/fleet && echo OK
bash syntax OK
```
