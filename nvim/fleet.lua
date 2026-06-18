-- fleet.lua — loaded into fleet-spawned nvim via:
--   nvim --cmd "lua vim.g.fleet = true" ... (fleet new uses dofile on this file)
-- Self-contained: the user's nvim config is never modified. Everything is
-- wrapped so a missing claudecode.nvim just means "no autostart", never an
-- error that blocks nvim.

-- Which terminal buffer is "the agent" — claude by default, but fleet sets
-- FLEET_TERM_MATCH per harness (e.g. "omp") so FleetSend/FleetCycleMode route
-- to the right terminal.
local function term_match()
  local m = vim.env.FLEET_TERM_MATCH
  if m == nil or m == "" then m = "claude" end
  return m
end

-- Defer everything until plugins are loaded.
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    local prompt = vim.env.FLEET_PROMPT
    if vim.env.FLEET_AUTOCLAUDE == "1" then
      -- Claude via claudecode.nvim.
      vim.defer_fn(function()
        local ok, terminal = pcall(require, "claudecode.terminal")
        if not ok then
          vim.notify("fleet: claudecode.nvim not available, open claude manually", vim.log.levels.WARN)
          return
        end
        -- Fleet-scoped permission mode: only this autostart path passes it, so
        -- manual <leader>cc launches keep claudecode's configured default.
        local sm = vim.env.FLEET_START_MODE
        local cmd_args = (sm and sm ~= "") and ("--permission-mode " .. sm) or nil
        pcall(terminal.open, {}, cmd_args)
        -- Seed the prompt through the terminal channel (same path as FleetSend)
        -- — passing it as a CLI arg through terminal.open proved unreliable.
        if prompt and prompt ~= "" then
          vim.defer_fn(function() FleetSend(prompt) end, 3000)
        end
      end, 300)
    elseif vim.env.FLEET_HARNESS_BIN and vim.env.FLEET_HARNESS_BIN ~= "" then
      -- Generic harness (omp, …): open it in a plain :terminal split so
      -- FleetSend can chan_send into it just like the claude terminal.
      vim.defer_fn(function()
        pcall(function()
          vim.cmd("botright vsplit")
          vim.cmd("terminal " .. vim.env.FLEET_HARNESS_BIN)
          vim.cmd("startinsert")
        end)
        -- Editor→agent parity for harnesses without an IDE channel: the same
        -- <leader>c* keys as the claude config, but routed through the terminal
        -- channel (the user's claudecode mappings are inert here — no claude).
        pcall(function()
          vim.keymap.set("v", "<leader>cs", FleetSendSelection,
            { silent = true, desc = "Send selection to agent" })
          vim.keymap.set("n", "<leader>ca", function() FleetSendFile() end,
            { silent = true, desc = "Mention current file to agent" })
        end)
        if prompt and prompt ~= "" then
          vim.defer_fn(function() FleetSend(prompt) end, 3000)
        end
      end, 300)
    end
  end,
})

-- Find the agent terminal's channel in this nvim (the :terminal buffer whose
-- name matches term_match()). Shared by every send helper below.
local function term_chan()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "terminal" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match(term_match()) then
        local chan = vim.bo[buf].channel
        if chan and chan > 0 then return chan end
      end
    end
  end
  return nil
end

-- Write text into the agent terminal. When submit is true, follow with a CR.
-- Text and the submit CR are SEPARATE writes: a single combined write reads as
-- a bracketed paste and the TUI buffers the trailing CR instead of submitting;
-- a delayed standalone CR is seen as a distinct Enter keypress. This path is
-- harness-agnostic — it drives claude's TUI and omp's TUI identically.
local function term_write(text, submit)
  local chan = term_chan()
  if not chan then return nil end
  vim.api.nvim_chan_send(chan, text)
  if submit then
    vim.defer_fn(function()
      local c = term_chan()
      if c then vim.api.nvim_chan_send(c, "\r") end
    end, 80)
  end
  return true
end

-- FleetSend(text): deliver text to the agent terminal in this nvim and submit.
-- Called remotely: nvim --server <sock> --remote-expr 'v:lua.FleetSend("...")'
function FleetSend(text)
  if type(text) ~= "string" or text == "" then return "empty" end
  if term_write(text, true) then return "sent" end
  -- no agent terminal yet: for claude, try to open one and retry once.
  local ok, terminal = pcall(require, "claudecode.terminal")
  if ok then
    pcall(terminal.open, {})
    vim.defer_fn(function() FleetSend(text) end, 1500)
    return "opening"
  end
  return "no-agent-terminal"
end

-- FleetSendSelection(): send the current visual selection to the agent terminal
-- as a fenced block tagged with the file path + line range. The omp/Pi-family
-- TUIs read this as ordinary prompt text — this is the no-protocol "send
-- selection" parity for harnesses without an editor channel (see
-- docs/omp-nvim-integration.md §0). Bind in visual mode.
function FleetSendSelection()
  local mode = vim.fn.mode()
  if not (mode == "v" or mode == "V" or mode == "\22") then return "not-visual" end
  local a, b = vim.fn.getpos("v"), vim.fn.getpos(".")
  local ok, lines = pcall(vim.fn.getregion, a, b, { type = mode })
  -- leave visual mode regardless of outcome
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  if not ok or not lines or #lines == 0 then return "no-selection" end
  local path = vim.fn.expand("%:.")
  if path == "" then path = "buffer" end
  local l1, l2 = math.min(a[2], b[2]), math.max(a[2], b[2])
  local ft = vim.bo.filetype or ""
  local msg = string.format("@%s (lines %d-%d):\n```%s\n%s\n```\n", path, l1, l2, ft, table.concat(lines, "\n"))
  return term_write(msg, false) and "sent" or "no-agent-terminal"
end

-- FleetSendFile(path): drop an @-file mention into the agent's prompt (no
-- submit, so the user can keep composing). Defaults to the current file.
function FleetSendFile(path)
  if not path or path == "" then path = vim.fn.expand("%:.") end
  if path == "" then return "no-file" end
  return term_write("@" .. path .. " ", false) and "sent" or "no-agent-terminal"
end

-- FleetCycleMode(): inject Shift+Tab (\27[Z) into the claude terminal to cycle
-- its permission mode (default → accept-edits → plan → bypass). Same focus-
-- independent path as FleetSend — straight to the terminal channel.
function FleetCycleMode()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "terminal" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match(term_match()) then
        local chan = vim.bo[buf].channel
        if chan and chan > 0 then
          vim.api.nvim_chan_send(chan, "\27[Z")
          return "sent"
        end
      end
    end
  end
  return "no-claude-terminal"
end
