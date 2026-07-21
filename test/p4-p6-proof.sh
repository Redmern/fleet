#!/usr/bin/env bash
# Proof harness — d28 PROOF DESIGN claims P4 (backward compatibility with
# in-flight work) and P6 (negative control: trivia must not trigger recon).
#
# These are the two claims that do NOT need a live fleet dispatch. P1/P2/P5 are
# observations on a real dispatch; P3's mechanism was hardened structurally in
# 72055cd.
#
# WHY THIS HARNESS IS NOT A GREP HARNESS
# --------------------------------------
# The spec (_reports/plan-agent-role/PLAN-PLAIN.md, "# PROOF DESIGN") says
# outright: "Nothing below is satisfiable by reading the diff." An earlier role
# shipped `test/plan-role-recon-proof.sh`, which asserts that certain STRINGS are
# present in FLEET_SUBORCH.md. That proves the prose was edited. It cannot
# distinguish a manual an agent OBEYS from one it ignores, and its claims were
# rejected as UNPROVEN. P4 and P6 are both claims about what a sub-orchestrator
# DOES, so both are tested by RUNNING a sub-orchestrator.
#
# Two layers, and the difference matters:
#
#   LAYER A (mechanical, always runs, deterministic).
#     `fleet reconcile` must revive an OLD-FORMAT ledger dir — one written before
#     this change: cursor `role-phase research`, no `reports` key, no RECON.md —
#     rather than choke on it or skip it. This is a genuine execution of the real
#     bin/fleet code against an old-shaped ledger.
#     HONESTY NOTE, stated up front because it bounds what Layer A can mean:
#     `bin/fleet` never PARSES `role-phase` (grep it — the string appears only in
#     comments and in gate-message prose). The cursor is read by the AGENT, not by
#     the code. So Layer A proves only that an old ledger still round-trips
#     through reconcile; it CANNOT prove "it continues at the right role and does
#     not re-run completed roles". That sentence is a claim about an agent.
#
#   LAYER B (behavioural, opt-in via FLEET_PROOF_LIVE=1, the ACTUAL P4/P6 proof).
#     Spawns a REAL headless sub-orchestrator (`claude -p`) with the byte-exact
#     prompt `cmd_reconcile` uses, pointed at THIS branch's FLEET_SUBORCH.md, in a
#     throwaway sandbox: private project root, a small fake repo, and a PATH whose
#     `fleet` and `tmux` are RECORDING STUBS. The stubs mean the agent's decisions
#     land in a log instead of spawning anything, and the assertions read that log
#     plus the filesystem. What the sub-orch DID is the evidence.
#     Layer B costs real model calls, so it is opt-in. A default run prints a loud
#     UNPROVEN banner: a green Layer-A-only run must never read as "P4/P6 proven".
#
# ISOLATION (every rule below has already cost real damage today — a harness took
# down the live tmux server TWICE, orphaning dispatch gates):
#   * the socket is resolved HERE, from THIS file's own mktemp TMPROOT, and the
#     harness REFUSES to start unless it lives under TMPROOT;
#   * every tmux call in this file routes through a same-file `-S` wrapper, so the
#     socket can be neither forgotten nor lost across a subshell;
#   * kill-server / kill-window state the socket LITERALLY, not via the wrapper;
#   * FLEET_ROOT is private, so nothing here can touch the REAL .fleet/dispatch
#     ledger (a naked `fleet dispatch` from a fleet pane mutates it — known footgun);
#   * XDG_CONFIG_HOME / XDG_RUNTIME_DIR private (else agents_tsv answers from the
#     LIVE fleetd), GIT_CONFIG_GLOBAL/SYSTEM=/dev/null, FLEET_DEBUG_PORT set (a
#     reap path runs `fuser -k 9222/tcp` = the dev's Chromium), TMUX unset.
#
# Prove the guard itself, with TMUX_TMPDIR UNSET:
#   FLEET_HARNESS_SOCK=/tmp/tmux-1000/default   -> rc=1 "resolved to the real tmux socket"
#   FLEET_HARNESS_SOCK=/tmp/somewhere-else/sock -> rc=1 "socket is not under TMPROOT"
# and confirm `tmux has-session -t pc` still succeeds after every run.
set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
FLEET="$HERE/bin/fleet"
MANUAL="$HERE/FLEET_SUBORCH.md"

