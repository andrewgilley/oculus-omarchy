-- Save and unsave pull requests, issues and commits in oculus.nvim's saved
-- items from outside Neovim.
--
-- The item is fetched from its forge and stored as the activity event Oculus's
-- project feeds build for it, under the key Oculus itself gives that event, so
-- Oculus lists, stars and unsaves it like an item saved from a feed. Writes go
-- through oculus.saved and oculus.storage; a running Neovim that published its
-- socket in omarchy.json is then asked to reload its saved items.

local remote = require("oculus_omarchy.remote")
local M = {}

M.config = {
  -- oculus.nvim's default state_file.
  state_file = vim.fn.stdpath("state") .. "/oculus.json",
}

local HOSTS = { ["github.com"] = "github", ["www.github.com"] = "github", ["codeberg.org"] = "codeberg" }
local API = { github = "https://api.github.com/repos/", codeberg = "https://codeberg.org/api/v1/repos/" }
local FORGE = { github = "GitHub", codeberg = "Codeberg" }
local NAME = "^[%w][%w_.-]*$"

-- https://github.com/owner/repo/pull/1 → { provider, repository, kind, number | sha }.
-- kind: pull_request | issue | commit. nil for anything else.
function M.parse_url(url)
  local host, owner, repo, section, id =
    tostring(url or ""):match("^https?://([^/]+)/([^/]+)/([^/]+)/([^/]+)/([^/?#]+)")
  local provider = host and HOSTS[host:lower()]

  if not provider or not owner:match(NAME) then
    return nil
  end

  repo = repo:gsub("%.git$", "")

  if not repo:match(NAME) then
    return nil
  end

  local item = { provider = provider, repository = owner .. "/" .. repo }
  section = section:lower()

  if (section == "pull" or section == "pulls") and id:match("^%d+$") then
    item.kind, item.number = "pull_request", tonumber(id)
  elseif section == "issues" and id:match("^%d+$") then
    item.kind, item.number = "issue", tonumber(id)
  elseif section == "commit" and #id >= 7 and #id <= 40 and id:match("^%x+$") then
    item.kind, item.sha = "commit", id:lower()
  else
    return nil
  end

  return item
end

-- What was saved, from the event: an /issues/N URL can turn out to be a pull request.
local function describe(event)
  local payload = event.payload

  if event.type == "PushEvent" then
    return ("commit %s@%s"):format(event.repo.name, payload.head:sub(1, 7))
  end

  return ("%s %s#%d"):format(event.type == "IssuesEvent" and "issue" or "pull request", event.repo.name,
    payload.number or payload.issue.number)
end

