#!/usr/bin/env bash
# guard-quoted-payload-proof.sh — fleet-guard: EXECUTED command vs INERT argument.
#
# Two directions, both load-bearing:
#   A. ALLOW  — the denied verbs merely MENTIONED inside a quoted -p/-m payload
#               (and other inert positions) must not deny. These are the false
#               positives that taught operators to route around the guard.
#   B. DENY   — every construct that turns text back INTO an executed command must
#               still deny: direct, chained, piped, substituted ($(…)/backticks,
#               including inside DOUBLE quotes where they really do run), eval,
#               sh -c, xargs, transparent prefixes, shell keywords, an expanded
#               variable, and an unbalanced-quote parse failure (fail CLOSED).
#
# Group B is the half that must FAIL against pre-fix code — run:
#   GUARD=<old checkout>/bin/fleet-guard test/guard-quoted-payload-proof.sh
#
# Isolation: no tmux, no daemon, no live config. fleet-guard is direct-invoked
# with synthesized PreToolUse JSON on stdin and XDG_CONFIG_HOME pointed at a
# mktemp -d we created and are the only remover of. The always-on merge/push
# block does not consult the guard-on marker, so the live one is never read.
set -u

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
GUARD=${GUARD:-$HERE/../bin/fleet-guard}
[ -x "$GUARD" ] || { echo "no such guard: $GUARD" >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fleet-guard-proof.XXXXXX") || exit 2
cleanup() { [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf -- "$TMP"; }   # only ours
trap cleanup EXIT INT TERM
export XDG_CONFIG_HOME="$TMP/config"
mkdir -p "$XDG_CONFIG_HOME"

pass=0; fail=0

# verdict <command> [env...] -> ALLOW|DENY
verdict() {
  local out cmd=$1; shift
  out=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$cmd" "$TMP" \
        | env FLEET_ROLE=worker "$@" "$GUARD" 2>/dev/null)
  case "$out" in *'"deny"'*) echo DENY ;; *) echo ALLOW ;; esac
}

check() { # check <ALLOW|DENY> <label> <command> [env...]
  local want=$1 label=$2 cmd=$3 got; shift 3
  got=$(verdict "$cmd" "$@")
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf '  ok   %-6s %s\n' "$want" "$label"
  else
    fail=$((fail+1)); printf '  FAIL want=%s got=%s  %s\n      cmd: %s\n' "$want" "$got" "$label" "$cmd"
  fi
}

echo "== A. inert payload / non-integration git -> ALLOW =="
check ALLOW "the reported bug: fleet new -p mentioning 'git merge'" \
  'fleet new fleet b --bare --self-merge --task impl -p "commit, then the orchestrator will git merge it"'
check ALLOW "fleet inbox put -m body mentioning 'git push'" \
  'fleet inbox put --to main -m "done; do not git push, orchestrator lands it"'
check ALLOW "fleet send body with separators inside the quotes" \
  'fleet send main "step 1; step 2 && git push -- do NOT run this"'
check ALLOW "verb inside a single-quoted payload" \
  "fleet new fleet b -p 'never run git merge yourself'"
check ALLOW "substitution syntax inside SINGLE quotes is inert" \
  "fleet new fleet b -p 'literally \$(git push) as text'"
check ALLOW "backtick body that is not git" \
  'fleet new fleet b -p "run `fleet ready` when done, never git push"'
# `git commit` is itself denied for workers now (no-auto-commit, d31), so the
# inert-mention intent is carried on a still-allowed verb; the commit form is
# asserted separately with the documented escape hatch on.
check ALLOW "the verb inside a -m message payload" \
  'git stash push -m "explain why we do not git push here"'
check ALLOW "the verb inside a commit message (fleet autocommit on)" \
  'git commit -m "explain why we do not git push here"' FLEET_AUTOCOMMIT=1
check ALLOW "harmless git subcommands still work" 'git status'
check ALLOW "harmless git subcommands still work (log)" 'git log --oneline -5'
check ALLOW "git word in a heredoc that is only WRITTEN to a file" \
  "$(printf 'cat > notes.md <<%s\nask the orchestrator to git merge this\n%s\n' EOF EOF)"

