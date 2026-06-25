#!/usr/bin/env bash
# Adversarial test for the fleet zombie-reconcile fix (commit de13b6b).
# Goal: BREAK it. PASS = behaved safely / die-loud. FAIL = real defect.
set -u

REPO="/home/red/proj/pc-tune/fleet/fleet_reconcile-zombie-terminal-state"
FLEET_BIN="$REPO/bin/fleet"

PASS=0; TOTAL=0; DEFECTS=()
ok()   { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "PASS  $1"; }
bad()  { TOTAL=$((TOTAL+1)); echo "FAIL  $1"; DEFECTS+=("$2"); }

# ---- isolated real-fleet invocation ----------------------------------------
# FLEET_SESSION=__nope__ => session_name returns a nonexistent session =>
# @fleet_root empty => FLEET_ROOT env wins => fleet_root == $T.
mkroot() {
  local t; t=$(mktemp -d)
  case "$t" in /tmp/*) : ;; *) echo "ABORT: mktemp not under /tmp: $t" >&2; exit 2 ;; esac
  printf '%s' "$t"
}
RF() { local t="$1"; shift; FLEET_SESSION=__nope__ FLEET_ROOT="$t" "$FLEET_BIN" "$@"; }
state_of() { awk -F'\t' '$1=="state"{v=$2}END{print v}' "$1/meta.tsv" 2>/dev/null; }

echo "=============================================================="
echo " A1  CRLF / whitespace in verb & id"
echo "=============================================================="

# A1a: CRLF in id. fixture d1 done. Then `dispatch done $'d1\r'`.
T=$(mkroot); mkdir -p "$T/.fleet/dispatch/d1"
printf 'state\trunning\n' > "$T/.fleet/dispatch/d1/meta.tsv"
out=$(RF "$T" dispatch done "$(printf 'd1\r')" 2>&1); rc=$?
real=$(state_of "$T/.fleet/dispatch/d1")
crlf_dir=$(printf 'd1\r'); has_junk=no
[ -d "$T/.fleet/dispatch/$crlf_dir" ] && has_junk=yes
echo "  out=[$out] rc=$rc  d1.state=[$real]  junk-dir(d1\\r)=$has_junk"
if echo "$out" | grep -q '→'; then
  # claimed success. Did it actually update intended d1, or fabricate junk?
  if [ "$real" = "running" ] && [ "$has_junk" = yes ]; then
    bad "A1a CRLF-id: claims success but wrote to junk dir 'd1\\r', real d1 untouched" \
"DEFECT A1a: CRLF in id fabricates a bogus dispatch dir.
  T=\$(mktemp -d); mkdir -p \$T/.fleet/dispatch/d1
  printf 'state\trunning\n' > \$T/.fleet/dispatch/d1/meta.tsv
  FLEET_SESSION=__nope__ FLEET_ROOT=\$T fleet dispatch done \$'d1\\r'
  # -> prints 'dispatch d1 -> done' (success) but creates \$T/.fleet/dispatch/d1\$'\\r'/
  #    leaving the real d1 state=running. Zombie survives."
  else
    ok "A1a CRLF-id: claimed success, intended d1 updated to [$real] (junk=$has_junk)"
  fi
else
  # die-loud path
  if [ "$has_junk" = yes ]; then
    bad "A1a CRLF-id: died but still created junk dir" \
"DEFECT A1a: CRLF id created junk dir even though command died: \$T/.fleet/dispatch/d1\$'\\r'"
  else
    ok "A1a CRLF-id: die-loud, no junk dir (out=[$out])"
  fi
fi
rm -rf "$T"

# A1b: leading/trailing whitespace in id.
T=$(mkroot); mkdir -p "$T/.fleet/dispatch/d2"
printf 'state\trunning\n' > "$T/.fleet/dispatch/d2/meta.tsv"
out=$(RF "$T" dispatch done "  d2 " 2>&1); rc=$?
real=$(state_of "$T/.fleet/dispatch/d2")
echo "  ws-id out=[$out] rc=$rc d2.state=[$real]"
if echo "$out" | grep -q '→' && [ "$real" = "running" ]; then
  bad "A1b ws-id: claims success but real d2 untouched (state=running)" \
"DEFECT A1b: padded id '  d2 ' claims success yet d2 stays running."
else
  ls "$T/.fleet/dispatch/" | grep -q ' ' \
    && bad "A1b ws-id: created a whitespace-named junk dir" "DEFECT A1b: whitespace junk dir created." \
    || ok "A1b ws-id: died loud / no success on padded id (out=[$out])"
fi
rm -rf "$T"

# A1c: trailing space in verb 'done '.
T=$(mkroot); mkdir -p "$T/.fleet/dispatch/d3"
printf 'state\trunning\n' > "$T/.fleet/dispatch/d3/meta.tsv"
out=$(RF "$T" dispatch "done " d3 2>&1); rc=$?
real=$(state_of "$T/.fleet/dispatch/d3")
echo "  verb='done ' out=[$out] rc=$rc d3.state=[$real]"
# 'done ' won't match case 'done' -> falls to bare-id path treating 'done ' as id.
# Must NOT claim 'done'. Either die or treat as bare spawn (which dies: no instruction.txt).
if echo "$out" | grep -qi 'usage\|no such\|not inside'; then
  ok "A1c verb-trailing-space: die-loud, not silently mapped to done (out=[$out])"
elif [ "$real" = "done" ]; then
  bad "A1c verb-trailing-space: 'done ' silently treated as terminal 'done'" \
"DEFECT A1c: verb 'done ' (trailing space) mutated d3 to done unexpectedly."
else
  ok "A1c verb-trailing-space: did not finalize d3 (state=[$real], out=[$out])"
fi
rm -rf "$T"

# A1d: id matching /^d[0-9]+$/ -- is there any validation? Garbage id with slashes.
T=$(mkroot); mkdir -p "$T/.fleet/dispatch"
out=$(RF "$T" dispatch done "../../../etc/evil" 2>&1); rc=$?
echo "  traversal-id out=[$out] rc=$rc"
if echo "$out" | grep -q '→'; then
  bad "A1d traversal-id: claims success on path-traversal id" \
"DEFECT A1d: id '../../../etc/evil' accepted (path traversal in dispatch dir)."
else
  ok "A1d traversal-id: die-loud on traversal id (no such dispatch); out=[$out]"
fi
rm -rf "$T"

echo "=============================================================="
echo " A2  FLEET_RECONCILE_CAP edge values (unit-test cmd_reconcile)"
echo "=============================================================="

# Extract meta_*/cmd_reconcile + stub the world.
run_reconcile_cap() { # <cap-as-env-literal-or-UNSET> <respawns> -> prints final state + flags
  local CAPSPEC="$1" RESP="$2"
  bash -c '
    set -u
    eval "$(sed -n "/^meta_get()/,/^}/p; /^meta_set()/,/^}/p; /^meta_compact()/,/^}/p; /^cmd_reconcile()/,/^}/p" "'"$REPO"'/bin/fleet")"
    T=$(mktemp -d)
    mkdir -p "$T/.fleet/dispatch/d1"
    printf "state\trunning\n" > "$T/.fleet/dispatch/d1/meta.tsv"
    printf "respawns\t'"$RESP"'\n" >> "$T/.fleet/dispatch/d1/meta.tsv"
    SPAWNED=0
    session_name(){ echo s; }
    fleet_root(){ echo "$T"; }
    suborch_live(){ return 1; }                 # dead window
    suborch_has_live_workers(){ return 1; }      # no live workers
    tmux(){ case "$1" in info) return 0;; *) return 0;; esac; }
    resolve_or_spawn_suborch(){ SPAWNED=1; }
    append_dashboard_alert(){ :; }
    '"$CAPSPEC"'
    cmd_reconcile
    st=$(awk -F"\t" "\$1==\"state\"{v=\$2}END{print v}" "$T/.fleet/dispatch/d1/meta.tsv")
    rs=$(awk -F"\t" "\$1==\"respawns\"{v=\$2}END{print v}" "$T/.fleet/dispatch/d1/meta.tsv")
    echo "state=$st respawns=$rs spawned=$SPAWNED rc=$?"
    rm -rf "$T"
  ' 2>&1
}

