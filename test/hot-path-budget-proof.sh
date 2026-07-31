#!/usr/bin/env bash
# hot-path-budget-proof — the lazy-promote prologue did not tax the hot path.
#
# PROOF DESIGN §4. `fleet-guard` fires on EVERY PreToolUse; `fleet-hook` fires on
# every state transition. Measured before this change: guard ≈15 ms, hook idle
# ≈0.9 ms on its fast path. A wrapper PROCESS was measured at +0.60 ms and
# rejected on that number alone (+88% of the hook's fast path), so the prologue
# is inline and pure builtins.
#
# SOFT by default, in keeping with house style: it REPORTS the numbers and only
# fails on a gross regression, because "we added an invisible 5 ms to every tool
# call" is exactly how this design would fail quietly. Set STRICT=1 to make the
# budget assertions hard.
set -u
. "$(dirname "$0")/hidden-proof-common.sh"
proof_isolate

STRICT="${STRICT:-0}"
N="${N:-20}"

REL="$TMPROOT/rel"; SRC="$TMPROOT/src"; mkdir -p "$SRC"
tar -C "$FLEET_REPO" --exclude=.git --exclude=node_modules -cf - . 2>/dev/null \
  | tar -C "$SRC" -xf - 2>/dev/null
export FLEET_RELEASE_DIR="$REL"
"$SRC/bin/fleet" promote >/dev/null 2>&1 || { echo "setup: promote failed" >&2; exit 1; }

PAY='{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'

ms_per() { # ms_per <n> <command...> — wall-clock ms per iteration
  local n="$1"; shift
  local t0 t1
  t0=$(date +%s%N)
  local i; for i in $(seq "$n"); do "$@" >/dev/null 2>&1 || true; done
  t1=$(date +%s%N)
  awk -v a="$t0" -v b="$t1" -v n="$n" 'BEGIN{printf "%.2f", (b-a)/n/1000000}'
}
ms_per_stdin() { # same, feeding the hook payload on stdin
  local n="$1"; shift
  local t0 t1
  t0=$(date +%s%N)
  local i; for i in $(seq "$n"); do printf '%s' "$PAY" | "$@" >/dev/null 2>&1 || true; done
  t1=$(date +%s%N)
  awk -v a="$t0" -v b="$t1" -v n="$n" 'BEGIN{printf "%.2f", (b-a)/n/1000000}'
}
under() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 <= b+0)}'; }

report() { # report <label> <measured> <budget>
  local label="$1" got="$2" budget="$3"
  printf '      %-46s %8s ms   (budget %s ms)\n' "$label" "$got" "$budget"
  if under "$got" "$budget"; then ok "$label within budget ($got ms)"
  elif [ "$STRICT" = 1 ]; then no "$label OVER budget ($got ms > $budget ms)"
  else printf 'WARN  %s over budget (%s ms > %s ms) — soft, see STRICT=1\n' "$label" "$got" "$budget"
  fi
}

section "steady state — release current, nothing to promote"

# Baseline: the SAME binaries with the prologue disabled outright. The absolute
# numbers move with machine load; the DELTA is what this proof actually owns.
base_guard=$(ms_per_stdin "$N" env FLEET_NO_PROMOTE=1 sh "$REL/current/bin/fleet-guard")
base_hook=$(ms_per "$N" env FLEET_NO_PROMOTE=1 sh "$REL/current/bin/fleet-hook" idle)
live_guard=$(ms_per_stdin "$N" sh "$REL/current/bin/fleet-guard")
live_hook=$(ms_per "$N" sh "$REL/current/bin/fleet-hook" idle)

printf '      %-46s %8s ms\n' "fleet-guard, prologue disabled" "$base_guard"
printf '      %-46s %8s ms\n' "fleet-hook idle, prologue disabled" "$base_hook"
report "fleet-guard (steady state)" "$live_guard" 20.00
report "fleet-hook idle (steady state)" "$live_hook" 3.00

