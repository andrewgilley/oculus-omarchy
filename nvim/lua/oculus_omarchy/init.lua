-- Bridge from oculus.nvim to the Omarchy "andrewgilley.oculus" bar widget.
--
-- Writes a small JSON snapshot of what Oculus knows to
-- $XDG_STATE_HOME/oculus/omarchy.json. The widget watches that file. Oculus
-- itself is not modified; this module only reads its public config and window
-- state, so every read is defensive.

local M = {}

M.config = {
  path = vim.fn.stdpath("state"):gsub("/nvim$", "") .. "/oculus/omarchy.json",
  interval_ms = 5000,
  max_events = 20,
}

local timer = nil
local last_payload = nil

local function count_projects(list)
  local total = 0

  for _, item in ipairs(list or {}) do
    if type(item) == "table" then
      if type(item.children) == "table" then
        total = total + count_projects(item.children)
      elseif item.repository then
        total = total + 1
      end
    end
  end

  return total
end

-- TODO: map the real event shapes from oculus.github / oculus.codeberg.
local function normalize_event(event)
  if type(event) ~= "table" then
    return nil
  end

  local repo = event.repo

  return {
    kind = event.kind or event.type,
    repository = event.repository or (type(repo) == "table" and repo.name) or repo,
    title = event.title or event.summary,
    actor = event.actor and (event.actor.login or event.actor) or event.username,
    url = event.url or event.html_url,
    created_at = event.created_at,
  }
end

function M.snapshot()
  local ok_oculus, oculus = pcall(require, "oculus")
  local ok_window, window = pcall(require, "oculus.window")
  local config = ok_oculus and oculus.config or {}
  local state = ok_window and window.state or {}

  local events = {}

  for _, event in ipairs(type(state.events) == "table" and state.events or {}) do
    local normalized = normalize_event(event)

    if normalized then
      table.insert(events, normalized)
    end

    if #events >= M.config.max_events then
      break
    end
  end

  local project = state.activity_project

  return {
    version = 1,
    running = true,
    pid = vim.fn.getpid(),
    server = vim.v.servername,
    view = state.view,
    tracking = {
      projects = count_projects(config.projects),
      users = #(config.contributors or {}),
    },
    focus = {
      project = type(project) == "table" and project.repository or project,
      user = state.selected_username,
    },
    events = events,
  }
end

local function write(payload)
  local ok_encode, encoded = pcall(vim.json.encode, payload)

  if not ok_encode then
    return
  end

  -- Skip identical writes so the widget's file watcher stays quiet.
  if encoded == last_payload then
    return
  end

  last_payload = encoded

  -- updated_at is added after the comparison so it doesn't defeat it.
  payload.updated_at = os.time()
  encoded = vim.json.encode(payload)

  vim.fn.mkdir(vim.fn.fnamemodify(M.config.path, ":h"), "p")

  local temporary = M.config.path .. ".tmp"

  if pcall(vim.fn.writefile, { encoded }, temporary) then
    vim.uv.fs_rename(temporary, M.config.path)
  end
end

local last_project_key = nil

-- Opening a project's feed in Oculus counts as "seen" for the widget.
local function track_opened_project()
  local ok, window = pcall(require, "oculus.window")
  local project = ok and window.state.activity_project or nil
  local key = type(project) == "table" and type(project.repository) == "string"
    and require("oculus_omarchy.activity").key(project)
    or nil

  if key and key ~= last_project_key then
    require("oculus_omarchy.activity").mark_seen({ key })
  end

  last_project_key = key
end

function M.publish()
  pcall(track_opened_project)
  write(M.snapshot())
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- The widget needs a socket to send commands back.
  if vim.v.servername == "" then
    vim.fn.serverstart()
  end

  if timer then
    timer:stop()
  end

  -- TODO: replace polling with User autocmds emitted by oculus.nvim
  -- (e.g. OculusActivityLoaded, OculusInspectOpened) once they exist.
  timer = vim.uv.new_timer()
  timer:start(0, M.config.interval_ms, vim.schedule_wrap(M.publish))

  local group = vim.api.nvim_create_augroup("OculusOmarchy", { clear = true })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if timer then
        timer:stop()
      end

      last_payload = nil
      write({ version = 1, running = false, pid = vim.fn.getpid() })
    end,
  })
end

return M
