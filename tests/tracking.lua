-- Run with: OCULUS_NVIM_PATH=/path/to/oculus.nvim nvim -l tests/tracking.lua
local root = vim.fn.fnamemodify(vim.uv.fs_realpath(arg[0]), ":h:h")
local plugin = assert(vim.env.OCULUS_NVIM_PATH, "set OCULUS_NVIM_PATH to the oculus.nvim checkout")
local scratch = vim.fn.tempname()
local env = vim.fn.environ()
env.OCULUS_NVIM_PATH = nil
env.OCULUS_OMARCHY_PROBE = nil
env.NVIM_APPNAME = "oculus-test"
env.XDG_CONFIG_HOME = scratch .. "/config"
env.XDG_DATA_HOME = scratch .. "/data"
env.XDG_STATE_HOME = scratch .. "/state"
env.XDG_RUNTIME_DIR = scratch .. "/run"
local tracking = env.XDG_CONFIG_HOME .. "/oculus/tracking.json"
local snapshot = env.XDG_STATE_HOME .. "/oculus/omarchy.json"
local socket = scratch .. "/editor.sock"
local editor, channel

local function read(file)
  return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
end

local function cli(...)
  local command = { vim.v.progpath, "-l", root .. "/nvim/bin/oculus-track", "--snapshot", snapshot, "--file", tracking }
  vim.list_extend(command, { ... })
  local result = vim.system(command, { env = env, clear_env = true, text = true }):wait(15000)
  assert(result.code == 0, result.stderr)
  return result.stdout
end

local function rpc(code, ...)
  return vim.rpcrequest(channel, "nvim_exec_lua", code, { ... })
end

local ok, err = xpcall(function()
  vim.fn.mkdir(env.XDG_CONFIG_HOME .. "/oculus", "p")
  vim.fn.mkdir(env.XDG_CONFIG_HOME .. "/" .. env.NVIM_APPNAME, "p")
  vim.fn.mkdir(env.XDG_RUNTIME_DIR, "p")
  vim.fn.writefile({ '{"version":1,"projects":[],"users":[]}' }, tracking)
  vim.fn.writefile({
    ("vim.opt.rtp:append(%q)"):format(root .. "/nvim"),
    ("vim.opt.rtp:append(%q)"):format(plugin),
    ("require('oculus').setup({tracking_file=%q, state_file=%q, sidebar=false})"):format(tracking, scratch .. "/oculus.json"),
    "require('oculus_omarchy').setup()",
  }, env.XDG_CONFIG_HOME .. "/" .. env.NVIM_APPNAME .. "/init.lua")

  -- No running editor and no standard lazy checkout: resolve the local plugin
  -- through the configured editor without publishing a discovery socket.
  assert(cli("--group", '["Editors"]', "--name", "Offline project", "github", "test/offline"):find("tracking test/offline", 1, true))
  assert(read(tracking).projects[1].children[1].name == "Offline project")
  assert(vim.fn.filereadable(snapshot) == 0, "discovery overwrote the real bridge snapshot")

  editor = vim.system({ vim.v.progpath, "--headless", "-i", "NONE", "-n", "--listen", socket }, {
    env = env, clear_env = true, text = true,
  })
  assert(vim.wait(5000, function() return vim.fn.filereadable(snapshot) == 1 end, 20), "bridge did not publish at the shared state path")
  local published = read(snapshot)
  assert(published.running == true and published.server == socket)
  assert(published.oculus_path == plugin, "bridge did not publish the loaded Oculus checkout")
  channel = vim.fn.sockconnect("pipe", socket, { rpc = true })
  assert(channel > 0)
  rpc("require('oculus').open()")

  cli("--name", "Live project", "github", "test/live")
  assert(rpc([[return require('oculus').config.projects[2].name]]) == "Live project")
  assert(rpc([[
    local w = require('oculus.window')
    return table.concat(vim.api.nvim_buf_get_lines(w.state.buf, 0, -1, false), '\n')
  ]]):find("Live project", 1, true), "the open Oculus list did not redraw")

  cli("--group", '["Editors","Plugins"]', "--name", "Directory", "--path", "lua/plugins", "github", "test/live")
  assert(rpc([[return require('oculus').config.projects[2].path]]) == "lua/plugins")
  cli("--move", '["Editors"]', "github", "test/live")
  cli("--remove", "--path", "lua/plugins", "github", "test/live")
  assert(#rpc("return require('oculus').config.projects") == 2)
  cli("codeberg", "test/codeberg")
  cli("github", "testuser")
  assert(rpc("return require('oculus').config.contributors[1].username") == "testuser")

  -- A widget pointed at another tracking file must not reset this editor.
  local other = scratch .. "/other.json"
  vim.fn.writefile({ '{"version":1,"projects":[],"users":[]}' }, other)
  local before = rpc("return require('oculus.window').state.request_id")
  cli("--file", other, "github", "test/other")
  assert(rpc("return require('oculus.window').state.request_id") == before)
  assert(#rpc("return require('oculus').config.projects") == 3)

  vim.rpcnotify(channel, "nvim_command", "qa!")
  assert(editor:wait(5000).code == 0)
  editor = nil
  local stopped = read(snapshot)
  assert(stopped.running == false and stopped.oculus_path == plugin)
  cli("github", "test/after-exit")
  assert(#read(tracking).projects == 3, "offline tracking after editor exit failed")
  print("Passed: local checkout discovery, shared snapshot, live redraw, groups, names, directories, providers, users, file isolation and offline tracking")
end, debug.traceback)

if channel then pcall(vim.fn.chanclose, channel) end
if editor then editor:kill(15); editor:wait(2000) end
vim.fn.delete(scratch, "rf")
if not ok then error(err, 0) end
