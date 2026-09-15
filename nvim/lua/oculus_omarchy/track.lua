-- Add projects and users to the oculus.nvim tracking file from outside Neovim.
--
-- Edits go through oculus's own tracking module (validated, written atomically)
-- and land at the root of the Projects or Users list. A running Neovim that
-- published its socket in omarchy.json is then asked to reload, so its Oculus
-- window picks the new entry up.

local M = {}

local config_home = vim.env.XDG_CONFIG_HOME or (vim.env.HOME .. "/.config")
local state_home = vim.env.XDG_STATE_HOME or (vim.env.HOME .. "/.local/state")

M.config = {
  tracking_file = config_home .. "/oculus/tracking.json",
  snapshot_file = state_home .. "/oculus/omarchy.json",
}

local function read_json(file)
  local handle = io.open(file, "rb")

  if not handle then
    return nil
  end

  local ok, data = pcall(vim.json.decode, handle:read("*a"))
  handle:close()
  return ok and type(data) == "table" and data or nil
end

-- Identities are unique per provider across a whole list, groups included.
local function contains(nodes, provider, field, value)
  for _, node in ipairs(nodes) do
    if type(node.children) == "table" then
      if contains(node.children, provider, field, value) then
        return true
      end
    elseif
      type(node[field]) == "string"
      and node[field]:lower() == value:lower()
      and (node.provider or "github") == provider
    then
      return true
    end
  end

  return false
end

-- Best effort: a missing or stale socket just means nothing to reload.
local function reload_running_neovim()
  local snapshot = read_json(M.config.snapshot_file)

  if not snapshot or snapshot.running ~= true or type(snapshot.server) ~= "string" then
    return
  end

  local ok, channel = pcall(vim.fn.sockconnect, "pipe", snapshot.server, { rpc = true })

  if ok and channel > 0 then
    pcall(vim.rpcrequest, channel, "nvim_exec_lua", [[
      local ok, oculus = pcall(require, "oculus")
      if ok and oculus.config and oculus.config.tracking_file then
        oculus.reload_tracking()
      end
    ]], {})
    vim.fn.chanclose(channel)
  end
end

-- provider: "github" | "codeberg"; identity: "owner/repo" or "login".
function M.add(provider, identity, file)
  if provider ~= "github" and provider ~= "codeberg" then
    return false, "provider must be github or codeberg"
  end

  if type(identity) ~= "string" or identity == "" then
    return false, "expected owner/repo or a login"
  end

  local ok, tracking = pcall(require, "oculus.tracking")

  if not ok then
    return false, "oculus.nvim not found; set OCULUS_NVIM_PATH"
  end

  local config = { tracking_file = file or M.config.tracking_file }
  local loaded, err = tracking.load(config)

  if not loaded then
    return false, err
  end

  local is_project = identity:find("/", 1, true) ~= nil
  local list = is_project and "projects" or "users"
  local field = is_project and "repository" or "username"
  local label = is_project and identity or ("@" .. identity)

  if contains(config._tracking.tree[list], provider, field, identity) then
    return true, "already tracking " .. label
  end

  local saved, save_err = tracking.mutate(config, function(tree)
    table.insert(tree[list], { [field] = identity, provider = provider })
  end)

  if not saved then
    return false, save_err
  end

  reload_running_neovim()
  return true, "tracking " .. label
end

return M