-- GET a forge API path with the token Oculus would use. JSON nulls come back
-- as nil rather than vim.NIL.
local function fetch(provider, path)
  local command = {
    "curl", "-sS", "-L", "--max-time", "15",
    "-H", provider == "github" and "Accept: application/vnd.github+json" or "Accept: application/json",
    "-H", "User-Agent: oculus-omarchy",
    "-w", "\n%{http_code}",
  }

  local token = require("oculus.auth").token(provider, {})
  local stdin

  -- The token goes through stdin so it never shows in the process list.
  if token and token ~= "" then
    vim.list_extend(command, { "-H", "@-" })
    stdin = (provider == "codeberg" and "Authorization: token " or "Authorization: Bearer ") .. token .. "\n"
  end

  command[#command + 1] = API[provider] .. path
  local result = vim.system(command, { text = true, stdin = stdin }):wait()

  if result.code ~= 0 then
    return nil, FORGE[provider] .. ": " .. (vim.trim(result.stderr or "") ~= "" and vim.trim(result.stderr) or "unreachable")
  end

  local body, status = (result.stdout or ""):match("^(.*)\n(%d+)$")
  local ok, data = pcall(vim.json.decode, body or "", { luanil = { object = true, array = true } })

  if tonumber(status) ~= 200 or not ok or type(data) ~= "table" then
    local message = ok and type(data) == "table" and data.message or nil
    return nil, ("%s: %s %s"):format(FORGE[provider], status or "?", message or "request failed")
  end

  return data
end

-- The events below mirror the ones oculus.github and oculus.codeberg build for
-- a project's feed, extended to open and closed pull requests.
local function pull_request_event(repository, pr)
  local merged = pr.merged == true or pr.merged_at ~= nil
  local action = merged and "merged" or pr.state == "closed" and "closed" or "opened"

  return {
    id = ("project-pr:%s:%s"):format(repository, pr.number),
    type = "PullRequestEvent",
    actor = merged and pr.merged_by or pr.user,
    repo = { name = repository },
    created_at = merged and pr.merged_at or action == "closed" and pr.closed_at or pr.created_at,
    url = pr.html_url,
    payload = {
      action = action,
      number = pr.number,
      pull_request = {
        number = pr.number,
        title = pr.title,
        body = pr.body,
        user = pr.user,
        state = pr.state,
        draft = pr.draft,
        merged = merged,
        merged_at = pr.merged_at,
        merged_by = pr.merged_by,
        html_url = pr.html_url,
        created_at = pr.created_at,
        updated_at = pr.updated_at,
      },
    },
  }
end

local function issue_event(repository, issue)
  local state = issue.state == "closed" and "closed" or "open"

  return {
    id = ("project-issue:%s:%s"):format(repository, issue.number),
    type = "IssuesEvent",
    actor = issue.user,
    repo = { name = repository },
    created_at = issue.updated_at or issue.created_at,
    url = issue.html_url,
    payload = {
      action = state == "closed" and "closed" or "opened",
      issue = {
        number = issue.number,
        title = issue.title,
        body = issue.body,
        user = issue.user,
        assignee = issue.assignee,
        assignees = issue.assignees or {},
        labels = issue.labels or {},
        state = state,
        html_url = issue.html_url,
        created_at = issue.created_at,
        updated_at = issue.updated_at,
      },
    },
  }
end

local function commit_event(repository, commit)
  local details = type(commit.commit) == "table" and commit.commit or {}
  local author = type(details.author) == "table" and details.author or {}
  local committer = type(details.committer) == "table" and details.committer or {}
  local account = type(commit.author) == "table" and commit.author or { name = author.name }

  return {
    id = "project-commit:" .. commit.sha,
    type = "PushEvent",
    actor = account,
    repo = { name = repository },
    created_at = commit.created or author.date or committer.date,
    url = commit.html_url,
    payload = {
      size = 1,
      head = commit.sha,
      commits = { { sha = commit.sha, message = details.message, author = account } },
    },
  }
end

-- The item as the event Oculus would show for it.
local function event_for(item)
  local base = item.repository .. "/"

  if item.kind == "commit" then
    local path = (item.provider == "codeberg" and "git/commits/" or "commits/") .. item.sha
    local commit, err = fetch(item.provider, base .. path)
    if not commit or type(commit.sha) ~= "string" then
      return nil, err or ("no commit " .. item.sha)
    end
    return commit_event(item.repository, commit)
  end

  if item.kind == "issue" then
    local issue, err = fetch(item.provider, base .. "issues/" .. item.number)
    if not issue then
      return nil, err
    end
    -- GitHub serves pull requests from the issues endpoint too.
    if not issue.pull_request then
      return issue_event(item.repository, issue)
    end
  end

  local pr, err = fetch(item.provider, base .. "pulls/" .. item.number)
  return pr and pull_request_event(item.repository, pr), err
end

local function reload_running_neovim()
  remote.exec([[
    local saved = package.loaded["oculus.saved"]
    local ok, oculus = pcall(require, "oculus")
    if saved and saved.loaded() and ok and oculus.config and oculus.config.state_file then
      saved.load((require("oculus.storage").load(oculus.config.state_file) or {}).saved_items)
    end
  ]])
end

-- Load the saved items, apply fn(store), and write the state file back.
local function edit(file, fn)
  local ok, storage = pcall(require, "oculus.storage")

  if not ok then
    return false, "oculus.nvim not found; set OCULUS_NVIM_PATH"
  end

  file = file or M.config.state_file
  local state = storage.load(file) or {}
  local store = require("oculus.saved")
  store.load(state.saved_items)

  local done, message = fn(store)

  if not done then
    return false, message
  end

  -- storage.save rebuilds the whole state file from a config table; handing
  -- it what's on disk leaves every other setting as it was.
  local saved, err = storage.save(file, state)

  if not saved then
    return false, err
  end

  reload_running_neovim()
  return true, message
end

-- Save the pull request, issue or commit at url. Saving it again refreshes the
-- entry and moves it to the top, as it does in Oculus.
function M.add(url, file)
  local item = M.parse_url(url)

  if not item then
    return false, "not a GitHub or Codeberg pull request, issue or commit: " .. tostring(url)
  end

  local event, err = event_for(item)

  if not event then
    return false, err
  end

  return edit(file, function(store)
    store.add({
      key = require("oculus.window")._activity_dedupe_key(event),
      saved_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      source = { kind = "project", provider = item.provider, repository = item.repository },
      event = event,
    })
    return true, "saved " .. describe(event)
  end)
end

-- Unsave the entries with these keys.
function M.remove(keys, file)
  return edit(file, function(store)
    local removed = 0

    for _, key in ipairs(keys) do
      if store.remove(key) then
        removed = removed + 1
      end
    end

    if removed == 0 then
      return false, "not in your saved items"
    end

    return true, ("removed %d saved item%s"):format(removed, removed == 1 and "" or "s")
  end)
end

return M