echo "== A2. MULTI-LINE quoted payload -> ALLOW (must fail pre-fix) =="
# A newline INSIDE a quoted payload is data. Pre-fix, scan_text split the text on
# "\n" before tokenizing, so each fragment had unbalanced quotes and an indented
# payload line read as a command word -> false DENY. Multi-line -p prompts are the
# normal shape of `fleet new`.
check ALLOW "multi-line -p, indented verb line" \
  "$(printf 'fleet new fleet b -p "line one\n  git push\nline three"\n')"
check ALLOW "multi-line -m with a blank line" \
  "$(printf 'fleet inbox put -m "summary\n\n  git -C /tmp push\n"\n')"
check ALLOW "multi-line payload with embedded single quotes" \
  "$(printf 'fleet send main "don'\''t do this:\n  git merge main\nask me instead"\n')"
check ALLOW "multi-line single-quoted payload" \
  "$(printf "fleet new fleet b -p 'plan:\n  1. stage\n  2. never git push\n'\n")"
check ALLOW "multi-line payload containing separators and a substitution" \
  "$(printf 'fleet send main "step 1; step 2 && git push\nand \$(git merge x) is text\n"\n')"
check ALLOW "multi-line payload with a trailing real command that is harmless" \
  "$(printf 'fleet send main "a\n  git push\nb"\ngit status\n')"
check ALLOW "multi-line payload followed by a comment line" \
  "$(printf 'fleet send main "a\n  git push\nb"   # note about git merge\necho done\n')"

echo "== B. executed command -> DENY (this half must fail pre-fix) =="
check DENY "direct" 'git merge main'
check DENY "direct push" 'git push origin HEAD'
check DENY "quoted command word" '"git" push'
check DENY "quoted subcommand" "git 'push' origin"
check DENY "extra spacing" 'git    push'
check DENY "absolute path" '/usr/bin/git push'
check DENY "git -C elsewhere" 'git -C ../other push'
check DENY "env-assign prefix" 'GIT_DIR=.git git push'
check DENY "; chain" 'echo hi; git push'
check DENY "&& chain" 'git commit -am x && git push'
check DENY "|| chain" 'git push || true'
check DENY "background &" 'git push &'
check DENY "pipe" 'git push | tee log'
check DENY "newline-separated" "$(printf 'echo a\ngit merge main\n')"
check DENY '$( ) substitution' 'X=$(git merge main)'
check DENY '$( ) inside double quotes REALLY runs' 'echo "out: $(git push)"'
check DENY 'nested $( )' 'echo $(echo $(git merge x))'
check DENY "backticks" '`git push`'
check DENY "backticks inside double quotes" 'echo "out: `git push`"'
check DENY "eval" 'eval "git push"'
check DENY "eval, args split across words" 'eval git push origin'
check DENY "sh -c" 'sh -c "git merge x"'
check DENY "bash -lc" 'bash -lc "git push"'
check DENY "sh -c wrapping eval" 'sh -c "eval \"git push\""'
check DENY "xargs" 'echo main | xargs git push origin'
check DENY "xargs with options" 'echo x | xargs -r -n1 git merge'
check DENY "env prefix" 'env FOO=1 git push'
check DENY "timeout prefix (drops its duration operand)" 'timeout 30 git push'
check DENY "nohup prefix" 'nohup git push'
check DENY "sudo prefix" 'sudo git merge x'
check DENY "command builtin" 'command git push'
check DENY "then keyword" 'if true; then git merge x; fi'
check DENY "do keyword" 'for f in a b; do git push; done'
check DENY "while/do" 'while true; do git merge x; done'
check DENY "brace group" '{ git push; }'
check DENY "subshell" '(cd .. && git push)'
check DENY "variable expanded into command position" 'V="git push"; $V'
check DENY "variable expanded, braced" 'V="git merge x"; ${V}'
check DENY "heredoc fed to a shell (the lines ARE the script)" \
  "$(printf 'sh <<%s\ngit push\n%s\n' EOF EOF)"
