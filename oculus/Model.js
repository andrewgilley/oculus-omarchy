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

// ---- Browser page (browser.json, written by the Oculus Page extension's host) --
// { version, url, updated_at, browser_pid }. url is "" when the active tab isn't
// on GitHub or Codeberg: the extension can't see URLs on any other site.
function parseBrowser(text) {
  var data = decode(text)
  if (!data || data.version !== 1) return { ok: false, url: "", pid: 0 }
  return { ok: true, url: String(data.url || ""), pid: Number(data.browser_pid) || 0 }
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
// Leaves come back flattened, each with `group`: the names of the groups it sits
// in from the list root ([] at the top level). `groups` lists every group path
// per list in tree order, the top level first.
function parseTracking(text) {
  var tracking = { ok: false, projects: [], users: [], keys: {}, groups: { projects: [[]], users: [[]] } }
  var data = decode(text)
  if (!data || data.version !== 1) return tracking

  function flatten(nodes, path, output, groups) {
    if (!(nodes instanceof Array)) return
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i]
      if (!node || typeof node !== "object") continue
      if (node.children instanceof Array) {
        var inner = path.concat([String(node.name)])
        groups.push(inner)
        flatten(node.children, inner, output, groups)
      } else {
        node.group = path
        output.push(node)
      }
    }
  }

  flatten(data.projects, [], tracking.projects, tracking.groups.projects)
  flatten(data.users, [], tracking.users, tracking.groups.users)
  tracking.projects = tracking.projects.filter(function(p) { return typeof p.repository === "string" })
  tracking.users = tracking.users.filter(function(u) { return typeof u.username === "string" })
  tracking.projects.forEach(function(p) { tracking.keys[projectKey(p.provider, p.repository)] = true })
  tracking.users.forEach(function(u) { tracking.keys[userKey(u.provider, u.username)] = true })
  tracking.ok = true
  return tracking
}

// Is the thing the page is about already in the tracking file? For a repo page
// (and any item under it) that's the project; for a user page, the user.
function isTracked(item, tracking) {
  if (!item) return false
  return item.kind === "user"
    ? tracking.keys[userKey(item.provider, item.owner)] === true
    : tracking.keys[projectKey(item.provider, item.repository)] === true
}

// Short at-a-glance state for the panel hero.
function trackedLabel(item, tracking) {
  if (!item) return ""
  if (!tracking.ok) return "No tracking file"
  return isTracked(item, tracking) ? "Tracked" : "Not tracked"
}

// What the panel offers for an item: [{ id, label, hint, key, done }]. Tracking
// leads, because recognising a trackable page is the point of the widget: every
// repo page offers the project *and* its owner, and rows for things already in
// the tracking file are dimmed, badged and do nothing. `key` is the digit that
// runs the row; `done` rows have none, so the numbering stays 1..n over the
// rows you can actually press.
function actionsFor(item, tracking) {
  if (!item) return []
  var actions = []
  var trackedRepo = item.repository && tracking.keys[projectKey(item.provider, item.repository)] === true
  var trackedUser = tracking.keys[userKey(item.provider, item.owner)] === true
  var owner = "@" + item.owner

  if (item.kind === "pull_request" || item.kind === "issue" || item.kind === "commit") {
    actions.push({ id: "inspect", label: "Inspect in Oculus", hint: describe(item) })
  }

  if (item.kind !== "user") {
    actions.push(trackedRepo
      ? { id: "trackProject", label: "Tracking " + item.repository, hint: "already in your tracking file", done: true }
      : { id: "trackProject", label: "Track " + item.repository, hint: "choose a group and name" })
    actions.push({ id: "project", label: "Open " + item.repository + " activity", hint: "in Oculus" })
  }

  actions.push(trackedUser
    ? { id: "trackUser", label: "Tracking " + owner,
        hint: item.kind === "user" ? "already in your tracking file" : "the owner is already tracked", done: true }
    : { id: "trackUser", label: "Track " + owner,
        hint: item.kind === "user" ? "choose a group and name" : "the owner · choose a group and name" })
  actions.push({ id: "user", label: "Open " + owner + "'s activity", hint: "in Oculus" })

  var digit = 0
  for (var i = 0; i < actions.length; i++) actions[i].key = actions[i].done ? "" : String(++digit)
  return actions
}

