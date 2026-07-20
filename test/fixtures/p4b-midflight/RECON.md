# RECON — `--dry-run` for widget sync

## Where the feature lives
- `repo/sync.sh` — the entire tool, 5 lines. Only executable file in the repo.
- `repo/sync.sh:3` `sync_all() { for w in widgets/*; do push "$w"; done; }` — enumeration.
- `repo/sync.sh:4` `push() { printf 'pushing %s\n' "$1"; }` — the "write" side.
- `repo/sync.sh:5` bare top-level `sync_all` call; runs on source/exec, unconditionally.
- `repo/README.md:1` — one sentence, no usage/flags section (contains typo "recieve").

## What already exists that the feature touches
- Arg parsing: **does not exist.** No `$1`/`getopts`/`case`/`shift` anywhere. `--dry-run` has no
  place to attach; the script ignores argv entirely.
- `widgets/` directory: **does not exist** on disk. The glob `widgets/*` is unquoted and
  unguarded, so with `sh` nullglob-off semantics it expands to the literal string `widgets/*`
  and `push` prints `pushing widgets/*` — one bogus line, exit 0. No failure signal today.
- Test harness: **does not exist.** No test file, no `tests/`, no CI config, no Makefile,
  no package manifest, no shellcheck config. Repo is exactly 2 files.
- Existing dry-run / verbose / log-level concept: **does not exist.** No env vars, no flags.
- Separation of "decide what to push" from "push it": partially there already — `sync_all`
  enumerates, `push` performs — which is the only existing seam.

## Two facts that most reframe the work
1. **Enumeration is a single-level glob (`widgets/*`), not a recursive walk.** The
   "nested-widget edge case" is therefore not a bug in a traversal — there is no traversal.
   A nested widget at `widgets/a/b` is never reached; `widgets/a` is pushed as one opaque item.
   Whatever "nested widget" is supposed to mean is undefined by the code and undefined by the
   README. This is a spec gap, not an implementation detail.
2. **There is no test infrastructure of any kind, and no runner to hook into.** "Ship with
   tests" means standing up a harness from zero, and the current entrypoint (line 5 executing
   on load) makes the script hard to source for testing without also running a sync.

## BUDGET SPENT
3 read-only calls (find/ls sweep, `cat` of both files, this write); 2 repo files read: `sync.sh`, `README.md`.
