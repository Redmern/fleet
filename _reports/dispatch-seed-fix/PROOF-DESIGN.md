# PROOF DESIGN — dispatch sub-orch seed fix

Two parts: (A) the **reproduction already run** in a throwaway tmux that nails the
mechanism, and (B) the **end-to-end dispatch proof** to run against a throwaway
FLEET_SESSION once the fix lands. (A) is done and quoted; (B) is the acceptance test.

## A. Mechanism reproduction (DONE — throwaway `tmux -L seedtest`, tmux 3.6b)

Stub command that records the arg it receives, then idles:
```sh
#!/bin/sh
printf '%s' "$1" > "$CAP"; exec sleep 600
```

### A1 — small arg OK, 20 KB seed FAILS (the bug)
```
$ tmux -L seedtest new-window -d -P -F '#{window_id}' -t '=t' -n A -e CAP=/tmp/capA.txt stub.sh "hello small prompt"
@1                       # OK, capA = 18 bytes (seed reached pane)

$ BIG="$(cat FLEET_SUBORCH.md)"   # 19998 bytes
$ tmux -L seedtest new-window -d -P -F '#{window_id}' -t '=t' -n B -e CAP=/tmp/capB.txt stub.sh "$BIG"
command too long         # rc=1, NO window created, capB never written
```

### A2 — `2>/dev/null` (the real code path) yields EMPTY win_id
```
$ r=$(tmux -L seedtest new-window … stub.sh "$BIG_20KB" 2>/dev/null); echo "win_id=[$r]"
win_id=[]                # → bin/fleet:986 prints "…in window " (blank). EXACT symptom.
```

### A3 — threshold + cause isolation
```
plain n=16000 : OK      plain n=16240 : command too long
plain n=16200 : OK      plain n=16260 : command too long
plain n=16220 : failed to send command
two-args 8190+8190 (=16380 total) : command too long   # cap is TOTAL, not per-arg
-e VAR=<8000> + arg<8000> (≈16 KB) : OK
14 KB arg WITH newlines : OK                            # newlines are NOT the cause
```
Conclusion: tmux imsg `MAX_IMSGSIZE` (16384) total-command cap. Not ARG_MAX
(4 MB), not newlines, not metachars.

### A4 — FIX path proven positive (short pointer) + hidden-session recreate
Precondition: `pc_hidden` session does **not** exist (the secondary-issue case).
```
$ POINTER="You are a fleet dispatch sub-orch. Read & follow …/FLEET_SUBORCH.md
           then handle DISPATCH ID: d99 (instruction: .fleet/dispatch/d99/instruction.txt)."
$ printf %s "$POINTER" | wc -c            → 180
$ tmux -L seedtest new-session -d -P -F '#{window_id}' -s pc_hidden -n so-d99 \
        -e CAP=/tmp/capFIX.txt -e FLEET_ROLE=worker stub.sh "$POINTER"
@0                                        # spawn OK
$ tmux -L seedtest has-session -t '=pc_hidden'   → YES   (hidden session recreated)
$ cat /tmp/capFIX.txt   → full pointer text       (seed content reached the pane)
```

## B. End-to-end acceptance test (run AFTER the fix; no code in this report)

Goal: prove a real `,`-dispatch spawns `so-d<N>` with the manual reaching the
sub-orch, that reconcile re-resolves, and that `pc_hidden` is recreated if absent.

1. **Boot a throwaway session.** `fleet up` a scratch project root (or reuse a
   disposable one). Enable dispatch: `fleet dispatch enable`.
2. **Dispatch.** From the main pane submit a `,`-prefixed prompt (or
   `fleet dispatch <id>` after writing `.fleet/dispatch/<id>/instruction.txt`).
   - **PASS:** `fleet ls` shows `so-d<N>` as a live (hidden) pane; the ledger
     `meta.tsv` has a non-empty `window_id`; the stdout line reads
     `spawned so-d<N> (claude) in window @NN` (id **non-blank**).
3. **Seed actually arrived.** Capture the sub-orch pane
   (`tmux capture-pane -p -t <wid>`): claude's transcript shows it **read
   `$FLEET_DIR/FLEET_SUBORCH.md`** and the `.fleet/dispatch/<id>/instruction.txt`
   as its first actions, and is acting on the manual (classifies / renames / spawns
   a worker). This is the load-bearing check: *the seed content reached the agent.*
4. **Reconcile re-resolves (idempotent).** Kill the sub-orch window
   (`tmux kill-window -t <wid>`), then `fleet reconcile`.
   - **PASS:** a fresh `so-d<N>` respawns, ledger `window_id` updated, no churn on a
     second `reconcile` (live → no-op).
5. **pc_hidden recreated if absent.** Ensure `<sess>_hidden` is gone (kill its last
   window), then `fleet reconcile` (or a new dispatch).
   - **PASS:** `tmux has-session -t '=<sess>_hidden'` returns true again; the
     sub-orch pane is parked inside it.
6. **No regression for plain scratch.** `fleet new --scratch helper -p "echo hi"`
   still spawns normally.

Acceptance = all of 2–6 PASS, with step 3 being the decisive "seed reached the
agent" gate.
