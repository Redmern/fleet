BUILD

## Why BUILD
The instruction scopes traversal OUT explicitly (`widgets/*` stays single-level), which removes
the one genuinely undecidable question in this feature. What remains is fully specified by the
repo: there is no arg parsing today (`sync.sh:5` calls `sync_all` bare at load time), so the flag
needs a `main()` and a source-guard, and both are mechanical. Two lenses agreed the frame is
worth building now: the repo is 5 lines with no legacy to fight, and the `DRY_RUN` guard's
*placement* — before any future transport line — is the durable artifact, cheaper to place now
than to retrofit around a real writer later.

## The specific disagreement between lenses
PRO and CON collide on what the tests may claim. CON is right that while `push` is a `printf`
stub, a "dry-run wrote nothing" assertion passes VACUOUSLY and can never turn red — such a test
defends nothing and would be theater. PRO is right that the guard itself is still worth landing.

Resolution: ship the guard, and REFUSE to ship the vacuous test. Test what is falsifiable today —
the verb, the exact line set, the exit code, and one-line-per-widget cardinality. Defer
"wrote nothing" until a real writer exists, or introduce a delegated transport function the
harness can fake.

## Accepted scope
- `sync.sh:5` — source-guard, so sourcing no longer triggers a full sync (prerequisite: today it
  sabotages any harness that sources the file).
- New `main()` — POSIX arg loop, `--dry-run` and `--`, usage/exit 2 on unknown flags.
- `DRY_RUN` guard placed inside `push`, before the (future) transport line — not around the loop,
  so the traversal stays a single code path and dry-run cannot drift from real sync.
- `widgets/` existence check: today the glob does not expand and the literal `widgets/*` is
  passed to `push`. That is a live bug dry-run would otherwise surface as garbage output.
- Test harness (greenfield — no tests, no CI exist).

## Explicitly out of scope
- Recursive/nested traversal. `widgets/*` remains single-level, per the instruction.
- Making `push` real. That reorders the roadmap and is the human's call, not this plan's.

## What would change the verdict
- To REVISE: evidence that a real transport already exists somewhere and the guard belongs
  elsewhere in the call path.
- To REJECT: a decision that `push` must be made real first, which would make dry-run
  non-vacuous but is a different unit of work.