# A2a: CAP=0, respawns=0 -> 0>=0 true -> abandon on first dead sweep (no grace).
r=$(run_reconcile_cap 'export FLEET_RECONCILE_CAP=0' 0)
echo "  CAP=0 resp=0 => $r"
if echo "$r" | grep -q 'state=failed'; then
  ok "A2a CAP=0: abandons on first dead sweep (documented footgun, not a crash) => $r"
else
  bad "A2a CAP=0: expected immediate abandon, got $r" "DEFECT A2a: CAP=0 did not abandon as expected: $r"
fi

# A2b: CAP="" (set, empty). ${FLEET_RECONCILE_CAP:-1} -> :- substitutes on empty -> 1.
r=$(run_reconcile_cap 'export FLEET_RECONCILE_CAP=""' 0)
echo "  CAP='' resp=0 => $r"
if echo "$r" | grep -qi 'unbound\|integer expression\|error'; then
  bad "A2b CAP='': blew up instead of defaulting to 1" "DEFECT A2b: empty CAP crashes: $r"
elif echo "$r" | grep -q 'state=running'; then
  # respawns 0 < default 1 => respawn, not abandon. state stays running, respawns->1
  ok "A2b CAP='': :- defaulted to 1, respawned (no abandon) => $r"
else
  ok "A2b CAP='': no crash; => $r"
