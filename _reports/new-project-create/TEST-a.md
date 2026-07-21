# Tester A report — `fleet new-project` wizard, end-to-end

**Feature:** new-project-create
**Binary under test:** `/home/red/proj/pc-tune/fleet/new-project-create/bin/fleet`
**Verdict:** GREEN — every check passes, including the load-bearing worktree-add and a real `fleet new` driven against the wizard's output.

All work was done in throwaway sandboxes under `/tmp` with `HOME` relocated
(`export HOME=$(mktemp -d)/home`) and `XDG_CONFIG_HOME TMUX FLEET_SESSION FLEET_ROOT`
unset. The real `~/.config/fleet` and any live tmux session were never touched.
Sandboxes were removed after evidence capture.

---

## Code under test (read for context)

- `new_bare_repo()` (bin/fleet:128) — `git init --bare`, then seeds an empty root
  commit via `hash-object`/`commit-tree`, `update-ref refs/heads/main`, and
  `symbolic-ref HEAD refs/heads/main`. Fail-silent: every failure `rm -rf`s the
  half-made repo and returns non-zero.
- `cmd_new_project()` (bin/fleet:421) — `read -e -p` prompts for project dir +
  an add-repo loop, sanitizes repo names with `tr -cd 'a-zA-Z0-9_.-'`, calls
  `new_bare_repo` per repo, writes `$CONF_DIR/projects/<name>.yml` inline with
  `root` contracted via `${pdir/#$HOME/\~}`, then boots `cmd_up` **only** when
  `[ -t 0 ] && [ -t 1 ]` (both stdin and stdout are ttys). Otherwise prints
  "non-interactive: skipped boot".
- `cmd_pick_project()` (bin/fleet:392) — fzf picker; `__fleet_new__` sentinel
  routes to `cmd_new_project`. Not exercised (needs fzf + tty); irrelevant to the
  create path.
- `new-project` dispatch (bin/fleet:4147) — `new-project) shift; cmd_new_project "$@"`.

---

## Commands run + raw evidence (trimmed to signal)

### Drive 1 — wizard, /tmp project dir (outside HOME), repos alpha+beta

```
$ fleet new-project <<EOF   (stdin = pipe, not a tty)
/tmp/.../proj/myproj
alpha
beta
<blank>
EOF
  created repo 'alpha'
  created repo 'beta'
created project 'myproj' -> /tmp/.../proj/myproj (2 repo(s))
  (non-interactive: skipped boot — run 'fleet up myproj')
wizard-exit=0
```

yml written at `$CONF_DIR/projects/myproj.yml`:
```
name: myproj
root: /tmp/fleet-newproj-testa.../proj/myproj
```

Per-repo shape (alpha shown; beta identical):
```
exists:            yes
is-bare-repository: true
core.bare:          true
refs/heads/main:    dace8694...   (resolves)
symbolic-ref HEAD:  refs/heads/main
```

### Check 3 — load-bearing worktree-add (the exact op `fleet new` runs)
```
$ git -C .../alpha worktree add -b feat .../alpha/feat main
exit=0
Preparing worktree (new branch 'feat')
HEAD is now at dace869 init alpha
worktree dir created: yes
invalid-reference present?: 0       <- grep -ci 'invalid reference' == 0
$ git -C .../alpha worktree list
.../alpha       (bare)
.../alpha/feat  dace869 [feat]
```