d_guard=$(awk -v a="$live_guard" -v b="$base_guard" 'BEGIN{printf "%.2f", a-b}')
d_hook=$(awk -v a="$live_hook" -v b="$base_hook" 'BEGIN{printf "%.2f", a-b}')
printf '      %-46s %8s ms\n' "prologue delta, fleet-guard" "$d_guard"
printf '      %-46s %8s ms\n' "prologue delta, fleet-hook" "$d_hook"
# The rejected wrapper-process design cost +0.60 ms. Inline builtins must be a
# small fraction of that; 0.40 ms leaves room for a loaded machine.
report "prologue delta, fleet-guard" "$d_guard" 0.40
report "prologue delta, fleet-hook" "$d_hook" 0.40

section "the steady state really is steady (no promote fired)"

before=$(readlink "$REL/current")
for i in 1 2 3 4 5; do printf '%s' "$PAY" | sh "$REL/current/bin/fleet-guard" >/dev/null 2>&1; done
chk "no promote happened during the measurement" "$before" "$(readlink "$REL/current")"
n=$(command ls -1d "$REL"/rel-* 2>/dev/null | wc -l)
chk "exactly one release tree exists (nothing churned)" 1 "$n"

section "no forks on the steady-state prologue path"

# The design claim is 'two stats, no fork'. strace makes it checkable rather than
# asserted; skipped (not failed) when strace is unavailable or restricted.
if command -v strace >/dev/null 2>&1 && strace -f -e trace=none true >/dev/null 2>&1; then
  n=$(printf '%s' "$PAY" | strace -f -e trace=execve -o "$TMPROOT/st.txt" \
        sh "$REL/current/bin/fleet-guard" >/dev/null 2>&1; grep -c execve "$TMPROOT/st.txt" || true)
  base=$(printf '%s' "$PAY" | strace -f -e trace=execve -o "$TMPROOT/st0.txt" \
        env FLEET_NO_PROMOTE=1 sh "$REL/current/bin/fleet-guard" >/dev/null 2>&1; grep -c execve "$TMPROOT/st0.txt" || true)
  printf '      execve count: %s with prologue, %s without\n' "$n" "$base"
  [ "${n:-99}" -le "$((${base:-0} + 1))" ] \
    && ok "prologue adds no process spawns in the steady state" \
    || no "prologue adds process spawns ($n vs $base execve)"
else
  printf 'SKIP  strace unavailable — the syscall-level fork check did not run\n'
fi

# Source-level backstop for the same claim, and the one that always runs: the
# steady-state prologue must contain no command substitution, no pipe and no
# external command — only `[`, `read` and `exec`. This is checkable without
# strace and fails loudly if someone later adds a `readlink`/`cat`/`date` to it.
for f in fleet-guard fleet-hook; do
  body=$(awk '/^# ---- lazy promote/,/^fi$/' "$REL/current/bin/$f" | grep -v '^ *#')
  [ -n "$body" ] || { no "[$f] prologue located in the source"; continue; }
  ok "[$f] prologue located in the source"
  # `||` is not a pipe — strip the logical operators before looking for one, or
  # every fail-silent `|| true` reads as a fork.
  scan=$(printf '%s\n' "$body" | sed 's/||//g; s/&&//g')
  if printf '%s\n' "$scan" | grep -qE '\$\(|`|\||readlink|dirname|basename|sed |awk |cat |date '; then
    no "[$f] prologue forks in the steady state: $(printf '%s\n' "$scan" | grep -nE '\$\(|`|\|' | head -1)"
  else
    ok "[$f] prologue is fork-free (no command substitution, pipe or external command)"
  fi
done

section "the promote path costs what it costs — but only once per save"

touch "$SRC/bin/fleet-guard"
t0=$(date +%s%N)
printf '%s' "$PAY" | sh "$REL/current/bin/fleet-guard" >/dev/null 2>&1
t1=$(date +%s%N)
promote_ms=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", (b-a)/1000000}')
printf '      %-46s %8s ms\n' "first guard call after a save (promotes)" "$promote_ms"
chk_ne "that call did promote" "$before" "$(readlink "$REL/current")"
after=$(readlink "$REL/current")
now=$(ms_per_stdin "$N" sh "$REL/current/bin/fleet-guard")
printf '      %-46s %8s ms\n' "guard, back in steady state" "$now"
chk "and then stops promoting (validation is per-SAVE, not per-call)" "$after" "$(readlink "$REL/current")"
report "guard after the promote (steady again)" "$now" 20.00

