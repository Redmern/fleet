#!/bin/sh
# fleet-dispatch.sh — UserPromptSubmit hook for the orchestration ("dispatch")
# layer. Runs ONLY in the main command-center pane (FLEET_ROLE=main). It intercepts
# sigil-prefixed prompts with ZERO model turn: writes the instruction to the durable
# ledger and spawns an ephemeral sub-orchestrator. A bare (no-sigil) prompt passes
# through untouched to the main pane's own model.
#
# DELIBERATELY opt-in: install.sh does NOT wire this. The operator enables it with
# `fleet dispatch enable`. It must NEVER be active in a live command center unless
# the operator chose to.
#
# Fail-safe = pass-through (exit 0, no dispatch) at every uncertain step.

# 1. ROLE GATE — the load-bearing fork-bomb guard (§1). MUST be first. Every
#    non-main pane (sub-orch, worker, stray claude) starts with FLEET_ROLE unset or
#    =worker, so this exits immediately and the prompt proceeds to that pane's model.
[ "${FLEET_ROLE:-}" = main ] || exit 0

# Dependencies — degrade to pass-through if anything is missing.
command -v jq >/dev/null 2>&1 || exit 0
FLEET_BIN="$(command -v fleet 2>/dev/null)"
[ -n "$FLEET_BIN" ] || exit 0

# Optional registry cross-check (anti-forgery / inheritance guard, §1). If a
# pane-role map exists for this pane and DISAGREES with the env, the map wins and we
# pass through. tmux gives us @fleet_root for the current session.
if [ -n "${TMUX_PANE:-}" ]; then
  _root="$(tmux show -v @fleet_root 2>/dev/null)"
  if [ -n "$_root" ] && [ -f "$_root/.fleet/roles/$TMUX_PANE" ]; then
    _r="$(cat "$_root/.fleet/roles/$TMUX_PANE" 2>/dev/null)"
    [ "$_r" = main ] || exit 0
  fi
fi

# 2. READ the prompt from stdin JSON (consume stdin once into a var).
_input="$(cat 2>/dev/null)"
[ -n "$_input" ] || exit 0
PROMPT="$(printf '%s' "$_input" | jq -r '.prompt // empty' 2>/dev/null)"
[ -n "$PROMPT" ] || exit 0

# 3. CLASSIFY — FLIPPED default (§3.1): a leading sigil dispatches; bare passes
#    through. The sigil is a single leading comma.
case "$PROMPT" in
  ,*) ;;            # dispatch
  *)  exit 0 ;;     # bare → pass-through to the main pane's model
esac
BODY="${PROMPT#,}"    # strip exactly one leading sigil
BODY="${BODY# }"      # strip one optional following space
[ -n "$BODY" ] || exit 0   # a lone "," is not an instruction

# Opportunistic recovery (§4): re-animate any stranded dispatch before our own.
# One-shot, cheap, best-effort — never blocks dispatch.
"$FLEET_BIN" reconcile >/dev/null 2>&1 || true

# 4. DISPATCH (zero model turn).
#    (a) Allocate an id + ledger dir. The body NEVER crosses a command line — fleet
#        echoes the dir path and we write instruction.txt ourselves with printf.
DIR="$("$FLEET_BIN" dispatch-alloc 2>/dev/null)"
[ -n "$DIR" ] && [ -d "$DIR" ] || exit 0
printf '%s' "$BODY" > "$DIR/instruction.txt" 2>/dev/null || exit 0
ID="$(basename "$DIR")"

#    (b) Spawn the sub-orchestrator (only the id is passed).
"$FLEET_BIN" dispatch "$ID" >/dev/null 2>&1 || true

#    (c) Re-assert idle (FINAL-b §4): a decision:block emits no Stop event, so the
#        existing `fleet-hook working` UserPromptSubmit entry would leave the main
#        badge stuck "working". Clear it. Best-effort, feed it the original JSON so
#        it has session_id/cwd. Subagent guards in fleet-hook make this a no-op for
#        non-main panes anyway.
if command -v fleet-hook >/dev/null 2>&1; then
  printf '%s' "$_input" | fleet-hook idle >/dev/null 2>&1 || true
fi

#    (d) Ack the user with ZERO model turn: the reason field renders to the
#        transcript; suppressOriginalPrompt keeps the erased text out of the message.
#        The id is d<N>/so-d<N> — no quotes/shell metachars, safe to interpolate.
printf '{"decision":"block","reason":"dispatched as %s → so-%s","suppressOriginalPrompt":true}\n' "$ID" "$ID"
exit 0
