# PLAN — `--dry-run` for widget sync

## Status
APPROVED — verdict BUILD (see SYNTHESIS.md). Traversal is explicitly out of scope per the
instruction: `widgets/*` stays single-level. Everything below is specified and unblocked;
GATE 1 was posted and popped, and this dispatch is at the `impl` rung.

## Scope of change (4 edits to sync.sh, 1 new file)
1. `sync.sh:5` — replace bare `sync_all` with `[ "${SYNC_LIB:-}" = 1 ] || main "$@"`.
   This is a prerequisite, not part of the flag: today the file runs a full sync on `.` /source,
   so any harness that sources it has already synced before asserting anything.
2. New `main()` — POSIX `while [ $# -gt 0 ]; do case $1 in --dry-run) DRY_RUN=1 ;; --) shift; break ;;
   -*) usage >&2; exit 2 ;; *) break ;; esac; shift; done`. Not `getopts`: no long-option support.
3. `sync.sh:3` `sync_all()` — enumeration. Rewritten per the nesting decision (see Open decision).
   Regardless of decision: explicit `[ -d widgets ] || { echo "no widgets/ tree" >&2; exit 1; }`,
   `[ -e "$w" ] || continue`, and `LC_ALL=C sort` for deterministic order.
4. `sync.sh:4` `push()` — dry-run guard as the FIRST line of the body, before any future
   transport call: `[ "$DRY_RUN" = 1 ] && { printf 'would push %s\n' "$1"; return 0; }`.
   State reaches `push` via a global `DRY_RUN` (`local` is not POSIX; surface is 2 functions).
5. New `tests.sh` — POSIX, no deps, `mktemp -d` fixtures, `trap` cleanup, ~30 lines.

## Output contract
- Dry run: `would push <path>` per widget, stdout, exit 0. Wet run: `pushing <path>`.
- Distinct verb, not a `[dry-run]` prefix on the same word — a prefix invites an assertion that
  also passes against a real push.
- One printed line == exactly one push. This is the invariant the tests exist to protect.

## The vacuity problem (CON's central objection) and how the plan answers it
`push` is a printf stub. It has no side effect to suppress, so "dry-run wrote nothing" is
VACUOUSLY true — the wet path also writes nothing. Accepted as correct. Mitigation, not denial:
- Do NOT ship any "asserted no writes" test. It would pass forever and prove nothing.
- Test the *observable* difference instead: verb, exact line set, exit code, ordering, one-line-
  per-widget cardinality. These are falsifiable today.
- Ship a fake transport in the harness (`push_transport()` overridden in the sourced test env to
  append to a temp file) so "wrote nothing" becomes a real assertion against a real writer.
  This requires `push` to delegate its write to a named function — the seam that makes the guard
  meaningful. Without it, defer the no-write test rather than fake-pass it.

## Settled decision (was blocking, answered at GATE 1)
Nesting. Readings 1/2/3 (leaf / all-nodes / composite) share the identical layout `widgets/a/b`
and demand three different outputs (`b` / `a`+`b` / `a`), and none is derivable from the repo.
The human answered at GATE 1: traversal is OUT OF SCOPE — `widgets/*` stays single-level, and
the "nested-widget edge case" clause is dropped from the instruction explicitly. No recursion
ships in this change.

## Traversal hazards (recorded for the FUTURE change that adds recursion; not this one)
`find -P` + `-maxdepth` (symlink cycles); `-print0` (newlines in names); note `widgets/*` skips
dotfiles but `find` does not — silent divergence from today; explicit sort (find is inode-order,
tests go flaky otherwise); decide whether empty dirs count as leaves.
