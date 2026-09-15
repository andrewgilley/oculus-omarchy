.pragma library

// Pure helpers for the Oculus bar widget. Kept free of QML types so they can be
// unit-tested with plain node if the widget grows.

// ---- Neovim snapshot (omarchy.json, written by oculus_omarchy) ----------------
// { version, running, updated_at, pid, server, view, tracking, focus, events }
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

// ---- New activity (activity.json, written by oculus-activity) -----------------
// { version, fetched_at, authenticated, total_new, errors: [],
//   projects: [{ key, provider, repository, name, new, latest_at,
//                latest_title, latest_url, error }] }   sorted by `new` desc
function parseActivity(text) {
  var activity = { ok: false, fetchedAt: 0, authenticated: true, totalNew: 0, errors: [], projects: [] }
  var data = decode(text)
  if (!data || data.version !== 1) return activity

  activity.ok = true
  activity.fetchedAt = Number(data.fetched_at) || 0
  activity.authenticated = data.authenticated !== false
  activity.errors = data.errors instanceof Array ? data.errors : []
  activity.projects = data.projects instanceof Array ? data.projects : []

  var total = 0
  for (var i = 0; i < activity.projects.length; i++) total += Number(activity.projects[i].new) || 0
  activity.totalNew = total
  return activity
}

function decode(text) {
  if (!text) return null
  try {
    return JSON.parse(text)
  } catch (e) {
    return null
  }
}

// Projects with something new first; quiet projects fill the rest by recency.
function topProjects(activity, limit) {
  return activity.projects.slice(0, Math.max(0, limit))
}

// Forges return at most one 100-item page per category, so large counts are floors.
function countLabel(n) {
  n = Number(n) || 0
  return n >= 100 ? "99+" : String(n)
}

function ago(epochSec, nowSec) {
  if (!epochSec) return "never"
  var s = Math.max(0, nowSec - epochSec)
  if (s < 60) return "just now"
  if (s < 3600) return Math.floor(s / 60) + "m ago"
  if (s < 86400) return Math.floor(s / 3600) + "h ago"
  return Math.floor(s / 86400) + "d ago"
}

function summary(activity, fetching, nowSec) {
  if (fetching && !activity.ok) return "Checking tracked projects…"
  if (!activity.ok) return "No activity fetched yet"
  var head = activity.totalNew > 0 ? countLabel(activity.totalNew) + " new since last opened" : "Nothing new"
  var tail = fetching ? "refreshing…" : "checked " + ago(activity.fetchedAt, nowSec)
  return head + " · " + tail
}

function projectUrl(project) {
  var host = project.provider === "codeberg" ? "https://codeberg.org/" : "https://github.com/"
  return host + project.repository
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
