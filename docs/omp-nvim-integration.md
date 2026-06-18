# omp ↔ Neovim integration — design doc

> Goal: give a **fleet-spawned omp agent** the same quality of Neovim
> integration that a Claude Code agent gets today via `claudecode.nvim` —
> autostart, diff review in nvim buffers, send-selection, @-file mentions —
> **without** requiring the user to embed omp in their own nvim config.

Status: research + design. Not an implementation. Cites file paths + exact
flags so the build can start from the right seams.

---

## TL;DR — the recommendation

**Drive omp through its native ACP server (`omp acp`), not a raw `:terminal`.**

omp (oh-my-pi v16.0.6, `~/.local/bin/omp`) ships a first-class editor-integration
transport that the "known flags" list missed: a top-level subcommand

```
omp acp   # "Run Oh My Pi as an ACP (Agent Client Protocol) server over stdio"
```

ACP is the **same published, versioned protocol Zed uses** for external agents
(JSON-RPC 2.0 over stdio). omp's ACP server is unusually complete and natively
delivers all three parity goals:

| Parity goal | claudecode.nvim mechanism (claude) | omp mechanism (ACP) |
|---|---|---|
| autostart + drive a session | WebSocket IDE/MCP server in nvim; CLI connects back | `session/new` + `session/prompt` over stdio |
| **diff review** accept/reject in nvim | `openDiff` MCP tool + deferred coroutine | `session/update` `tool_call` carrying `{type:"diff",path,oldText,newText}`; accept/reject via `session/request_permission` |
| send selection / @-file mention | `at_mentioned` / `selection_changed` broadcasts | `session/prompt` content blocks: text, `resource_link` (file mention), embedded selection — `promptCapabilities.embeddedContext:true` |

Architecturally the two are **mirror images** of the same idea (editor ⇄ agent
RPC carrying diffs + context), but the **direction is flipped**:

- **claudecode.nvim**: nvim is the **server**, claude CLI is the **client**.
  Discovery via lockfile + `CLAUDE_CODE_SSE_PORT`.
- **omp ACP**: nvim is the **client**, omp is the **server** (a subprocess on
  stdio). No lockfile, no port, no discovery dance — just spawn `omp acp` and
  speak JSON-RPC over its stdin/stdout.

The ACP direction is **simpler to wire from fleet** (no WebSocket server to host
in nvim, no auth token, no port file) and is omp's blessed path.

---

## 0. CRITICAL UPDATE (post-research, supersedes optimistic framing below)

Live probing of `omp acp` + reading omp's **embedded** docs (`approval-mode.md`,
`mcp-config.md`, ACP/RPC source strings in the binary) surfaced a constraint the
first-pass doc under-weighted:

**omp's editor-integration modes are HEADLESS. There is no "TUI + sidechannel".**
- `omp acp` and `omp --mode=rpc[/-ui]` run omp as a *headless server* with **no
  terminal UI** (binary literally prints *"Copy not available in ACP mode"*;
  `rpc-ui` implies `--no-pty`).
- claudecode.nvim's parity trick relies on claude running its **full TUI in the
  `:terminal`** *and* exposing the IDE channel **at the same time**. omp cannot do
  both at once: you either get the rich omp TUI **or** the editor protocol.

