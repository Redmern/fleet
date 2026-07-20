# Decision gate — `--dry-run` for widget sync, in plain English

## Where this stands
APPROVED at GATE 1 — you popped this and said build it. Nested/recursive widgets are out of
scope by your instruction, which is what unblocked it. Implementation is in progress.

## What we ARE building
- A real `--dry-run` flag. The script currently ignores its arguments entirely, so this is the
  first argument the tool has ever accepted. Unknown flags fail loudly instead of silently
  doing a full sync.
- A clear difference in output: `would push <thing>` for a dry run, `pushing <thing>` for a real
  one. Different word, not a prefix, so a test cannot accidentally pass against a real push.
- The dry-run check sits as the first line of the push function, so whenever someone adds real
  network or disk code, it lands *behind* the guard and is automatically covered.
- Two honest bug fixes we found along the way: the tool currently prints `pushing widgets/*` —
  a widget that does not exist — because there is no `widgets/` folder; and the script performs
  a full sync merely by being loaded, which would sabotage the tests.
- A small test file, plain shell, no new dependencies.

## What we are NOT building, and why
- Any test asserting "dry run wrote nothing." The push function is currently a `printf` stub —
  it writes nothing either way, so that test passes forever while proving nothing. We would
  rather ship no test than a green light that never turns red.
- Manifest files, marker files, or a config format for widgets. None exists; inventing one to
  settle a traversal question is a bigger change than the flag itself.
- The recursive folder walk. Out of scope by your instruction: `widgets/*` stays single-level.

## Proof design (how we'd actually prove it works)
We build a throwaway `widgets/` folder per test, run the tool, and compare the complete output
line-for-line against an expected list. Complete, not "contains" — a missing or duplicated
widget fails. We check the exit code, and we check that the number of printed lines exactly
equals the number of widgets, which is what catches a parent and child both being pushed.
Avoiding the vacuous trap: instead of asserting an absence that is already true, we assert the
things that are actually different today — the verb, the exact line set, the ordering, the
count. If you want a genuine "wrote nothing" test, we make the push function delegate its write
to a separate function that the test replaces with one that logs to a file. Then "nothing was
written" is a real claim about a real writer. That is a small extra edit; say the word.

## The question that was asked, and your answer
**Q1 — nested widgets.** Given `widgets/a/b`, what should `--dry-run` print? You answered
**(D) Not now**: leave the folder walk alone and ship the flag against the current single-level
behaviour. Output for the example is `widgets/a`, and "cover the nested-widget edge case" is
dropped from the instruction explicitly rather than silently.

**Q2 — empty folders and dotfiles.** Defaults accepted: empty folders under `widgets/` are not
widgets and are skipped; hidden files stay skipped, as today's code already does.

With Q1 answered, GATE 1 was approved and this dispatch moved to the `impl` rung.
