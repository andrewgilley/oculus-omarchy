-- Run Lua in the Neovim that last published its socket to omarchy.json, so it
-- picks up a file edited behind its back. Best effort: a missing or stale
-- socket just means there's no Neovim to tell.

local M = {}

local state_home = vim.env.XDG_STATE_HOME or (vim.env.HOME .. "/.local/state")

M.snapshot_file = state_home .. "/oculus/omarchy.json"

local function read_json(file)
  local handle = io.open(file, "rb")

  if not handle then
    return nil
  end

  local ok, data = pcall(vim.json.decode, handle:read("*a"))
  handle:close()
  return ok and type(data) == "table" and data or nil
end

function M.exec(code, snapshot_file)
  local snapshot = read_json(snapshot_file or M.snapshot_file)

  if not snapshot or snapshot.running ~= true or type(snapshot.server) ~= "string" then
    return
  end

  local ok, channel = pcall(vim.fn.sockconnect, "pipe", snapshot.server, { rpc = true })

  if ok and channel > 0 then
    pcall(vim.rpcrequest, channel, "nvim_exec_lua", code, {})
    vim.fn.chanclose(channel)
  end
end

return M
