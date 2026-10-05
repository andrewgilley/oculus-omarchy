-- Bridge from Neovim to the Omarchy "andrewgilley.oculus" bar widget.
--
-- Publishes this Neovim's RPC socket to $XDG_STATE_HOME/oculus/omarchy.json so
-- the widget can open Oculus here and oculus-track can reload tracking here.

local M = {}

M.config = {
  path = (vim.env.XDG_STATE_HOME or (vim.env.HOME .. "/.local/state")) .. "/oculus/omarchy.json",
  interval_ms = 30000,
}

local timer = nil

local function write(payload)
  payload.version = 1
  payload.pid = vim.fn.getpid()
  payload.updated_at = os.time()
  vim.fn.mkdir(vim.fn.fnamemodify(M.config.path, ":h"), "p")

  local temporary = M.config.path .. ".tmp"

  if pcall(vim.fn.writefile, { vim.json.encode(payload) }, temporary) then
    vim.uv.fs_rename(temporary, M.config.path)
  end
end

function M.publish()
  write({ running = true, server = vim.v.servername, oculus_path = require("oculus_omarchy.runtime").path() })
end

function M.setup(opts)
  if vim.env.OCULUS_OMARCHY_PROBE == "1" then return end
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- The widget needs a socket to send commands back.
  if vim.v.servername == "" then
    vim.fn.serverstart()
  end

  if timer then
    timer:stop()
  end

  -- A heartbeat, so the widget can tell a crashed Neovim from a live one.
  timer = vim.uv.new_timer()
  timer:start(0, M.config.interval_ms, vim.schedule_wrap(M.publish))

  local group = vim.api.nvim_create_augroup("OculusOmarchy", { clear = true })

  -- The most recently focused Neovim wins.
  vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = M.publish })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if timer then
        timer:stop()
      end

      write({ running = false, oculus_path = require("oculus_omarchy.runtime").path() })
    end,
  })
end

return M
