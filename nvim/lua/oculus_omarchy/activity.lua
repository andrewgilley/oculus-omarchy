-- New-activity counts for the Omarchy widget.
--
-- For every tracked project, fetch recent pushes and merged pull requests with
-- oculus's own forge clients and count those newer than the project's
-- "last opened" time. Results go to activity.json; last-opened times live in
-- seen.json and are updated by the bridge (opening a project in Oculus) or the
-- widget (mark seen).

local M = {}

local state_home = vim.env.XDG_STATE_HOME or (vim.env.HOME .. "/.local/state")

M.config = {
  dir = state_home .. "/oculus",
  tracking_file = vim.fn.expand("~/.config/oculus/tracking.json"),
  oculus_state_file = state_home .. "/nvim/oculus.json",
  activity_types = { "push", "merged_pull_request" },
  concurrency = 4,
  -- GitHub allows 60 unauthenticated requests/hour; never refetch faster.
  unauthenticated_min_interval = 3600,
  timeout_ms = 120000,
}

local function path(name)
  return M.config.dir .. "/" .. name
end

local function read_json(file)
  local handle = io.open(file, "rb")

  if not handle then
    return nil
  end

  local ok, data = pcall(vim.json.decode, handle:read("*a"))
  handle:close()
  return ok and type(data) == "table" and data or nil
end

local function write_json(file, data)
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  local temporary = file .. ".tmp." .. vim.fn.getpid()

  if pcall(vim.fn.writefile, { vim.json.encode(data) }, temporary) then
    vim.uv.fs_rename(temporary, file)
  end
end

function M.key(project)
  return (project.provider == "codeberg" and "codeberg" or "github")
    .. ":"
    .. project.repository:lower()
end

-- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant).
local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- ISO 8601 ("2026-09-15T10:00:00Z", "...+02:00", fractional seconds) to epoch.
function M.to_epoch(value)
  if type(value) ~= "string" then
    return nil
  end

  local y, mo, d, h, mi, s, rest =
    value:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)(.*)$")

  if not y then
    return nil
  end

  local epoch = days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)

  local sign, oh, om = rest:match("([+-])(%d%d):?(%d%d)$")

  if sign then
    local offset = tonumber(oh) * 3600 + tonumber(om) * 60
    epoch = sign == "+" and epoch - offset or epoch + offset
  end

  return epoch
end

-- Same membership oculus uses: the tracking file, else its legacy state file.
function M.projects()
  local config = { tracking_file = M.config.tracking_file }
  local ok, tracking = pcall(require, "oculus.tracking")

  if ok and vim.uv.fs_stat(vim.fn.expand(M.config.tracking_file)) then
    if tracking.load(config) then
      return config.projects
    end
  end

  local saved = read_json(M.config.oculus_state_file) or {}
  return saved.projects or {}
end

local function github_token()
  if vim.env.GITHUB_TOKEN and vim.env.GITHUB_TOKEN ~= "" then
    return vim.env.GITHUB_TOKEN
  end

  if vim.fn.executable("gh") == 1 then
    local result = vim.system({ "gh", "auth", "token" }, { text = true }):wait()

    if result.code == 0 then
      local token = vim.trim(result.stdout or "")
      return token ~= "" and token or nil
    end
  end
end

local function event_title(event)
  local payload = event.payload or {}

  if payload.pull_request and payload.pull_request.title then
    return payload.pull_request.title
  end

  local commit = payload.commits and payload.commits[1]
  local message = commit and commit.message or ""
  return (message:match("^[^\n]*"))
end

local function event_url(event, project)
  local payload = event.payload or {}

  if payload.pull_request and payload.pull_request.html_url then
    return payload.pull_request.html_url
  end

  local host = project.provider == "codeberg" and "https://codeberg.org/"
    or "https://github.com/"

  if payload.head then
    return host .. project.repository .. "/commit/" .. payload.head
  end

  return host .. project.repository
end

function M.read_seen()
  return read_json(path("seen.json")) or {}
end

function M.read_activity()
  return read_json(path("activity.json"))
end

local function sort_projects(list)
  table.sort(list, function(left, right)
    if left.new ~= right.new then
      return left.new > right.new
    end

    return (left.latest_at or 0) > (right.latest_at or 0)
  end)
end

-- Record "opened now" for the given keys (or every project when keys is nil)
-- and zero their counts in activity.json so the bar clears immediately.
function M.mark_seen(keys)
  local now = os.time()
  local seen = M.read_seen()
  local activity = M.read_activity()
  local wanted = keys and {} or nil

  for _, key in ipairs(keys or {}) do
    wanted[key] = true
    seen[key] = now
  end

  if activity and type(activity.projects) == "table" then
    for _, item in ipairs(activity.projects) do
      if not wanted or wanted[item.key] then
        item.new = 0
        seen[item.key] = now
      end
    end

    sort_projects(activity.projects)
    write_json(path("activity.json"), activity)
  end

  write_json(path("seen.json"), seen)
end

-- Fetch every project and write activity.json. Blocks (for `nvim -l`).
function M.refresh(opts)
  opts = opts or {}
  local previous = M.read_activity()
  local token = github_token()
  local now = os.time()

  if
    not token
    and not opts.force
    and previous
    and now - (previous.fetched_at or 0) < M.config.unauthenticated_min_interval
  then
    return previous, "skipped: unauthenticated rate limit window"
  end

  local seen = M.read_seen()
  local projects = M.projects()
  local results, errors = {}, {}
  local queue, running, done = vim.deepcopy(projects), 0, 0

  local function finish(project, events, err)
    local key = M.key(project)

    -- First sighting: start counting from now instead of flagging history.
    seen[key] = seen[key] or now

    local item = {
      key = key,
      provider = project.provider,
      repository = project.repository,
      name = project.name or project.repository,
      new = 0,
      error = err,
    }

    for _, event in ipairs(events or {}) do
      local at = M.to_epoch(event.created_at)

      if at and at > seen[key] then
        item.new = item.new + 1
      end

      if at and at > (item.latest_at or 0) then
        item.latest_at = at
        item.latest_title = event_title(event)
        item.latest_url = event_url(event, project)
      end
    end

    if err then
      errors[#errors + 1] = project.repository .. ": " .. tostring(err)
    end

    results[#results + 1] = item
    running, done = running - 1, done + 1
  end

  local function pump()
    while running < M.config.concurrency and #queue > 0 do
      local project = table.remove(queue, 1)
      local ok, client = pcall(require, "oculus." .. (project.provider or "github"))
      running = running + 1

      if not ok or type(client.repository_updates) ~= "function" then
        finish(project, nil, "unsupported provider")
      else
        client.repository_updates(project.repository, {
          activity_types = M.config.activity_types,
          token = token,
          codeberg_token = vim.env.CODEBERG_TOKEN,
          force = true,
        }, function(events, err)
          finish(project, events, err)
          pump()
        end)
      end
    end
  end

  pump()
  vim.wait(M.config.timeout_ms, function() return done == #projects end, 100)

  sort_projects(results)

  local activity = {
    version = 1,
    fetched_at = os.time(),
    authenticated = token ~= nil,
    total_new = 0,
    errors = errors,
    projects = results,
  }

  for _, item in ipairs(results) do
    activity.total_new = activity.total_new + item.new
  end

  write_json(path("seen.json"), seen)
  write_json(path("activity.json"), activity)
  return activity
end

return M