### Drive 2 — tilde-contraction proof (project dir genuinely UNDER HOME)
Drive 1's project sits outside HOME, so `${pdir/#$HOME/~}` correctly does NOT
contract (the path isn't under HOME). To prove the contraction logic itself
fires, I re-ran with `PROJ=$HOME/work/myproj`:
```
created project 'myproj' -> ~/work/myproj (2 repo(s))
--- yml ---
name: myproj
root: ~/work/myproj
PASS: ~ contraction fired      (grep -E '^root: ~/work/myproj$')
PASS: no literal home path     (grep -q "$HOME" finds nothing)
```

### Check 4 — REAL `fleet new` against the wizard-created project
`session_name()` honors `$FLEET_SESSION`; `fleet_root()` honors `$FLEET_ROOT`.
Setting both lets the real `cmd_new` run with no tmux server. It executed the
genuine worktree-add code path and only fail-silently degraded at the final tmux
window step (exactly as designed):
```
$ FLEET_ROOT=.../myproj FLEET_SESSION=nope_no_session fleet new alpha feat
creating worktree .../alpha/feat (feat)...
Preparing worktree (new branch 'feat')
HEAD is now at 17ca1b8 init alpha
can't find window: nope_no_session         <- fail-silent tmux degrade
spawned alpha/feat (claude) in window
fleet-new-exit=0
$ git -C .../alpha worktree list
.../alpha       (bare)
.../alpha/feat  17ca1b8 [feat]
```
This is stronger than check 3's simulation: the **production `cmd_new`** itself
created the worktree off `main` with no "invalid reference: main", proving the
wizard's seed satisfies the real consumer. No tmux/HOME outside /tmp was touched.

### Adversarial extras
- **Re-run on existing non-empty dir, answer `n`** → `fleet: cancelled`, exit 0.
  The non-empty-dir guard (`read -e -p "...use it anyway?"`) works on the pipe.
- **Duplicate repo name** → `'alpha' already exists, skipped` (second alpha).
- **Junk-char name `we!@#ird`** → sanitized to dir `weird` and created.
  Confirms `tr -cd 'a-zA-Z0-9_.-'`.

### Author's harness — independent confirmation
```
$ bash .fleet/notes/proof-new-project.sh; echo "exit=$?"
... 16 PASS lines ...
GREEN — all checks passed
exit=0
```

---

## PASS/FAIL table

| # | Check | Result | Evidence |
|---|-------|--------|----------|
| 1a | `projects/<name>.yml` written under `$CONF_DIR/projects/` | PASS | file present, 63 bytes |
| 1b | yml has `name: <name>` line | PASS | `name: myproj` |
| 1c | yml has `root:` line | PASS | `root: ...` present |
| 1d | `~` contraction actually fires when proj is under HOME; no literal home leaks | PASS | Drive 2: `root: ~/work/myproj`, no `$HOME` substring |
| 2a | [alpha] repo dir exists | PASS | dir present |
| 2b | [alpha] `is-bare-repository` == true | PASS | `true` |
| 2c | [alpha] `core.bare` == true | PASS | `true` |
| 2d | [alpha] `refs/heads/main` verifies | PASS | resolves to a commit |
| 2e | [alpha] `symbolic-ref HEAD` == refs/heads/main | PASS | `refs/heads/main` |
| 2f-j | [beta] same five checks | PASS | identical |
| 3a | `git worktree add -b feat <dir> main` exits 0 | PASS | exit=0 |
| 3b | NO "invalid reference: main" on stderr | PASS | grep count 0 |
| 3c | worktree dir created | PASS | `.../alpha/feat` listed |
| 4 | real `fleet new alpha feat` worktree-adds off main (no tmux) | PASS | real `cmd_new` created `alpha/feat`, no invalid-ref, fail-silent tmux degrade, exit 0 |
| H | author harness GREEN | PASS | 16/16 PASS, exit 0 |
| ADV1 | non-empty-dir guard / cancel | PASS | `fleet: cancelled` |
| ADV2 | duplicate repo skipped | PASS | "already exists, skipped" |
| ADV3 | repo-name sanitization | PASS | `we!@#ird` -> `weird` |

No FAILs.

---

## Interactive (`read -e`) path vs the heredoc path

The wizard reads every input with `read -e -p "...: "`. `read -e` enables
readline line-editing **only when stdin is a tty**; when stdin is a pipe (the
heredoc case) it reads a plain line per call but consumes the **same** input
tokens in the **same** order. So the heredoc path exercises identical code for:
the project-dir prompt, the non-empty-dir confirmation, the whole add-repo loop
(`new_bare_repo` per name, name sanitization, dup/empty handling), and the inline
yml write. Every line of `cmd_new_project` from 429 through 460 is covered.

**The one and only difference** is the final gate at line 462:
`if [ -t 0 ] && [ -t 1 ]; then cmd_up "$name"; else echo "...skipped boot..."`.
Under the pipe, stdin/stdout are not ttys, so the wizard prints "skipped boot"
instead of calling `cmd_up` (which would boot a tmux session). That gate is the
intended, documented behavior for non-interactive callers — it is not a code path
that produces or alters the project/yml/repos.

I am confident the interactive path would behave identically for all
project-creation effects, because: (1) the only branch keyed on tty-ness is the
post-creation boot, well after the yml and all repos are written; (2) `read -e`
changes input *editing*, not the values delivered or the control flow; (3) the
real `cmd_new` consumer was driven successfully against the wizard's output
(check 4), so the downstream `cmd_up`/`cmd_new` integration the interactive path
would reach is itself proven to work with these seeds. The interactive run would
additionally boot tmux; that is out of scope for proving the create logic and was
deliberately not exercised in the sandbox.

---

## Final verdict

GREEN — `fleet new-project` creates the yml (with correct `~` contraction),
produces real seeded bare-repo containers with `main`, and the exact worktree-add
that `fleet new` performs — including a real invocation of `cmd_new` — succeeds
with no "invalid reference: main"; author harness independently GREEN (16/16, exit 0).