section "the FAILED-GATE steady state — the degraded mode is the incident mode"

# The trigger `source -nt .stamp` stays true for as long as the worktree is
# broken. Without a negative cache, EVERY PreToolUse of EVERY agent re-runs the
# whole gate (~30-file copy, bash -n over 6.5k lines, a python AST walk, three
# smoke subprocesses) for as long as the merge is unresolved — i.e. worst exactly
# when things are already going wrong. The drift marker is the cache: retry only
# once the source changes again.
printf '<<<<<<< HEAD\nx=1\n=======\nx=2\n>>>>>>> other\n' >> "$SRC/bin/fleet-guard"
printf '%s' "$PAY" | sh "$REL/current/bin/fleet-guard" >/dev/null 2>&1   # first try: refuses
[ -f "$REL/drift" ] && ok "the gate refused and left a drift marker" \
                    || no "the gate refused and left a drift marker"
broken=$(ms_per_stdin "$N" sh "$REL/current/bin/fleet-guard")
printf '      %-46s %8s ms\n' "guard while the worktree is BROKEN" "$broken"
report "guard while the worktree is broken" "$broken" 20.00
# HARD, unlike the timing budgets: this asserts the negative cache EXISTS, not
# that the machine was fast. Without it the same call runs a full gate (measured
# ~88 ms against ~15 ms healthy), so a 2x ceiling has enormous headroom and still
# catches the regression.
ceil=$(awk -v b="$live_guard" 'BEGIN{printf "%.2f", (b+0)*2}')
under "$broken" "$ceil" \
  && ok "the failed gate is NOT re-run on every call (${broken} ms <= ${ceil} ms)" \
  || no "the failed gate is re-run on every call (${broken} ms > ${ceil} ms) — negative cache gone"

# ...and it must still retry the moment the human touches the file again.
touch "$SRC/bin/fleet-guard"
before=$(readlink "$REL/current")
printf '%s' "$PAY" | sh "$REL/current/bin/fleet-guard" >/dev/null 2>&1
chk "a still-broken source is still refused" "$before" "$(readlink "$REL/current")"
sed -i '/^<<<<<<< HEAD$/,/^>>>>>>> other$/d' "$SRC/bin/fleet-guard"
printf '%s' "$PAY" | sh "$REL/current/bin/fleet-guard" >/dev/null 2>&1
chk_ne "and promotes again once the human fixes it" "$before" "$(readlink "$REL/current")"

section "the hook protocol survives a promote+re-exec"

# The promote branch runs a gate, tar, git and three smoke subprocesses before
# the re-exec. The claim in the source is that the PreToolUse protocol is
# byte-identical whether or not that happened — so assert the DENY still lands,
# not merely that the exit code is 0.
PUSH='{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
out=$(printf '%s' "$PUSH" | FLEET_ROLE=worker sh "$REL/current/bin/fleet-guard" 2>/dev/null)
case "$out" in *'"deny"'*) ok "steady state: a worker git push is denied" ;;
               *) no "steady state: a worker git push is denied (got: ${out:-<empty>})" ;; esac
touch "$SRC/bin/fleet-guard"                       # force the promote branch
before=$(readlink "$REL/current")
out=$(printf '%s' "$PUSH" | FLEET_ROLE=worker sh "$REL/current/bin/fleet-guard" 2>/dev/null); rc=$?
chk "promote branch: exit code unchanged" 0 "$rc"
chk_ne "promote branch: a promote really did happen" "$before" "$(readlink "$REL/current")"
case "$out" in *'"deny"'*) ok "promote branch: the deny SURVIVES the promote+re-exec" ;;
               *) no "promote branch: the deny survives the promote+re-exec (got: ${out:-<empty>})" ;; esac
err=$(printf '%s' "$PUSH" | FLEET_ROLE=worker sh "$REL/current/bin/fleet-guard" 2>&1 >/dev/null | wc -c)
chk "promote branch: nothing leaked to stderr" 0 "$err"

proof_summary