Consequence — omp forces an either/or:
- **(A) omp TUI in `:terminal`** (today's MVP): great chat UX, `FleetSend` works,
  but **no** structured diff/selection channel.
- **(B) `omp acp` headless**: diff-review/selection/mention possible, but you must
  **reimplement omp's chat UI inside nvim** (render `agent_message_chunk` etc.).
  That is a large build and a *worse* chat experience than omp's own TUI.

So "ACP gives claudecode parity for free" is **false**. Realistic split:
- **Cheap wins, keep the TUI (no ACP):** add *send-selection* and *@-file-mention*
  by `chan_send`ing text (a fenced selection / an `@path`) into the omp TUI via
  the existing FleetSend channel. Closes 2 of 3 gaps, no architecture change.
- **Diff-review (the one hard gap):** genuinely needs headless ACP/RPC + a custom
  in-nvim chat UI. Big, separate effort. (An alternative worth a spike: omp is an
  **MCP client** — `session/new` takes `mcpServers`, and RPC mode has a
  `RpcHostToolBridge` / `set_host_tools` letting the *host* register tools omp
  calls back over stdio. nvim-as-MCP/host-tool-server *might* feed omp editor
  tools while keeping a UI — unverified.)

Live-verified facts (this machine, omp 16.0.6): newline-delimited JSON-RPC 2.0
over stdio; `initialize`→`session/new`→`session/prompt`; async `session/update`
notifications seen: `available_commands_update`, `session_info_update`,
`usage_update`. `session/request_permission` is the documented accept/reject gate
(kept by default unless `tools.approvalMode: yolo`). A live `tool_call`/diff frame
was **not** captured — the sandbox model returned `end_turn` without performing
edits; capturing a real diff frame remains the top pre-build unknown for path (B).

---

## 1. How claudecode.nvim works (the parity bar)

Found on disk: `~/.local/share/nvim/lazy/claudecode.nvim/` (coder/claudecode.nvim
v0.2.0). It is a pure-Lua reimplementation of the VS Code "IDE" MCP integration.

### Transport
- nvim runs a **loopback WebSocket server** (RFC 6455, built on `vim.loop`,
  no external libs) speaking **JSON-RPC 2.0 / MCP** (`server/init.lua`,
  `server/tcp.lua`, `server/frame.lua`). MCP protocol version `2024-11-05`.
- **Discovery**: nvim writes `~/.claude/ide/<port>.lock` (JSON
  `{pid, workspaceFolders, ideName:"Neovim", transport:"ws", authToken:<uuidv4>}`,
  `lockfile.lua:114-121`) and injects `CLAUDE_CODE_SSE_PORT=<port>` +
  `ENABLE_IDE_INTEGRATION=true` + `FORCE_CODE_TERMINAL=true` into the spawned
  claude terminal (`terminal.lua:309-324`). Despite the name "SSE", transport is
  WebSocket. Auth: CLI sends the token back in HTTP header
  `x-claude-code-ide-authorization` on the WS upgrade (`handshake.lua:44`).
- Server **autostarts on plugin load** (`config.auto_start=true`); the claude CLI
  launches lazily when the terminal opens or a mention is queued.

### Feature → wire mechanism
- **Terminal lifecycle**: managed split (native `:terminal` / snacks / external),
  `:ClaudeCode[Focus|Open|Close]` (`terminal.lua`, `init.lua:984-1020`).
- **Send selection**: `:ClaudeCodeSend` → broadcast `at_mentioned`
  `{filePath,lineStart,lineEnd}` (`selection.lua:630-698`).
- **@-file mentions**: `:ClaudeCodeAdd` / tree integrations for nvim-tree,
  neo-tree, oil, mini.files → each path sent as `at_mentioned`
  (`integrations.lua`). Mentions are queued/debounced until the WS connects.
- **Diff review (the crown jewel)**: CLI calls MCP tool `openDiff`
  `{old_file_path,new_file_path,new_file_contents,tab_name}`. Handler is
  `requires_coroutine=true` (`tools/open_diff.lua:94`): it opens a **native nvim
  diff** (old buffer `diffthis` | proposed scratch buffer `diffthis`) and
  **`coroutine.yield()`s, blocking the JSON-RPC response** (`diff.lua:1335`).
  The pending responder is stashed in global `_G.claude_deferred_responses`
  keyed by coroutine id. **Accept** = `:w` the proposed buffer → resumes with
  `FILE_SAVED` + content; **reject** = delete the buffer → `DIFF_REJECTED`.
  Keymaps `:ClaudeCodeDiffAccept` / `:ClaudeCodeDiffDeny`.
- **Selection/focus tracking**: debounced `selection_changed` broadcasts with
  LSP-style positions (`selection.lua:430-544`).
- **MCP tool catalog** exposed to claude: `openDiff`, `openFile`,
  `getCurrentSelection`, `getLatestSelection`, `getOpenEditors`,
  `getDiagnostics`, `getWorkspaceFolders`, `checkDocumentDirty`, `saveDocument`,
  `closeAllDiffTabs`, `close_tab` (`tools/init.lua:42-57`).

**The reusable idea for omp**: the *deferred-coroutine* pattern (yield on a tool
that needs human accept/reject, resume from an autocmd). ACP needs the same
pattern, just triggered by `session/request_permission` instead of `openDiff`.

---

## 2. omp's editor-integration surface

omp exposes **three** mechanisms. Ranked for this goal:

### (1) ACP — `omp acp` — RECOMMENDED
- **Transport**: JSON-RPC 2.0, newline-delimited, over **stdio**. nvim is the
  client; omp is the subprocess server.
- **Live-verified handshake** (`echo '{"jsonrpc":"2.0","id":0,"method":"initialize",...}' | omp acp`):
  ```json
  {"protocolVersion":1,
   "agentInfo":{"name":"oh-my-pi","title":"Oh My Pi","version":"16.0.6"},
   "agentCapabilities":{"loadSession":true,
     "promptCapabilities":{"embeddedContext":true,"image":true},
     "sessionCapabilities":{"list":{},"fork":{},"resume":{},"close":{}}}}
  ```
- **Methods omp implements** (from binary strings, all present): `initialize`,
  `authenticate`, `session/new`, `session/prompt`, `session/update`,
  `session/request_permission`, `session/load`, `session/set_mode`,
  `session/cancel`, `session/list`, `session/fork`, `session/resume`,
  `session/close`, `fs/read_text_file`, `fs/write_text_file`, and a full
  `terminal/*` suite (`create/output/wait_for_exit/kill/release/credential`).
- **Diff review**: edits arrive as `session/update` notifications with
  `sessionUpdate:"tool_call"`/`"tool_call_update"` whose content includes an ACP
  **diff block** `{"type":"diff","path":<abs>,"oldText":<str|null>,"newText":<str>}`
  (`oldText` null = new file). Approval routed to the client via
  **`session/request_permission`** for `bash`/`edit`/`delete`/`move`. Other
  `sessionUpdate` kinds: `agent_message_chunk`, `agent_thought_chunk`,
  `user_message_chunk`, `plan`, `available_commands_update`,
  `current_mode_update`. Documented in omp's embedded `approval-mode.md`:
  > "When ACP approval is required, OMP routes it through the ACP client instead
  > of the terminal TUI. Client-gated `bash`, `edit`, `delete`, and `move` calls
  > use ACP `session/request_permission`."
- **Selection / @-mentions**: `promptCapabilities.embeddedContext:true` ⇒
  `session/prompt` accepts content blocks beyond text — `resource`/`resource_link`
  (file mentions to a URI) and images. A visual selection → embedded text/resource
  block; an @-file → `resource_link`.
- **Modes**: `session/new` returns `configOptions` with a `mode` select
  (`default` headless / `plan` read-only) + a `model` select; switch mid-session
  via `session/set_mode`. **This is omp's analogue of claude permission modes** —
  relevant to the fleet mode-pill gap (§5).
- **Approval default**: keep the client gate; for unattended runs pass
  `omp acp --yolo` / `--approval-mode yolo`.

### (2) `--mode=rpc` / `rpc-ui` — omp's own protocol (fallback, not recommended)
- Custom **newline-delimited JSON** over stdio, `{"type":...}`-tagged. **NOT**
  JSON-RPC, **NOT** LSP-framed. Emits `{"type":"ready"}` first.
- Commands keyed on `type`: `prompt`, `steer`, `follow_up`, `abort`,
  `new_session`, `get_state`, `set_model`, `set_thinking_level`, `bash`,
  `set_host_tools`, `set_host_uri_schemes`, … Events:
  `tool_execution_start/update/end`, `message_*`, `agent_*`.
- **No dedicated diff frame** — edits surface as `tool_execution_*` for the
  `edit`/`write` tools; review goes through an "Extension UI" sub-protocol
  (`extension_ui_request` → `confirm`/`select`/`editor`). Lower-level than ACP.
- `rpc-ui` = `rpc` + a `setToolUIContext` callback for richer tool-render
  directives, and **implies `--no-pty`**. Same command schema otherwise.
- **Verdict**: proprietary and lower-level. ACP gives typed diffs + a standard
  permission gate for free. Use rpc only if ACP proves to lack something.

### (3) Hooks / extensions (`--hook` / `-e,--extension`) — complementary, not a transport
- **JavaScript/TypeScript** ES modules running **in-process** in omp (not shell,
  not lua, not a client channel). `--hook` is now an alias for `--extension`.
- Events via `pi.on`: session lifecycle, `context` (rewrite messages),
  `tool_call` (pre, can `{block,reason}`), `tool_result` (post, override output),
  turn/compaction. API: `pi.registerCommand`, `pi.registerTool`, `pi.ui`, …
- **Cannot** present diffs to an external editor or receive selections — they run
  inside omp. Useful as a *policy* layer (e.g. block risky edits) **alongside**
  ACP, not as the editor link.

### Disk findings
- omp state: `~/.omp/{agent,cache,logs,natives}` only. **No** `~/.config/omp`,
  no on-disk config, **no companion editor plugin** ships. ACP is the contract.
- omp's authoritative protocol docs are **embedded in the binary** (`rpc.md`,
  `approval-mode.md`, `hooks.md`, 80+ md files); `omp.sh/docs` returns 403 to
  fetch. ACP diff shape cross-confirmed at agentclientprotocol.com.

