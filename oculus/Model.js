.pragma library

// Pure helpers for the Oculus bar widget. Kept free of QML types so they can be
// unit-tested with plain node if the widget grows.

// ---- Neovim snapshot (omarchy.json, written by oculus_omarchy) ----------------
// { version, running, updated_at, pid, server }
function parseSnapshot(text, nowSec, staleAfterSec) {
  var state = { ok: false, live: false, server: "", pid: 0 }
  var data = decode(text)
  if (!data || data.version !== 1) return state

  var updatedAt = Number(data.updated_at) || 0
  state.ok = true
  // A crashed Neovim never writes running=false, so fall back to age.
  state.live = data.running === true && (nowSec - updatedAt) <= staleAfterSec
  state.server = String(data.server || "")
  state.pid = Number(data.pid) || 0
  return state
}

function decode(text) {
  if (!text) return null
  try {
    return JSON.parse(text)
  } catch (e) {
    return null
  }
}

// ---- Forge URLs ----------------------------------------------------------------
var HOSTS = { "github.com": "github", "www.github.com": "github", "codeberg.org": "codeberg" }

// First path segments that are forge pages, not users.
var RESERVED = {
  github: ["about", "apps", "codespaces", "collections", "contact", "dashboard", "enterprise",
    "events", "explore", "features", "issues", "login", "logout", "marketplace", "new",
    "notifications", "organizations", "pricing", "pulls", "search", "security", "settings",
    "signup", "sponsors", "stars", "topics", "trending"],
  codeberg: ["admin", "api", "assets", "explore", "issues", "notifications", "pulls",
    "repo", "user"],
}

var NAME = /^[A-Za-z0-9][A-Za-z0-9_.-]*$/

// https://github.com/owner/repo/pull/1 → { kind, provider, owner, repo, repository,
// number | sha, url }. kind: project | user | pull_request | issue | commit.
// Returns null for anything that isn't a GitHub/Codeberg user, repo or item.
function parseUrl(text) {
  var raw = String(text || "").trim().split(/\s/)[0]
  var m = raw.match(/^(?:https?:\/\/)?([^\/?#]+)(\/[^?#]*)?/i)
  if (!m) return null

  var provider = HOSTS[m[1].toLowerCase()]
  if (!provider) return null

  var parts = (m[2] || "").split("/").filter(Boolean)
  if (parts.length === 0) return null
  if (parts[0] === "orgs" && parts.length >= 2) parts = [parts[1]]
  if (RESERVED[provider].indexOf(parts[0].toLowerCase()) >= 0 || !NAME.test(parts[0])) return null

  var host = provider === "codeberg" ? "https://codeberg.org/" : "https://github.com/"
  var owner = parts[0]
  if (parts.length === 1) return { kind: "user", provider: provider, owner: owner, url: host + owner }

  var repo = parts[1].replace(/\.git$/, "")
  if (!NAME.test(repo)) return null

  var item = { kind: "project", provider: provider, owner: owner, repo: repo, repository: owner + "/" + repo }
  var section = (parts[2] || "").toLowerCase()
  var id = parts[3] || ""

  if ((section === "pull" || section === "pulls") && /^\d+$/.test(id)) {
    item.kind = "pull_request"
    item.number = Number(id)
  } else if (section === "issues" && /^\d+$/.test(id)) {
    item.kind = "issue"
    item.number = Number(id)
  } else if (section === "commit" && /^[0-9a-f]{7,40}$/i.test(id)) {
    item.kind = "commit"
    item.sha = id.toLowerCase()
  }

  item.url = host + item.repository + (item.kind === "project" ? "" : "/" + parts[2] + "/" + id)
  return item
}

function projectKey(provider, repository) {
  return (provider === "codeberg" ? "codeberg" : "github") + ":" + String(repository).toLowerCase()
}

function userKey(provider, username) {
  return (provider === "codeberg" ? "codeberg" : "github") + ":@" + String(username).toLowerCase()
}

// Arguments for oculus-open / oculus-track.
function projectTarget(item) { return item.provider + ":" + item.repository }
function userTarget(item) { return item.provider + ":" + item.owner }

function describe(item) {
  if (!item) return ""
  switch (item.kind) {
    case "user": return "@" + item.owner
    case "project": return item.repository
    case "pull_request": return "Pull request · " + item.repository + "#" + item.number
    case "issue": return "Issue · " + item.repository + "#" + item.number
    case "commit": return "Commit · " + item.repository + "@" + item.sha.slice(0, 7)
  }
  return ""
}

// ---- Tracking file (~/.config/oculus/tracking.json) ---------------------------
// { version: 1, projects: [tree], users: [tree] }; groups have `children`.
function parseTracking(text) {
  var tracking = { ok: false, projects: [], users: [], keys: {} }
  var data = decode(text)
  if (!data || data.version !== 1) return tracking

  function flatten(nodes, output) {
    if (!(nodes instanceof Array)) return
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i]
      if (!node || typeof node !== "object") continue
      if (node.children instanceof Array) flatten(node.children, output)
      else output.push(node)
    }
  }

  flatten(data.projects, tracking.projects)
  flatten(data.users, tracking.users)
  tracking.projects = tracking.projects.filter(function(p) { return typeof p.repository === "string" })
  tracking.users = tracking.users.filter(function(u) { return typeof u.username === "string" })
  tracking.projects.forEach(function(p) { tracking.keys[projectKey(p.provider, p.repository)] = true })
  tracking.users.forEach(function(u) { tracking.keys[userKey(u.provider, u.username)] = true })
  tracking.ok = true
  return tracking
}

// What the panel offers for an item: [{ id, label, hint, done }]. `done`
// rows are shown dimmed and do nothing (e.g. already tracked).
function actionsFor(item, tracking) {
  if (!item) return []
  var actions = []
  var repoTracked = item.repository && tracking.keys[projectKey(item.provider, item.repository)] === true

  if (item.kind === "pull_request" || item.kind === "issue" || item.kind === "commit") {
    actions.push({ id: "inspect", label: "Inspect in Oculus", hint: describe(item) })
  }

  if (item.kind === "user") {
    var userTracked = tracking.keys[userKey(item.provider, item.owner)] === true
    actions.push({ id: "user", label: "Open @" + item.owner + "'s activity", hint: item.provider })
    actions.push({ id: "trackUser", label: userTracked ? "Tracking @" + item.owner : "Track @" + item.owner,
      hint: "add to tracking file", done: userTracked })
  } else {
    actions.push({ id: "project", label: "Open " + item.repository + " activity", hint: item.provider })
    actions.push({ id: "trackProject", label: repoTracked ? "Tracking " + item.repository : "Track " + item.repository,
      hint: "add to tracking file", done: repoTracked })
    actions.push({ id: "user", label: "Open @" + item.owner + "'s activity", hint: "owner" })
  }

  return actions
}

// Single-quote a value for a POSIX shell command line.
function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

// Command that drives the running Neovim over its RPC socket.
function remoteCommand(server, exCommand) {
  if (!server) return ""
  return "nvim --server " + shellQuote(server) + " --remote-send " + shellQuote("<C-\\><C-n><Cmd>" + exCommand + "<CR>")
}