# The multi-line REAL SCRIPT: looks like the payload case above, is not. A quoted
# multi-line argument on one statement must not launder a genuine command on the
# next line — this is the case the A2 fix is most likely to break.
check DENY "multi-line script: quoted arg first, real verb on its own line" \
  "$(printf "printf 'a\\\\nb\\\\n'\ngit push\n")"
check DENY "multi-line script: MULTI-LINE quoted arg, then real verb" \
  "$(printf 'printf "a\nb\n"\ngit push origin HEAD\n')"
check DENY "multi-line script: indented real verb after a plain line" \
  "$(printf 'cd repo\n  git merge main\n')"
check DENY "multi-line script: verb after a comment line" \
  "$(printf '# git push is what we avoid\ngit push\n')"
check DENY "multi-line script: verb inside a multi-line if block" \
  "$(printf 'if true\nthen\n  git push\nfi\n')"
check DENY "multi-line script: verb in a substitution spanning lines" \
  "$(printf 'X=$(cd repo &&\n  git merge main)\n')"
check DENY "multi-line script: verb after a line-continuation" \
  "$(printf 'echo a \\\\\n  && git push\n')"
check DENY "multi-line script: sh -c with a multi-line body" \
  "$(printf 'sh -c "echo a\ngit push"\n')"
check DENY "multi-line payload closed early, verb on next line" \
  "$(printf 'fleet send main "a\nb"\ngit merge main\n')"
check DENY "unbalanced quote across lines falls CLOSED" \
  "$(printf 'fleet send main "a\n  git push\n')"
check DENY "unbalanced quote falls CLOSED" 'git push "'
check DENY "unbalanced quote, verb mid-line" 'echo " ; git merge main'

echo "== C. exemptions and scope are unchanged =="
c_exempt=$(python3 -c 'import json;print(json.dumps({"tool_name":"Bash","tool_input":{"command":"git push"},"cwd":"/tmp"}))' \
           | FLEET_ROLE=worker FLEET_SELF_MERGE=1 "$GUARD" 2>/dev/null)
case "$c_exempt" in *'"deny"'*) fail=$((fail+1)); echo "  FAIL --self-merge worker was denied" ;;
  *) pass=$((pass+1)); echo "  ok   ALLOW  FLEET_SELF_MERGE=1 worker may push" ;; esac

c_orch=$(python3 -c 'import json;print(json.dumps({"tool_name":"Bash","tool_input":{"command":"git push"},"cwd":"/tmp"}))' \
         | FLEET_ROLE=main "$GUARD" 2>/dev/null)
case "$c_orch" in *'"deny"'*) fail=$((fail+1)); echo "  FAIL orchestrator was denied" ;;
  *) pass=$((pass+1)); echo "  ok   ALLOW  non-worker role is untouched" ;; esac

c_tool=$(python3 -c 'import json;print(json.dumps({"tool_name":"Read","tool_input":{"command":"git push"},"cwd":"/tmp"}))' \
         | FLEET_ROLE=worker "$GUARD" 2>/dev/null)
case "$c_tool" in *'"deny"'*) fail=$((fail+1)); echo "  FAIL non-Bash tool was denied" ;;
  *) pass=$((pass+1)); echo "  ok   ALLOW  non-Bash tool is untouched" ;; esac

# fail-silent: garbage stdin, empty stdin, no stdin must all exit 0 and say nothing
for bad in '' 'not json at all' '{"tool_name":'; do
  out=$(printf '%s' "$bad" | FLEET_ROLE=worker "$GUARD" 2>/dev/null); rc=$?
  if [ $rc -eq 0 ] && [ -z "$out" ]; then
    pass=$((pass+1)); echo "  ok   fail-silent on malformed stdin"
  else
    fail=$((fail+1)); echo "  FAIL malformed stdin rc=$rc out=$out"
  fi
done

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