---

## 3. How fleet wires nvim today, and the exact gap

### Today's spawn path (`bin/fleet:466-477`)
Every agent gets the same nvim launch:
```bash
nvim . --cmd "lua pcall(dofile, '$FLEET_DIR/nvim/fleet.lua')" --listen "$nsock"
```
with env (`bin/fleet:472-474`):
- `FLEET_AUTOCLAUDE` = `1` iff `H_NVIM_PLUGIN=1` else `0`  ← **the central gate**
- `FLEET_HARNESS_BIN` = resolved binary (e.g. `omp`)
- `FLEET_TERM_MATCH` = `H_TERM_MATCH` (terminal-name match for FleetSend)
- `FLEET_PROMPT` = seed prompt

`fleet.lua` branches on that gate (`nvim/fleet.lua:17-51`):
- **`FLEET_AUTOCLAUDE==1`** → `require("claudecode.terminal").open{}` (WebSocket
  IDE server comes up).
- **else `FLEET_HARNESS_BIN` set** → `botright vsplit` + `:terminal <bin>` — a
  **dumb PTY**. This is omp's current leg.

Both then seed the prompt via `FleetSend(prompt)` after 3 s, and both take
messages via `FleetSend` (`nvim/fleet.lua:55-82`): it iterates terminal buffers,
matches the name against `FLEET_TERM_MATCH`, and `nvim_chan_send`s text + a
deferred `\r`. **This already works for omp** — it's harness-agnostic.

