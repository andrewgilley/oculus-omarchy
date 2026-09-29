-- Open a tracked project's parent group in the Oculus project list.
local M = {}

function M.open()
  local ok, names = pcall(vim.json.decode, vim.env.OCULUS_GROUP_PATH or "")
  if not ok or type(names) ~= "table" or #names == 0 then
    vim.notify("Oculus: invalid project directory", vim.log.levels.ERROR)
    return false
  end

  local window = require("oculus.window")
  local tracking = window.state.opts and window.state.opts._tracking
  local nodes = tracking and tracking.tree and tracking.tree.projects
  if type(nodes) ~= "table" then
    vim.notify("Oculus: project tracking is unavailable", vim.log.levels.ERROR)
    return false
  end

  local path = {}
  for _, name in ipairs(names) do
    if type(name) ~= "string" or name == "" then
      vim.notify("Oculus: invalid project directory", vim.log.levels.ERROR)
      return false
    end
    local found
    for index, node in ipairs(nodes) do
      if node.name == name and type(node.children) == "table" then
        found = index
        nodes = node.children
        break
      end
    end
    if not found then
      vim.notify("Oculus: project directory not found: " .. name, vim.log.levels.ERROR)
      return false
    end
    path[#path + 1] = found
  end

  window.state.community_view = "projects"
  window.state.tracking_paths = { projects = path, users = {} }
  window.refresh_tracking()
  return true
end

return M