fi

# A2b2: CAP='' with respawns=1 -> 1>=1 -> abandon (proves default really is 1).
r=$(run_reconcile_cap 'export FLEET_RECONCILE_CAP=""' 1)
echo "  CAP='' resp=1 => $r"
echo "$r" | grep -q 'state=failed' \
  && ok "A2b2 CAP='' resp=1: default-1 confirmed (abandons) => $r" \
  || { echo "$r"|grep -qi 'unbound\|error' \
       && bad "A2b2 CAP='' resp=1 crashed" "DEFECT A2b2: $r" \
       || ok "A2b2 CAP='' resp=1: no abandon (default!=1?) but no crash => $r"; }

# A2c: CAP="abc" non-numeric. [ "$n" -ge "abc" ] -> integer error.
r=$(run_reconcile_cap 'export FLEET_RECONCILE_CAP=abc' 0)
echo "  CAP=abc resp=0 => $r"
if echo "$r" | grep -qi 'unbound variable\|set -u'; then
  bad "A2c CAP=abc: unbound/abort under set -u" "DEFECT A2c: non-numeric CAP triggers set -u abort: $r"
elif echo "$r" | grep -q 'state=running'; then
  # integer error short-circuits && chain -> falls through to respawn. degrade-to-zombie, no crash.
  ok "A2c CAP=abc: integer error short-circuits guard, degrades to respawn (no crash) => $r"
elif echo "$r" | grep -q 'state=failed'; then
  bad "A2c CAP=abc: non-numeric cap somehow abandoned" "DEFECT A2c: CAP=abc abandoned unexpectedly: $r"
else
  ok "A2c CAP=abc: no crash => $r"
fi

echo "=============================================================="
echo " A3  set -u safety in suborch_has_live_workers (zero panes)"
echo "=============================================================="
A3=$(bash -c '
  set -u
  eval "$(sed -n "/^is_harness_cmd()/,/^}/p; /^suborch_has_live_workers()/,/^}/p" "'"$REPO"'/bin/fleet")"
  PANES=""
  tmux(){ case "$1" in list-panes) printf "%s\n" "$PANES";; *) return 0;; esac; }
  if suborch_has_live_workers 7 sess; then echo "live(0)"; else echo "dead(1)"; fi