# --- isolation ----------------------------------------------------------------
TMPROOT=$(mktemp -d)
# Socket isolation is INTRINSIC, never inherited. Ambient `export TMUX_TMPDIR` is
# NOT enough on its own: any step running in a shell that did not inherit it falls
# back to /tmp/tmux-$(id -u)/default — the REAL server — and a bare `tmux
# kill-server` in cleanup() then tears down the live fleet. TMUX_TMPDIR is still
# exported, but only so CHILD processes ($FLEET -> tmux) reach the SAME private
# server; correctness no longer rests on it.
export TMUX_TMPDIR="$TMPROOT/tmuxsock"
mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"; chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"
# FLEET_HARNESS_SOCK exists ONLY so the guard below can be proven to fire; it is
# itself guarded, so it can never be used to escape to the real socket.
SOCK="${FLEET_HARNESS_SOCK:-$TMUX_TMPDIR/tmux-$(id -u)/default}"

# --- fail-fast guard: runs BEFORE any tmux call -------------------------------
if [ "$SOCK" = "/tmp/tmux-$(id -u)/default" ]; then
  echo "REFUSE: harness resolved to the real tmux socket ($SOCK)" >&2
  rm -rf "$TMPROOT"; exit 1
fi
case "$SOCK" in
  "$TMPROOT"/*) ;;
  *) echo "REFUSE: harness socket is not under TMPROOT ($SOCK not under $TMPROOT)" >&2
     rm -rf "$TMPROOT"; exit 1 ;;
esac

tmux() { command tmux -S "$SOCK" "$@"; }

export XDG_CONFIG_HOME="$TMPROOT/config";  mkdir -p "$XDG_CONFIG_HOME/fleet/sessions"
export XDG_RUNTIME_DIR="$TMPROOT/run";     mkdir -p "$XDG_RUNTIME_DIR"
unset TMUX
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export FLEET_DEBUG_PORT=59223
export FLEET_SESSION="p4p6_t"
export FLEET_ROOT="$TMPROOT/root"; mkdir -p "$FLEET_ROOT/.fleet/dispatch"

# A real binary named `claude` so tmux's #{pane_current_command} reads `claude`
# and is_harness_cmd() calls the pane LIVE (a shebang script would report `sh`).
mkdir -p "$TMPROOT/bin"
cp "$(command -v sleep)" "$TMPROOT/bin/claude" 2>/dev/null
CLAUDE_BIN="$TMPROOT/bin/claude"
REAL_CLAUDE=$(command -v claude 2>/dev/null || true)

# kill-server is EXPLICITLY socket-scoped, not just wrapper-scoped: this is the
# one call that destroys a whole server, so it states its target literally.
# P4P6_EVIDENCE=<dir> copies every behavioural sandbox out BEFORE the wipe. Without
# it a failing case is unauditable: the trap deletes TMPROOT on exit, so the cursor
# walk, cmds.log and artifacts that justify the verdict are gone by the time anyone
# reads it. A proof whose evidence self-destructs is a claim, not a proof.
cleanup() {
  if [ -n "${P4P6_EVIDENCE:-}" ]; then
    mkdir -p "$P4P6_EVIDENCE" 2>/dev/null
    cp -a "$TMPROOT"/sb-* "$P4P6_EVIDENCE"/ 2>/dev/null
  fi
  command tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$TMPROOT"
}
trap cleanup EXIT

pass() { echo "  PASS($1)"; }
fail() { echo "  FAIL($1): $2"; FAILED=$((FAILED+1)); }
skip() { echo "  SKIP($1): $2"; SKIPPED=$((SKIPPED+1)); }
FAILED=0; SKIPPED=0

LED="$FLEET_ROOT/.fleet/dispatch"
meta_get() { awk -F'\t' -v k="$2" '$1==k{v=$2} END{print v}' "$LED/$1/meta.tsv" 2>/dev/null; }

win_exists() { # <id-or-window-name>
  local s
  for s in "$FLEET_SESSION" "${FLEET_SESSION}_hidden"; do
    tmux list-windows -t "=$s" -F '#{window_name}' 2>/dev/null \
      | grep -qx "so-$1" && return 0
  done
  return 1
}

tmux new-session -d -s "$FLEET_SESSION" -n base -c "$FLEET_ROOT" sh 2>/dev/null
tmux set -t "$FLEET_SESSION" @fleet_root "$FLEET_ROOT" 2>/dev/null

echo "== p4-p6-proof: backward compat with in-flight ledgers + trivia stays flat =="
echo

# ============================================================================ #
# LAYER A — mechanical. An OLD-FORMAT ledger still round-trips through the real
# `fleet reconcile`.
# ============================================================================ #
echo "-- LAYER A (mechanical, deterministic) --"

# An OLD-FORMAT ledger dir: exactly what a pre-d28 sub-orch wrote. Note what is
# ABSENT — no `reports` key (cmd_dispatch_rename did not write one), and no
# _reports/<slug>/RECON.md — because that is the shape this change has to keep
# swallowing.
mk_old_ledger() { # <id> <state> <role-phase>
  local id="$1" st="$2" ph="$3"
  mkdir -p "$LED/$id"
  printf 'Add a --dry-run flag to the widget sync command.\n' > "$LED/$id/instruction.txt"
  { printf 'state\t%s\n' "$st"
    printf 'window\tso-%s\n' "$id"
    printf 'respawns\t0\n'
    printf 'role-phase\t%s\n' "$ph"; } > "$LED/$id/meta.tsv"
}

reset_led() { rm -rf "$LED"; mkdir -p "$LED"; }

# --- A1. an old-format, non-terminal, dead-window dispatch is REVIVED, and its
#     cursor survives the revival byte-for-byte. If reconcile choked on the
#     missing `reports` key, or rewrote the cursor, an in-flight dispatch would
#     lose its place — which is the P4 failure at the mechanical layer.
reset_led
mk_old_ledger d81 planning research
FLEET_RECONCILE_CAP=5 PATH="$TMPROOT/bin:$PATH" "$FLEET" reconcile >/dev/null 2>&1
n=$(meta_get d81 respawns); ph=$(meta_get d81 role-phase); st=$(meta_get d81 state)
if [ "$n" = 1 ] && [ "$ph" = research ] && [ "$st" = planning ]; then
  pass A1
else
  fail A1 "old-format ledger did not survive reconcile: respawns='$n' (want 1) role-phase='$ph' (want research) state='$st' (want planning)"
fi

# --- A2. same for a LATER old-format cursor (`impl`). The cursor is an opaque
#     token to bin/fleet; a dispatch that was mid-implementation when the manual
#     changed must revive just as cleanly.
reset_led
mk_old_ledger d82 implementing impl
FLEET_RECONCILE_CAP=5 PATH="$TMPROOT/bin:$PATH" "$FLEET" reconcile >/dev/null 2>&1
n=$(meta_get d82 respawns); ph=$(meta_get d82 role-phase)
if [ "$n" = 1 ] && [ "$ph" = impl ]; then
  pass A2
else
  fail A2 "old-format impl-cursor ledger did not survive reconcile: respawns='$n' (want 1) role-phase='$ph' (want impl)"
fi

# --- A3. the revived sub-orch is handed the SAME dispatch id and the SAME
#     instruction file — i.e. it is resumed, not re-created under a new id. The
#     window name carries the identity, so assert on it.
if win_exists d82 || win_exists d81; then
  pass A3
else
  fail A3 "no so-<id> window was spawned for a revived old-format dispatch — the resume never happened"
fi

# --- A4. bash -n on the thing under test.
if bash -n "$FLEET" 2>/dev/null; then pass A4; else fail A4 "bash -n failed on $FLEET"; fi

echo

# ============================================================================ #
# LAYER B — behavioural. A REAL headless sub-orch, in a stubbed sandbox.
# ============================================================================ #
echo "-- LAYER B (behavioural: real headless sub-orch) --"

# One sandbox per behavioural run. Contains:
#   root/            private project root (the agent's CWD)
#     repo/          a tiny git repo to be recon'd / edited
#     .fleet/dispatch/<id>/{instruction.txt,meta.tsv}
#     _reports/<slug>/  wherever the agent decides, via the ledger `reports` key
#   bin/fleet        RECORDING STUB — logs argv, never spawns
#   bin/tmux         REFUSING STUB — logs argv, exits 1
#   cmds.log         every stubbed command, one argv per line
#
# The stubs are what make this safe AND observable: the sub-orch's decisions
# ("spawn a PLAN role", "rename to <slug>") become log lines instead of real
# panes, and the assertions read the log. Nothing it can do reaches the live
# fleet, the live tmux server, or the real ledger.
mk_sandbox() { # <dir> <id> <slug> <instruction-file> <state> <role-phase> [artifacts...]
  local sb="$1" id="$2" slug="$3" inst="$4" st="$5" ph="$6"; shift 6
  local root="$sb/root" led="$sb/root/.fleet/dispatch/$id"
  mkdir -p "$led" "$sb/bin" "$root/_reports/$slug" "$root/repo"
  : > "$sb/cmds.log"

  # --- the fake repo the recon would look at ---------------------------------
  printf 'Widget sync tool. It can recieve updates from the hub.\n' > "$root/repo/README.md"
  cat > "$root/repo/sync.sh" <<'EOF'
#!/bin/sh
# widget sync — pushes local widgets to the hub
sync_all() { for w in widgets/*; do push "$w"; done; }
push() { printf 'pushing %s\n' "$1"; }
sync_all
EOF
  chmod +x "$root/repo/sync.sh"
  ( cd "$root/repo" && git init -q . && git -c user.email=t@t -c user.name=t add -A \
      && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1

  # --- the OLD-FORMAT ledger --------------------------------------------------
  cp "$inst" "$led/instruction.txt"
  { printf 'state\t%s\n' "$st"
    printf 'window\tso-%s\n' "$id"
    printf 'respawns\t1\n'
    # `reports` IS written here even for the old-format cases: cmd_dispatch_rename
    # writes it, and without it the agent has no absolute reports path at all,
    # which would test a different (and unrelated) failure. What makes these
    # ledgers "old format" is the cursor value plus the ABSENT RECON.md.
    printf 'reports\t%s\n' "$root/_reports/$slug"
    printf 'role-phase\t%s\n' "$ph"; } > "$led/meta.tsv"

  # --- pre-existing artifacts (a finished PLAN role, but NO RECON.md) --------
  # These are REAL artifacts, copied from test/fixtures/, not placeholders — and
  # that distinction decided a case. The first cut of this harness seeded
  # `# PLAN.md\n(pre-existing artifact from before the resume)`, and the resumed
  # sub-orch rebuilt the whole plan, its new PLAN.md stating the reason outright:
  # "Supersedes the content-free stub of the same name". It was RIGHT to: an empty
  # plan is not a plan, so that run tested a degenerate fixture, not the resume
  # contract. A backward-compat fixture has to be indistinguishable from what the
  # OLD pipeline actually left on disk, so these are the genuine PLAN.md /
  # SYNTHESIS.md / PLAN-PLAIN.md a real sub-orch produced for this same
  # instruction, with RECON.md withheld — which is exactly the old-format shape.
  local a
  for a in "$@"; do
    if [ -f "$HERE/test/fixtures/p4b-midflight/$a" ]; then
      cp "$HERE/test/fixtures/p4b-midflight/$a" "$root/_reports/$slug/$a"
    else
      printf '# %s\n\n(pre-existing artifact from before the resume)\n' "$a" \
        > "$root/_reports/$slug/$a"
    fi
  done

  # --- recording stub: fleet -------------------------------------------------
  cat > "$sb/bin/fleet" <<EOF
#!/bin/sh
printf '%s\n' "fleet \$*" >> "$sb/cmds.log"
case "\$1" in
  dispatch)
    # 'fleet dispatch rename <id> <slug>' — echo back a plausible reports path.
    printf '%s\n' "$root/_reports/$slug" ;;
  new)     printf 'spawned (stub)\n' ;;
  watch)   printf 'watching (stub)\n' ;;
  ls)      printf 'no agents (stub)\n' ;;
  *)       printf 'ok (stub)\n' ;;
esac
exit 0
EOF
  # --- refusing stub: tmux ---------------------------------------------------
  cat > "$sb/bin/tmux" <<EOF
#!/bin/sh
printf '%s\n' "tmux \$*" >> "$sb/cmds.log"
printf 'tmux: refused by proof harness\n' >&2
exit 1
EOF
  chmod +x "$sb/bin/fleet" "$sb/bin/tmux"
}

# Run one headless sub-orch against a sandbox. Byte-exact prompt from
# cmd_reconcile's respawn path (bin/fleet, the `cmd_new --scratch` call), pointed
# at THIS branch's manual — that is the whole point: we are testing the manual as
# an instruction set, so the agent must be given it the way fleet gives it.
run_suborch() { # <sandbox> <id>
  local sb="$1" id="$2" root="$1/root"
  ( cd "$root" \
    && PATH="$sb/bin:$PATH" TMUX= FLEET_ROOT="$root" \
       timeout "${P4P6_TIMEOUT:-600}" "$REAL_CLAUDE" -p \
       --permission-mode bypassPermissions \
       --output-format text \
       "You are a fleet dispatch sub-orchestrator (so-$id). Your project root is your CWD ($root).
FIRST, read and follow your operating manual: $MANUAL
THEN handle DISPATCH ID: $id — read your instruction at .fleet/dispatch/$id/instruction.txt" \
  ) > "$sb/agent.out" 2>"$sb/agent.err"
  printf '%s' "$?" > "$sb/agent.rc"
}

# --- observables -------------------------------------------------------------
# Did a RECON.md land? (§3.0.1b's artifact — the thing P6 says must NOT appear
# for trivia, and P4b says must NOT be re-derived on resume.)
recon_written() { # <sandbox> <slug>
  [ -s "$1/root/_reports/$2/RECON.md" ]
}
# Did the agent spawn a PLAN role agent? The role pipeline spawns fleet agents
# named <slug>-plan / <slug>-impl / <slug>-test (§3.0.2), so a `fleet new` whose
# branch/label ends in -plan is the pipeline firing.
spawned_role() { # <sandbox> <role>
  grep -E "^fleet new .*[-_]$2( |$|-)" "$1/cmds.log" >/dev/null 2>&1
}
# Any pipeline role at all.
spawned_any_role() { # <sandbox>
  spawned_role "$1" plan || spawned_role "$1" impl || spawned_role "$1" test
}
n_fleet_new() { grep -cE '^fleet new ' "$1/cmds.log" 2>/dev/null || echo 0; }

# --- "continue, not restart", operationalised --------------------------------
# The first cut of P4a asserted `fleet new <slug>-plan was called AND the cursor
# is still `research``. That was an over-specified PROXY and the run falsified the
# proxy, not the claim: the sub-orch worked the research rung INLINE (its harness
# has sub-agents, so §3.0.2's "one fleet agent per role" was satisfied by
# sub-agent contexts), wrote RECON.md + PLAN.md + SYNTHESIS.md + PLAN-PLAIN.md +
# three ADVISER files, advanced the cursor `research -> gate1-wait`, and posted
# GATE 1. That IS continuing. Demanding a specific spawn mechanism tested the
# harness's shape, not the resume contract.
#
# What P4 actually claims is DIRECTION OF TRAVEL: a resumed dispatch moves
# forward along the rung sequence and never rewinds to re-do finished work. So
# rank the rungs and compare. This is the honest test, and it is strictly HARDER
# to satisfy than "did not crash": a restarting sub-orch rewinds, and rewinding
# is precisely what this catches (P4b-MUT confirms it can).
rung_index() { # <cursor value> -> 0..5, or -1 for unknown/empty
  case "$1" in
    research)   echo 0 ;; gate1-wait) echo 1 ;; impl) echo 2 ;;
    test)       echo 3 ;; gate2-wait) echo 4 ;; done) echo 5 ;;
    *)          echo -1 ;;
  esac
}
cursor_now() { # <sandbox> <id> — last-wins, exactly like meta_get
  awk -F'\t' '$1=="role-phase"{v=$2} END{print v}' \
    "$1/root/.fleet/dispatch/$2/meta.tsv" 2>/dev/null
}
# Did the cursor ever REWIND below where the resume started? The ledger is
# append-only (§3.0.5 upserts by appending), so the whole walk is on disk and a
# rewind is visible as a later line ranking below the start rung.
cursor_rewound() { # <sandbox> <id> <start-rung>
  local start; start=$(rung_index "$3")
  local v i
  awk -F'\t' '$1=="role-phase"{print $2}' \
    "$1/root/.fleet/dispatch/$2/meta.tsv" 2>/dev/null | while read -r v; do
      i=$(rung_index "$v")
      [ "$i" -ge 0 ] && [ "$i" -lt "$start" ] && { echo REWOUND; break; }
  done | grep -q REWOUND
}


# Case selection, so a re-run need not re-burn cases already settled.
# P4P6_CASES="p4a p4b" runs just those. Default: all.
P4P6_CASES="${P4P6_CASES:-p6 p6mut p4a p4b p4bmut p4bnew}"
want() { case " $P4P6_CASES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

if [ "${FLEET_PROOF_LIVE:-0}" != 1 ]; then
  skip B "LAYER B not run (set FLEET_PROOF_LIVE=1). P4 and P6 are BEHAVIOURAL claims; Layer A alone does NOT prove either."
elif [ -z "$REAL_CLAUDE" ]; then
  skip B "no \`claude\` on PATH — cannot run a headless sub-orch"
else
  # Instruction fixtures live OUT here, not inside a case block: they are shared,
  # and creating one inside `if want p6mut` meant P4P6_CASES="p4a p4b" ran with a
  # missing instruction file (cp: cannot stat inst-feature.txt) — the sandbox came
  # up without an instruction at all.
  printf "Fix the typo 'recieve' -> 'receive' in repo/README.md.\n" > "$TMPROOT/inst-trivial.txt"
  printf 'Add a --dry-run flag to the widget sync command: it must print every widget it would push without writing anything, cover the nested-widget edge case, and ship with tests.\n' > "$TMPROOT/inst-feature.txt"
  printf 'Add a --dry-run flag to the widget sync command: it must print every widget it would push without writing anything, and ship with tests. Nested/recursive widgets are OUT OF SCOPE — widgets/* stays single-level.\n' > "$TMPROOT/inst-p4b.txt"

  # ---- P6. NEGATIVE CONTROL: a trivial one-liner must stay on the flat path.
  #      §3.0.1 classifies question < trivial < feature and biases trivial->flat.
  #      If recon fires here, the change has carpet-bombed the cheap path.
  if want p6; then
  SB6="$TMPROOT/sb-p6"; mkdir -p "$SB6"
  mk_sandbox "$SB6" d90 typo-fix "$TMPROOT/inst-trivial.txt" planning ""
  run_suborch "$SB6" d90
  if ! recon_written "$SB6" typo-fix && ! spawned_any_role "$SB6"; then
    pass P6
  else
    fail P6 "trivia triggered the pipeline: RECON.md=$(recon_written "$SB6" typo-fix && echo written || echo absent) roles=$(grep -E '^fleet new ' "$SB6/cmds.log" | tr '\n' ';')"
  fi

  fi

  # ---- P6-MUT. The mutation that proves P6 CAN fail: same harness, same
  #      assertions, a FEATURE-sized instruction. If the P6 assertions stay green
  #      here they are asserting nothing, and P6 is worthless.
  if want p6mut; then
  SB6M="$TMPROOT/sb-p6mut"; mkdir -p "$SB6M"
  mk_sandbox "$SB6M" d91 dry-run "$TMPROOT/inst-feature.txt" planning ""
  run_suborch "$SB6M" d91
  if recon_written "$SB6M" dry-run || spawned_any_role "$SB6M"; then
    pass P6-MUT
  else
    fail P6-MUT "the P6 assertions cannot fail: a full feature ALSO produced no RECON.md and no role agent"
  fi

  fi

  # ---- P4a. old-format ledger, cursor `research`, no RECON.md. Nothing is
  #      finished, so "continue" means: stay in the research rung and spawn the
  #      PLAN role. It must NOT fail, park, or start a different dispatch.
  if want p4a; then
  SB4A="$TMPROOT/sb-p4a"; mkdir -p "$SB4A"
  mk_sandbox "$SB4A" d92 dry-run "$TMPROOT/inst-feature.txt" planning research
  run_suborch "$SB4A" d92
  ph=$(cursor_now "$SB4A" d92); pi=$(rung_index "$ph")
  # Continue = the cursor is still a RECOGNISED rung (an old-format value did not
  # become unresolvable), it did not rewind below `research`, and the rung was
  # actually worked (SYNTHESIS.md = the PLAN role finished, per §3.0.5's table).
  if [ "$pi" -ge 0 ] && ! cursor_rewound "$SB4A" d92 research \
     && [ -s "$SB4A/root/_reports/dry-run/SYNTHESIS.md" ]; then
    pass P4a
  else
    fail P4a "resume from cursor=research did not continue: cursor now='$ph' (rung $pi; -1=unresolvable) rewound=$(cursor_rewound "$SB4A" d92 research && echo YES || echo no) SYNTHESIS.md=$([ -s "$SB4A/root/_reports/dry-run/SYNTHESIS.md" ] && echo written || echo absent); log: $(tr '\n' ';' < "$SB4A/cmds.log")"
  fi

  fi

  # ---- P4b. THE case. Old-format ledger mid-pipeline: cursor `impl`, with
  #      PLAN.md + SYNTHESIS.md already on disk and NO RECON.md — a shape only a
  #      pre-d28 dispatch can have. §3.0.5's table says SYNTHESIS.md present =>
  #      the PLAN role finished. The resumed sub-orch must pick up at impl and
  #      must NOT re-run the completed role, and must NOT treat the missing
  #      RECON.md as "start over". That is the exact failure a cursor rename
  #      would have introduced.
  if want p4b; then
  # The instruction here is the UNAMBIGUOUS variant, and that is load-bearing.
  # Run with the ambiguous "cover the nested-widget edge case" wording, the PLAN
  # role legitimately returns REVISE — and a resumed sub-orch then rewinds for a
  # reason that has nothing to do with backward compatibility. It said so
  # outright: "the artifacts say the PLAN role returned REVISE, not BUILD… `impl`
  # was a rung this dispatch never earned. I rolled the cursor back to research."
  # That is CORRECT behaviour against a self-contradictory ledger — a dispatch at
  # `impl` must have had a BUILD verdict — so it tested the fixture, not P4. A
  # backward-compat fixture must be internally consistent: unambiguous
  # instruction -> BUILD verdict -> gate 1 passed -> cursor legitimately at impl.
  SB4B="$TMPROOT/sb-p4b"; mkdir -p "$SB4B"
  mk_sandbox "$SB4B" d93 dry-run "$TMPROOT/inst-p4b.txt" implementing impl \
    PLAN.md SYNTHESIS.md PLAN-PLAIN.md
  run_suborch "$SB4B" d93
  # Re-running a completed role shows up three ways, any one of which fails it:
  # the cursor rewinds below `impl`; RECON.md is re-derived (§3.0.5: RECON.md is
  # a research-rung artifact and the rung is finished); or PLAN.md is rewritten.
  plan_mtime_changed=no
  cmp -s "$HERE/test/fixtures/p4b-midflight/PLAN.md" \
         "$SB4B/root/_reports/dry-run/PLAN.md" || plan_mtime_changed=yes
  if ! cursor_rewound "$SB4B" d93 impl \
     && ! recon_written "$SB4B" dry-run \
     && [ "$plan_mtime_changed" = no ]; then
    pass P4b
  else
    fail P4b "resume from cursor=impl re-ran a completed role: rewound=$(cursor_rewound "$SB4B" d93 impl && echo YES || echo no) RECON.md=$(recon_written "$SB4B" dry-run && echo REWRITTEN || echo absent) PLAN.md-rewritten=$plan_mtime_changed; cursor walk: $(awk -F'\t' '$1=="role-phase"{printf "%s ", $2}' "$SB4B/root/.fleet/dispatch/d93/meta.tsv")"
  fi

  fi

  # ---- P4b-MUT. The mutation that proves P4b CAN fail: identical sandbox with
  #      the cursor RENAMED to `plan` — the rename §3.0.5 says must never happen —
  #      and the completed artifacts removed, i.e. a ledger whose place is lost.
  #      A restart here is the RIGHT answer, so the P4b assertions must go RED.
  if want p4bmut; then
  SB4BM="$TMPROOT/sb-p4bmut"; mkdir -p "$SB4BM"
  mk_sandbox "$SB4BM" d94 dry-run "$TMPROOT/inst-feature.txt" planning plan
  run_suborch "$SB4BM" d94
  # Trips if ANY limb of P4b's conjunction breaks — same predicates, so this
  # proves P4b's own assertions are live rather than vacuous.
  if cursor_rewound "$SB4BM" d94 impl || recon_written "$SB4BM" dry-run \
     || spawned_role "$SB4BM" plan; then
    pass P4b-MUT
  else
    fail P4b-MUT "the P4b assertions cannot fail: a lost-place cursor with NO artifacts also produced no rewind, no RECON.md and no plan role"
  fi
  fi

  # ---- P4b-NEWFMT. The control that decides what a P4b failure MEANS, and it is
  #      the difference between "this change broke in-flight work" and "§3.0.5 is
  #      ambiguous for everybody".
  #
  #      P4b resumes an OLD-format ledger at `impl` and the sub-orch rewinds to
  #      `gate1-wait`, re-posting a gate the human already passed. The tempting
  #      reading is "the missing RECON.md confused it" = a backward-compat
  #      regression. But §3.0.5's cross-check TABLE says, flatly, `SYNTHESIS.md`
  #      present => "read the verdict → GATE 1" — and a NEW-format ledger at
  #      `impl` has SYNTHESIS.md too. If the table is what is driving the rewind,
  #      the same thing happens with RECON.md present, and the defect has nothing
  #      to do with old ledgers.
  #
  #      So: byte-identical to P4b, plus RECON.md. This asserts the NEW format
  #      does NOT rewind. It PASSES => only the old format regresses => P4 fails
  #      for real. It FAILS => both formats rewind => the cursor-vs-table
  #      contradiction in §3.0.5 is general, and P4 is not what is broken.
  #
  #      MEASURED (2 runs per arm, and the result is CROSSED):
  #        old fmt (no RECON.md): rewound once, continued once (impl -> test)
  #        new fmt (RECON.md):    continued once, rewound once (impl -> gate1-wait)
  #      So RECON.md presence has NO detectable effect, and a SINGLE run of either
  #      arm proves nothing — the first pair looked like a clean backward-compat
  #      regression and the replication inverted it exactly. The rewind is real but
  #      INTERMITTENT and format-independent: §3.0.5's prose ("the cursor is the
  #      fast path; artifacts are the cross-check, NEVER the primary signal") and
  #      its table (`SYNTHESIS.md` present => "read the verdict -> GATE 1")
  #      disagree about a cursor at `impl`, and the sub-orch resolves that
  #      disagreement differently run to run. Treat a lone red here as a coin
  #      flip; run both arms at least twice before drawing any conclusion.
  if want p4bnew; then
  SB4BN="$TMPROOT/sb-p4bnew"; mkdir -p "$SB4BN"
  mk_sandbox "$SB4BN" d95 dry-run "$TMPROOT/inst-p4b.txt" implementing impl \
    PLAN.md SYNTHESIS.md PLAN-PLAIN.md RECON.md
  run_suborch "$SB4BN" d95
  if ! cursor_rewound "$SB4BN" d95 impl; then
    pass P4b-NEWFMT
  else
    fail P4b-NEWFMT "a NEW-format ledger (RECON.md present) rewinds from impl too => the rewind is NOT a backward-compat regression; §3.0.5's cursor-vs-table contradiction hits both formats. cursor walk: $(awk -F'\t' '$1=="role-phase"{printf "%s ", $2}' "$SB4BN/root/.fleet/dispatch/d95/meta.tsv")"
  fi
  fi
fi

echo
if [ "${FLEET_PROOF_LIVE:-0}" != 1 ]; then
  cat <<'BANNER'
  ############################################################################
  #  P4 and P6 are UNPROVEN by this run. Layer A exercised the mechanical     #
  #  ledger path only; both claims are about what a sub-orchestrator DOES.    #
  #  Re-run with FLEET_PROOF_LIVE=1 to run the behavioural layer.             #
  ############################################################################
BANNER
fi

if [ "$FAILED" = 0 ]; then
  echo "RESULT: ALL RUN CASES PASS ($SKIPPED skipped)"
  exit 0
else
  echo "RESULT: $FAILED case(s) FAILED ($SKIPPED skipped)"
  exit 1
fi
