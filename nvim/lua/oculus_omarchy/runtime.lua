-- Helpers run with `nvim -l`, which skips the user's plugin configuration.
local M = {}

function M.path()
  local file = vim.api.nvim_get_runtime_file("lua/oculus/tracking.lua", false)[1]
  return file and vim.fn.fnamemodify(file, ":h:h:h") or nil
end

function M.setup(snapshot_file)
  if vim.env.OCULUS_NVIM_PATH then
    vim.opt.rtp:append(vim.env.OCULUS_NVIM_PATH)
    return
  end

  local snapshot = require("oculus_omarchy.remote").read(snapshot_file)
  if snapshot and type(snapshot.oculus_path) == "string" then
    vim.opt.rtp:append(snapshot.oculus_path)
  end
  vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/oculus.nvim")
  if M.path() then return end

  -- Resolve local lazy.nvim checkouts from the configured editor, even when
  -- no editor is running. Isolate its state so discovery cannot replace the
  -- real bridge's socket or saved Oculus state.
  local scratch = vim.fn.tempname()
  vim.fn.mkdir(scratch, "p")
  local output = scratch .. "/runtime-path"
  local code = [[
    local ok = pcall(require, "oculus.tracking")
    local file = ok and vim.api.nvim_get_runtime_file("lua/oculus/tracking.lua", false)[1]
    if file then vim.fn.writefile({vim.fn.fnamemodify(file, ":h:h:h")}, vim.env.OCULUS_RUNTIME_OUTPUT) end
    vim.cmd("qa!")
  ]]
  local result = vim.system({ vim.v.progpath, "--headless", "-i", "NONE", "-n", "-c", "lua " .. code }, {
    env = { XDG_STATE_HOME = scratch, OCULUS_RUNTIME_OUTPUT = output, OCULUS_OMARCHY_PROBE = "1" },
    text = true,
  }):wait(10000)
  if result.code == 0 and vim.fn.filereadable(output) == 1 then
    local path = vim.fn.readfile(output)[1]
    if path then vim.opt.rtp:append(path) end
  end
  vim.fn.delete(scratch, "rf")
end

return M