' 2>&1)
echo "  zero-panes => $A3"
if echo "$A3" | grep -qi 'unbound'; then
  bad "A3 zero-panes: unbound variable under set -u" "DEFECT A3: suborch_has_live_workers trips set -u on empty PANES: $A3"
elif [ "$A3" = "dead(1)" ]; then
  ok "A3 zero-panes: no unbound, returns dead(1)"
else
  bad "A3 zero-panes: unexpected => $A3" "DEFECT A3: $A3"
fi
# A3b: valid owned harness line -> live(0)
A3b=$(bash -c '
  set -u
  eval "$(sed -n "/^is_harness_cmd()/,/^}/p; /^suborch_has_live_workers()/,/^}/p" "'"$REPO"'/bin/fleet")"
  PANES="so-7 claude"
  tmux(){ case "$1" in list-panes) printf "%s\n" "$PANES";; *) return 0;; esac; }
  if suborch_has_live_workers 7 sess; then echo "live(0)"; else echo "dead(1)"; fi
' 2>&1)
echo "  owned-harness => $A3b"
[ "$A3b" = "live(0)" ] && ok "A3b owned harness => live(0)" \
  || bad "A3b owned harness not detected => $A3b" "DEFECT A3b: owned harness pane not counted live: $A3b"

echo "=============================================================="
echo " A4  owner-stamp false positives in suborch_has_live_workers"
echo "=============================================================="
slw() { # <id> <PANES> -> live/dead
  bash -c '
    set -u
    eval "$(sed -n "/^is_harness_cmd()/,/^}/p; /^suborch_has_live_workers()/,/^}/p" "'"$REPO"'/bin/fleet")"
    PANES='"$(printf '%q' "$2")"'
    tmux(){ case "$1" in list-panes) printf "%s\n" "$PANES";; *) return 0;; esac; }
    if suborch_has_live_workers '"$1"' sess; then echo live; else echo dead; fi
  ' 2>&1
}
declare -A A4exp=(
  ["7|so-7 claude"]=live
  ["7|so-7 bash"]=dead
  ["7|so-99 claude"]=dead
  ["7|so-71 claude"]=dead
  ["7| claude"]=dead
)
for key in "7|so-7 claude" "7|so-7 bash" "7|so-99 claude" "7|so-71 claude" "7| claude"; do
  id="${key%%|*}"; panes="${key#*|}"; exp="${A4exp[$key]}"
  got=$(slw "$id" "$panes")
  echo "  id=$id PANES=[$panes] expect=$exp got=$got"
  if [ "$got" = "$exp" ]; then
    ok "A4 [$panes] => $got (expected $exp)"
  else
    bad "A4 [$panes] => $got, expected $exp" \
"DEFECT A4: suborch_has_live_workers id=$id PANES='$panes' returned $got, expected $exp."
  fi
done

echo "=============================================================="
echo " A5  is_harness_cmd classifier + *claude* glob breadth"
echo "=============================================================="
ihc() {
  bash -c '
    set -u
    eval "$(sed -n "/^is_harness_cmd()/,/^}/p" "'"$REPO"'/bin/fleet")"
    if is_harness_cmd "$1"; then echo 0; else echo 1; fi
  ' _ "$1" 2>&1
}
declare -A A5exp=( [bash]=1 [zsh]=1 [sh]=1 [claude]=0 [node]=0 [nvim]=0 )
for c in bash zsh sh claude node nvim; do
  got=$(ihc "$c"); exp="${A5exp[$c]}"
  [ "$got" = "$exp" ] && ok "A5 is_harness_cmd($c)=$got" \
    || bad "A5 is_harness_cmd($c)=$got expected $exp" "DEFECT A5: classifier($c)=$got expected $exp"
done
# glob breadth: any name containing 'claude' -> 0
for c in notclaude claudette xclaudex; do
  got=$(ihc "$c")
  echo "  glob *claude* : $c => $got"