// The action a bare Enter runs: the first one that isn't already done.
function primaryAction(actions) {
  for (var i = 0; i < actions.length; i++) if (!actions[i].done) return actions[i]
  return null
}

function actionForKey(actions, key) {
  for (var i = 0; i < actions.length; i++) if (actions[i].key === key) return actions[i]
  return null
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

// ---- Overlay: search tracked projects and users, the current page, a URL -------
var ICONS = {
  project: "\uf401", user: "\uf007", pull_request: "\uf407", issue: "\uf41b",
  commit: "\uf417", group: "\uf07b", newGroup: "\uf067",
}

function forgeName(provider) { return provider === "codeberg" ? "Codeberg" : "GitHub" }

function forgeUrl(provider, identity) {
  return (provider === "codeberg" ? "https://codeberg.org/" : "https://github.com/") + identity
}

function groupLabel(path) { return path && path.length > 0 ? path.join(" \u203a ") : "Top level" }

// A tracked leaf in the shape parseUrl returns for its page.
function trackedItem(list, node) {
  var provider = node.provider === "codeberg" ? "codeberg" : "github"
  if (list === "users") return { kind: "user", provider: provider, owner: node.username, url: forgeUrl(provider, node.username) }
  var parts = node.repository.split("/")
  return { kind: "project", provider: provider, owner: parts[0], repo: parts[1], repository: node.repository,
    url: forgeUrl(provider, node.repository) }
}

// 0 when some word of the query is missing from the row's text; 2 when the label
// (or a repository's name) starts with the query, so exact-ish hits rise; else 1.
function matchScore(text, label, query) {
  var words = query.trim().toLowerCase().split(/\s+/).filter(Boolean)
  if (words.length === 0) return 1
  var haystack = text.toLowerCase()
  for (var i = 0; i < words.length; i++) if (haystack.indexOf(words[i]) < 0) return 0
  var bare = label.toLowerCase().replace(/^@/, "")
  return bare.indexOf(words[0]) === 0 || bare.split("/").pop().indexOf(words[0]) === 0 ? 2 : 1
}

function itemRow(item, kind, section) {
  return { key: kind + ":" + item.url, section: section, kind: kind, icon: ICONS[item.kind] || ICONS.project,
    label: describe(item), detail: item.url, item: item }
}

// Rows for the overlay's list: a URL typed or pasted into the search, the page
// open in the browser, then every tracked project and user that matches.
// { key, section, kind: link | page | tracked, icon, label, detail, item,
//   list, identity, group }
function paletteRows(tracking, pageItem, query) {
  var rows = []
  var typed = parseUrl(query)
  if (typed) rows.push(itemRow(typed, "link", "Link"))
  if (pageItem && !typed && matchScore(describe(pageItem) + " " + pageItem.url, describe(pageItem), query) > 0) {
    rows.push(itemRow(pageItem, "page", "This page"))
  }
  if (typed) return rows

  ;["projects", "users"].forEach(function(list) {
    var scored = []
    tracking[list].forEach(function(node, index) {
      var item = trackedItem(list, node)
      var identity = list === "users" ? node.username : node.repository
      var label = describe(item)
      // A display name that only repeats the identity (or the repo's name) adds nothing.
      var name = typeof node.name === "string"
        && [identity, identity.split("/").pop()].indexOf(node.name) < 0 ? node.name : ""
      var detail = [groupLabel(node.group), forgeName(item.provider)].concat(name ? [name] : []).join(" \u00b7 ")
      var score = matchScore([label, name, node.group.join(" "), item.provider].join(" "), label, query)
      if (score === 0) return
      scored.push({ score: score, index: index, row: {
        key: list + ":" + item.provider + ":" + identity.toLowerCase(), section: list === "users" ? "Users" : "Projects",
        kind: "tracked", icon: ICONS[item.kind], label: label, detail: detail, item: item,
        list: list, identity: identity, group: node.group } })
    })
    scored.sort(function(a, b) { return b.score - a.score || a.index - b.index })
    scored.forEach(function(entry) { rows.push(entry.row) })
  })
  return rows
}

// What the overlay offers for a row: [{ id, label, hint, done }]. The first
// action that isn't done is what Enter runs.
function rowActions(row, tracking) {
  if (!row) return []
  var item = row.item
  if (row.kind === "tracked") {
    return [
      { id: item.kind === "user" ? "user" : "project", label: "Open activity", hint: "in Oculus" },
      { id: "browser", label: "Open on " + forgeName(item.provider), hint: item.url },
      { id: "move", label: "Move to a group\u2026", hint: "now in " + groupLabel(row.group) },
      { id: "untrack", label: "Untrack", hint: "remove from your tracking file" },
    ]
  }
  var actions = actionsFor(item, tracking).map(function(action) {
    var copy = { id: action.id, label: action.label, hint: action.hint, done: action.done === true }
    if (!copy.done && (copy.id === "trackProject" || copy.id === "trackUser")) copy.hint = "choose a group and name next"
    return copy
  })
  if (row.kind === "link") actions.push({ id: "browser", label: "Open on " + forgeName(item.provider), hint: item.url })
  return actions
}

// Where to put a project or user: every group in its list, filtered by the
// query, plus a new top-level group named after the query when none matches it
// exactly. { key, section, kind: group | newGroup, icon, label, detail, path }
function groupRows(tracking, list, query, current) {
  var q = query.trim()
  var rows = []
  var exact = false
  var groups = tracking.groups[list] || [[]]
  for (var i = 0; i < groups.length; i++) {
    var path = groups[i]
    var label = groupLabel(path)
    if (q && path.length > 0 && path[path.length - 1].toLowerCase() === q.toLowerCase()) exact = true
    if (matchScore(label, label, q) === 0) continue
    var here = current && current.join("\n") === path.join("\n")
    rows.push({ key: "group:" + path.join("\n"), section: "Groups", kind: "group", icon: ICONS.group,
      label: label, detail: here ? "current group" : "", path: path, current: here })
  }
  if (q && !exact && !/[\u0000-\u001f]/.test(q)) {
    rows.push({ key: "newGroup:" + q, section: "Groups", kind: "newGroup", icon: ICONS.newGroup,
      label: "New group \u201c" + q + "\u201d", detail: "at the top level", path: [q] })
  }
  return rows
}

// The last step of tracking: what to call the new entry. One row, naming it
// after the query, or after its identity when the query is empty, which leaves
// the name unset. { key, section, kind: name, icon, label, detail, name }
function nameRows(target, query) {
  var name = query.trim()
  if (/[\u0000-\u001f]/.test(name)) return []
  return [{ key: "name", section: "Name", kind: "name", icon: ICONS[target.list === "users" ? "user" : "project"],
    label: name ? "Track as \u201c" + name + "\u201d" : "Track as " + target.label,
    detail: "in " + groupLabel(target.path) + (name ? "" : " \u00b7 no display name"), name: name }]
}

// This plugin's inline settings from shell.json: its bar entry, or a plugins[] entry.
function pluginSettings(text, id) {
  var data = decode(text)
  if (!data || typeof data !== "object") return {}
  var layout = data.bar && data.bar.layout ? data.bar.layout : {}
  var entries = [].concat(layout.left || [], layout.center || [], layout.right || [], data.plugins || [])
  for (var i = 0; i < entries.length; i++) {
    if (entries[i] && typeof entries[i] === "object" && entries[i].id === id) return entries[i]
  }
  return {}
}
