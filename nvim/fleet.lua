-- fleet.lua — loaded into fleet-spawned nvim via:
--   nvim --cmd "lua vim.g.fleet = true" ... (fleet new uses dofile on this file)
-- Self-contained: the user's nvim config is never modified. Everything is
-- wrapped so a missing claudecode.nvim just means "no autostart", never an
-- error that blocks nvim.

-- Defer everything until plugins are loaded.
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    if vim.env.FLEET_AUTOCLAUDE ~= "1" then return end
    vim.defer_fn(function()
      local ok, terminal = pcall(require, "claudecode.terminal")
      if not ok then
        vim.notify("fleet: claudecode.nvim not available, open claude manually", vim.log.levels.WARN)
        return
      end
      pcall(terminal.open, {})
      -- Seed the initial prompt through the terminal channel (same path as
      -- FleetSend) — passing it as a CLI arg through terminal.open proved
      -- unreliable across terminal providers.
      local prompt = vim.env.FLEET_PROMPT
      if prompt and prompt ~= "" then
        vim.defer_fn(function() FleetSend(prompt) end, 3000)
      end
    end, 300)
  end,
})

-- FleetSend(text): deliver text to the claude terminal in this nvim.
-- Called remotely: nvim --server <sock> --remote-expr 'v:lua.FleetSend("...")'
function FleetSend(text)
  if type(text) ~= "string" or text == "" then return "empty" end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "terminal" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match("claude") then
        local chan = vim.bo[buf].channel
        if chan and chan > 0 then
          -- Send text and the submit CR as SEPARATE writes. A single
          -- combined write reads as a bracketed paste and the TUI buffers
          -- the trailing CR instead of submitting; a delayed standalone CR
          -- is seen as a distinct Enter keypress.
          vim.api.nvim_chan_send(chan, text)
          vim.defer_fn(function() vim.api.nvim_chan_send(chan, "\r") end, 80)
          return "sent"
        end
      end
    end
  end
  -- no claude terminal yet: try to open one, then retry once
  local ok, terminal = pcall(require, "claudecode.terminal")
  if ok then
    pcall(terminal.open, {})
    vim.defer_fn(function() FleetSend(text) end, 1500)
    return "opening"
  end
  return "no-claude-terminal"
end

-- FleetCycleMode(): inject Shift+Tab (\27[Z) into the claude terminal to cycle
-- its permission mode (default → accept-edits → plan → bypass). Same focus-
-- independent path as FleetSend — straight to the terminal channel.
function FleetCycleMode()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "terminal" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match("claude") then
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