### Harness config knobs (`harness.d/*.conf`, consumed in `bin/fleet`)
| Var | claude.conf | omp.conf | consumed at |
|---|---|---|---|
| `H_NVIM_PLUGIN` | `1` | `0` | `bin/fleet:472` → `FLEET_AUTOCLAUDE` |
| `H_BIN` | `claude-profile claude` | `omp` | binary resolution |
| `H_TERM_MATCH` | `claude` | `omp` | `FLEET_TERM_MATCH` |
| `H_STATE_SRC` | `hook` | `scrape` | daemon state source |
| `H_MODE_KEYS`/`H_MODE_LIST` | Shift+Tab / 5 modes | `""` / `""` | mode cycling |
| `H_BUSY_RE` | `""` | `esc to interrupt\|working\|…` | pane-scrape state |

`H_NVIM_PLUGIN` is a **bool consumed in exactly one place** (`bin/fleet:472`).
That single boolean is the entire mechanism flipping an agent between the
claudecode.nvim path and the plain-terminal path. **It is the designed extension
point** — generalize it from a bool to a plugin selector.

### The gap (omp vs claude)
omp already has: autostart, prompt seed, `FleetSend` delivery, pane-scrape state,
session-JSONL cost. It is **missing everything editor-protocol-shaped** because
its `:terminal omp` is a one-way PTY with no return channel into nvim:
1. **No bidirectional editor link** — no diffs, no context push, no tool events.
2. **No diff review** in nvim buffers.
3. **No send-selection / @-mention** into the agent.
4. **No mode pill** — `harness_has_modes()` is name-hardcoded to `claude`
   (`bin/fleet-dash:139-141`), ignoring `H_MODE_LIST`.
5. **No PreToolUse guard** (`H_GUARD_KIND=none`).

---

## 4. Recommended design

