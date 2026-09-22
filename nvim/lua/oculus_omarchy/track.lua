-- Track, untrack and regroup projects and users in the oculus.nvim tracking
-- file from outside Neovim.
--
-- Edits go through oculus's own tracking module (validated, written atomically).
-- Groups are addressed by their names from the list root, and ones that don't
-- exist yet are created at the end of their parent. A running Neovim that
-- published its socket in omarchy.json is then asked to reload, so its Oculus
-- window picks the change up.

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

local function matches(node, provider, field, value, path)
  return type(node[field]) == "string"
    and node[field]:lower() == value:lower()
    and (node.provider or "github") == provider
    and (node.path or ""):lower() == (path or ""):lower()
end

-- Identities are unique per provider across a whole list, groups included.
local function contains(nodes, provider, field, value, path)
  for _, node in ipairs(nodes) do
    if type(node.children) == "table" then
      if contains(node.children, provider, field, value, path) then
        return true
      end
    elseif matches(node, provider, field, value, path) then
      return true
    end
  end

  return false
end

-- Detach the leaf for provider/value from wherever it sits and return it.
local function take(nodes, provider, field, value, path)
  for index, node in ipairs(nodes) do
    if type(node.children) == "table" then
      local found = take(node.children, provider, field, value, path)

      if found then
        return found
      end
    elseif matches(node, provider, field, value, path) then
      return table.remove(nodes, index)
    end
  end
end

-- The children of the group at path (names from the list root; {} is the root),
-- creating groups that don't exist yet. Names match ignoring case, as Oculus
-- keeps sibling group names distinct that way.
local function group_children(nodes, path)
  for _, name in ipairs(path) do
    local found = nil

    for _, node in ipairs(nodes) do
      if type(node.children) == "table" and type(node.name) == "string" and node.name:lower() == name:lower() then
        found = node
        break
      end
    end

    if not found then
      found = { name = name, children = {} }
      table.insert(nodes, found)
    end

    nodes = found.children
  end

  return nodes
end

-- "/Editors/Plugins/" or a JSON array of names, for names containing "/".
function M.parse_group(text)
  if type(text) ~= "string" or text == "" or text == "/" then
    return {}
  end

  if text:sub(1, 1) == "[" then
    local ok, names = pcall(vim.json.decode, text)
    return ok and type(names) == "table" and names or nil
  end

  return vim.split(text, "/", { trimempty = true })
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

-- Load the tracking file, apply edit(tree, list, field, label), save and tell
-- a running Neovim. edit returns false plus a message to stop without saving.
local function edit(provider, identity, file, path, fn)
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
  if path and (provider ~= "github" or not is_project) then
    return false, "--path requires a GitHub project"
  end
  local list = is_project and "projects" or "users"
  local field = is_project and "repository" or "username"
  local label = (is_project and identity or ("@" .. identity)) .. (path and ("/" .. path) or "")
  local message = nil

  local saved, save_err = tracking.mutate(config, function(tree)
    local done
    done, message = fn(tree[list], field, label)

    if not done then
      error(message, 0)
    end
  end)

  if not saved then
    return false, save_err
  end

  reload_running_neovim()
  return true, message
end

-- provider: "github" | "codeberg"; identity: "owner/repo" or "login";
-- group: path of group names ({} or nil for the list root); name: the display
-- name Oculus shows (nil leaves it unset, so Oculus falls back to the identity).
function M.add(provider, identity, file, group, name, path)
  return edit(provider, identity, file, path, function(nodes, field, label)
    if contains(nodes, provider, field, identity, path) then
      return true, "already tracking " .. label
    end

    table.insert(group_children(nodes, group or {}), { [field] = identity, provider = provider, name = name, path = path })
    return true, "tracking " .. label .. (name and name ~= identity and (" as " .. name) or "")
  end)
end

function M.remove(provider, identity, file, path)
  return edit(provider, identity, file, path, function(nodes, field, label)
    if not take(nodes, provider, field, identity, path) then
      return false, "not tracking " .. label
    end

    return true, "stopped tracking " .. label
  end)
end

-- Append the entry to the end of the group at path.
function M.move(provider, identity, group, file, path)
  return edit(provider, identity, file, path, function(nodes, field, label)
    local node = take(nodes, provider, field, identity, path)

    if not node then
      return false, "not tracking " .. label
    end

    table.insert(group_children(nodes, group or {}), node)
    local where = #(group or {}) > 0 and table.concat(group, " › ") or "the top level"
    return true, "moved " .. label .. " to " .. where
  end)
end

return M