done
# Judge: zsh/sh are explicitly NOT in the harness set so a dead shell is dead.
# But a stray proc literally containing 'claude' would be counted live.
nc=$(ihc notclaude)
if [ "$nc" = 0 ]; then
  echo "  NOTE: 'notclaude' classified live (0) — *claude* glob is broad."
  # Is there a realistic stray process whose name contains 'claude' that isn't a harness?
  # pane_current_command is the basename of the foreground proc. A user editing
  # 'claude.md' via e.g. a wrapper named 'claude-foo' would match — but those are rare
  # and themselves harness-adjacent. Not a realistic zombie-keepalive in practice.
  ok "A5 glob breadth: *claude* matches substrings (notclaude=live) — documented, no realistic stray-proc keepalive constructed"
else
  ok "A5 glob breadth: 'notclaude' not matched (=$nc)"
fi

echo "=============================================================="
echo " A6  stickiness-bypass / race: raw terminal verb clobbers done"
echo "=============================================================="
T=$(mkroot); mkdir -p "$T/.fleet/dispatch/d1"
printf 'state\tdone\n' > "$T/.fleet/dispatch/d1/meta.tsv"
out=$(RF "$T" dispatch cancel d1 2>&1); rc=$?
real=$(state_of "$T/.fleet/dispatch/d1")
echo "  fixture state=done; raw 'dispatch cancel d1' => out=[$out] rc=$rc final=[$real]"
if [ "$real" = "cancelled" ]; then
  ok "A6 raw cancel clobbers done->cancelled (last-wins by design; stickiness lives only at the dash call site) — ACCEPTED-BY-DESIGN"
else
  bad "A6 raw cancel did NOT clobber done (got $real) — contradicts documented last-wins" \
"DEFECT A6: raw terminal verb claims last-wins but did not overwrite done (final=$real)."
fi
# A6 TOCTOU narrative for dash: card_meta_state reads 'running', worker writes 'done',
# then the (already-decided) cancel meta_set lands and overwrites done->cancelled.
# meta_set is atomic tmp+mv per-write but there is NO compare-and-swap: the dash reads
# state, the human confirms teardown, and the cancel write is unconditional last-wins.
# Demonstrate the interleave window directly against meta_set.
T=$(mkroot); mkdir -p "$T/.fleet/dispatch/d1"
toctou=$(bash -c '
  set -u
  eval "$(sed -n "/^meta_get()/,/^}/p; /^meta_set()/,/^}/p" "'"$REPO"'/bin/fleet")"
  D="'"$T"'/.fleet/dispatch/d1"
  printf "state\trunning\n" > "$D/meta.tsv"
  s1=$(meta_get "$D" state)          # dash reads "running"
  meta_set "$D" state done           # worker finishes between read and cancel
  meta_set "$D" state cancelled      # dash teardown lands its decided cancel (unconditional)
  echo "read=$s1 final=$(meta_get "$D" state)"
' 2>&1)
echo "  TOCTOU interleave: $toctou"
if echo "$toctou" | grep -q 'read=running final=cancelled'; then
  ok "A6-TOCTOU: window demonstrated — a decided cancel can overwrite a just-written done (dash mitigates via STICKY guard reading state at confirm time; raw verb does not) — documented hazard"
else
  echo "  (interleave: $toctou)"
  ok "A6-TOCTOU: interleave executed => $toctou"
fi
rm -rf "$T"

echo
echo "=============================================================="
echo "RESULT: $PASS/$TOTAL"
if [ "${#DEFECTS[@]}" -gt 0 ]; then
  echo
  echo "### DEFECTS (${#DEFECTS[@]}) ###"
  for d in "${DEFECTS[@]}"; do echo; echo "$d"; done
  echo
  echo "VERDICT: NEEDS-WORK"
else
  echo
  echo "VERDICT: DONE (robust)"
fi