### Does an omp.nvim exist? No.
No omp-authored editor plugin ships or is on disk. **But omp speaks ACP**, and
ACP has a growing Neovim client ecosystem (e.g. CodeCompanion.nvim's ACP adapter;
Zed's reference client `zed-industries/agent-client-protocol`). Two build
options:

- **Option A — adopt/vendor an existing ACP nvim client** as `nvim/acp.lua`,
  wired the same way `claudecode.nvim` is. Less code; depends on a third-party
  plugin's maturity and that the user need not configure it.
- **Option B — write a minimal in-tree `nvim/omp.lua`** ACP client (recommended
  for fleet's fail-silent, zero-user-config ethos). ~A few hundred lines of Lua:
  spawn `omp acp` via `vim.fn.jobstart` (stdio), frame/parse newline JSON-RPC,
  implement the handful of client-side methods + the diff-review coroutine.
  Self-contained `dofile` shim like `fleet.lua`, no plugin manager.

**Recommendation: Option B** — it matches fleet's "embeds nothing, calls
everything, fail-silent, no user config" model (CLAUDE.md). Keep it a single
`dofile`-able Lua file mirroring `fleet.lua`'s structure.

### What fleet changes (the seams, concretely)
1. **`harness.d/omp.conf`**: turn the plugin flag into a selector. Either reuse
   `H_NVIM_PLUGIN` as a string (`H_NVIM_PLUGIN=omp`) or add `H_NVIM_PLUGIN_KIND`.
   Keep `H_TERM_MATCH=omp` (the ACP client still hosts a terminal buffer named
   so `FleetSend` keeps working).
2. **`bin/fleet:472`**: generalize the gate. Instead of
   `FLEET_AUTOCLAUDE = (H_NVIM_PLUGIN==1)`, export a tri-state, e.g.
   `FLEET_NVIM_PLUGIN=claude|omp|none`, from `H_NVIM_PLUGIN`. Leave the rest of
   the env block (`FLEET_HARNESS_BIN`, `FLEET_TERM_MATCH`, `FLEET_PROMPT`)
   untouched — the omp Lua reuses them.
3. **`nvim/fleet.lua:17-51`**: add a third autostart branch. On
   `FLEET_NVIM_PLUGIN=="omp"`, `dofile`/`require` the new `nvim/omp.lua` and call
   its `open()` (spawns `omp acp`, opens an output/terminal buffer). On `"claude"`
   keep today's `claudecode.terminal`. On `"none"`/`0` keep the plain `:terminal`.
4. **`nvim/omp.lua`** (new): the ACP client. Owns:
   - `jobstart{ "omp", "acp", ... }` on stdio; `initialize` → `session/new`.
   - A **chat/output buffer** named to match `H_TERM_MATCH` (so `FleetSend`'s
     name-match + chan_send path can still seed prompts — or, cleaner, route
     `FleetSend` through `session/prompt`; see below).
   - **Diff review**: on `session/update` `tool_call` with a `diff` block, open a
     native nvim diff (reuse claudecode's pattern — old buffer `diffthis` |
     proposed buffer `diffthis`). On `session/request_permission`, **defer** the
     response (coroutine yield), resume with allow/deny from accept/reject
     keymaps (`:OmpDiffAccept` / `:OmpDiffDeny`). This is the exact
     deferred-responder pattern from `claudecode/diff.lua` — port it.
   - `FleetAddFile()` / selection command → `session/prompt` content block
     (`resource_link` for a file, embedded text for a selection).
5. **`FleetSend` routing** (`nvim/fleet.lua:55-82`): for omp, prefer routing the
   message through `omp.lua`'s `session/prompt` (structured, robust) rather than
   chan_send into a PTY. Keep chan_send as the fail-silent fallback. `cmd_send`
   in `bin/fleet:490-510` is already harness-agnostic (RPC `--remote-expr` then
   `send-keys` fallback) — no change needed there.
6. **Mode pill** (`bin/fleet-dash:139-141`): change `harness_has_modes()` to gate
   on `H_MODE_LIST != ""` instead of `name==claude`. Populate `omp.conf`
   `H_MODE_LIST="default plan"` and have `FleetCycleMode` (or a new
   `FleetSetMode`) call ACP `session/set_mode`. (Stretch; not MVP.)
7. **State**: no change — `fleetd.scrape_harnesses` (`bin/fleetd:171-207`) already
   handles hookless harnesses. (Stretch: derive state from ACP `session/update`
   `agent_*` events for precision instead of pane-scrape.)

### Why this is clean
`H_NVIM_PLUGIN` → `FLEET_*` env → `fleet.lua` branch is **already** the harness
abstraction's plugin seam. We are adding a third leg to an existing fork, not
re-architecting. ACP-as-client means **no WebSocket server, no lockfile, no port,
no auth token** to manage in nvim — strictly less machinery than claudecode.nvim.

---

## 5. Phased plan

**Phase 0 — MVP: terminal/autostart parity (mostly already done).**
- omp autostarts in nvim + prompt seed + `FleetSend` already work via the generic
  PTY leg. Confirm and lock as the baseline. *Effort: ~0; verification only.*

**Phase 1 — ACP session embed.**
- New `nvim/omp.lua`: spawn `omp acp`, `initialize` + `session/new`, render
  agent message chunks into a buffer, route prompts/`FleetSend` through
  `session/prompt`. Add the `FLEET_NVIM_PLUGIN` tri-state gate (`bin/fleet:472`,
  `harness.d/omp.conf`, `fleet.lua` third branch). *Deliverable: omp driven over
  ACP instead of a raw PTY, message in/out structured.*

**Phase 2 — diff review.**
- Handle `session/update` `tool_call` diff blocks → native nvim diff buffers;
  `session/request_permission` → deferred coroutine + accept/reject keymaps
  (port claudecode's `diff.lua` responder pattern). *Deliverable: omp's proposed
  edits reviewed/accepted/rejected inside nvim — the headline parity feature.*

**Phase 3 — selection + @-mentions.**
- `FleetAddFile` / visual-selection commands → `session/prompt` `resource_link` /
  embedded-text blocks. Optional tree-explorer integrations mirroring
  claudecode's. *Deliverable: push editor context into omp.*

**Phase 4 — polish (stretch).**
- Mode pill via `H_MODE_LIST` + ACP `session/set_mode`; precise agent state from
  ACP events instead of pane-scrape; optional omp policy hook as a guard analogue.

---

## 6. Open questions / risks

1. **Live diff frame not captured.** `initialize`/`session/new` are live-verified,
   but no LLM provider was reachable in the research sandbox, so a real
   `session/update` diff + `session/request_permission` during an `edit` turn was
   not observed end-to-end. The shapes are confirmed from the ACP spec **and**
   literal field strings in omp's binary, but **before building Phase 2, run a
   one-shot ACP edit turn against a working provider and capture the actual
   frames** (a harness skeleton was left at `/tmp/acp_client.py`). *Highest-risk
   unknown.*
2. **PTY vs ACP for the prompt seed.** Routing `FleetSend` through `session/prompt`
   is cleaner but changes the today-working chan_send path. Keep chan_send as a
   fail-silent fallback; don't regress the MVP.
3. **Terminal-buffer expectation.** `FleetSend`'s name-match (`H_TERM_MATCH`)
   assumes a `:terminal` buffer exists. An ACP client may not host a real PTY;
   either keep a thin terminal buffer named to match, or switch omp's `FleetSend`
   to the ACP route (preferred) and relax the name-match dependency for omp.
4. **ACP version drift.** omp reports ACP `protocolVersion:1`; the spec is young.
   Pin behavior to what omp 16.0.6 actually emits; degrade fail-silent (per
   CLAUDE.md) if a method is missing.
5. **Auth / unattended runs.** Default ACP keeps the client permission gate even
   though the schema default is `yolo`. For autonomous fleet agents decide policy:
   `omp acp --yolo` (no gate) vs. auto-allow in the nvim client. Mode `plan` is a
   useful read-only default.
6. **Third-party client maturity (if Option A).** CodeCompanion/Zed ACP clients
   evolve independently and would need user-invisible config — friction against
   fleet's zero-config goal. Reinforces Option B (in-tree `omp.lua`).
7. **`fs/*` and `terminal/*` callbacks.** omp's ACP server can call back into the
   client for file reads/writes and client-owned terminals. MVP can decline these
   (let omp use its own fs/PTY); revisit if omp relies on client-side fs for diff
   application.

---

## Appendix — citation index

- claudecode.nvim: `~/.local/share/nvim/lazy/claudecode.nvim/` — `server/init.lua`,
  `server/tcp.lua`, `server/handshake.lua:44`, `lockfile.lua:114-121`,
  `terminal.lua:309-324`, `tools/open_diff.lua:94`, `diff.lua:1335`,
  `tools/init.lua:42-57`, `init.lua:984-1020`.
- omp: `~/.local/bin/omp` v16.0.6 — `omp --help`, `omp acp --help`, embedded
  `rpc.md` / `approval-mode.md` / `hooks.md`; live `initialize` + `session/new`
  over `omp acp`. ACP spec: agentclientprotocol.com/protocol/tool-calls.
- fleet: `bin/fleet:466-477` (spawn), `:472-474` (env gate), `:490-510`
  (`cmd_send`), `harness.d/claude.conf`, `harness.d/omp.conf`,
  `nvim/fleet.lua:17-51` (autostart branch), `:55-82` (`FleetSend`),
  `bin/fleet-dash:139-141` (mode gate), `bin/fleetd:171-207` (scrape state).
