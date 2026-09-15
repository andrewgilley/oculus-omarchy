# oculus × omarchy

Omarchy shell plugin that shows the [oculus.nvim](../lua/oculus.nvim)
projects with the most new activity since you last opened them.

```
omarchy/
├── oculus/                          # Omarchy plugin (id: andrewgilley.oculus)
│   ├── manifest.json                # bar-widget manifest + settings schema
│   ├── Panel.qml                    # bar icon + count, popout project list, scheduler
│   └── Model.js                     # file parsing / formatting / command helpers
├── nvim/
│   ├── bin/oculus-activity          # headless fetcher CLI (nvim -l)
│   └── lua/oculus_omarchy/
│       ├── init.lua                 # bridge running inside your Neovim
│       └── activity.lua             # fetch + count + seen bookkeeping
└── install.sh
```

## How it works

```
                         ┌── oculus.github / oculus.codeberg (repository_updates)
oculus-activity ─────────┤   tracked projects from ~/.config/oculus/tracking.json
  (widget runs it)       └─▶ ~/.local/state/oculus/activity.json ──┐
                                                                    │ FileView
oculus_omarchy (in nvim) ─▶ seen.json, omarchy.json ────────────────┤ (watchChanges)
                                                                    ▼
Neovim RPC socket ◀── nvim --server … --remote-send ────────── Panel.qml
```

- **What counts as new:** pushes (commits) and merged pull requests newer than
  the project's *last opened* time in `seen.json`. The first time a project is
  fetched, "now" becomes its starting point, so history isn't flagged as new.
- **What counts as opened:** opening the project's feed in Oculus (the bridge
  notices `activity_project` change), clicking it in the panel, or `a` (mark
  all seen).
- **Schedule:** the widget checks once a minute and runs the fetcher when the
  data is older than `refreshIntervalSec` (default 15 min). Because it compares
  ages instead of counting ticks, it catches up right after suspend. Opening
  the popout refreshes if the data is older than 5 min; `r` or right-click
  forces a refresh.
- **Rate limits:** each run costs about 2 requests per project (about 42 for
  your 21 projects). The token comes from `GITHUB_TOKEN`, then `gh auth token`
  (5000/hour). Without a token GitHub allows only 60/hour, so the fetcher
  refuses to run more than hourly and the panel says so. Codeberg uses
  `CODEBERG_TOKEN` if it's set.
- Counts are floors past one page (shown as `99+`).

## Setup

1. Put the bridge on Neovim's runtime path, for example with lazy.nvim:

   ```lua
   {
     dir = "~/Dev/oculus-omarchy/nvim",
     name = "oculus-omarchy",
     dependencies = { "andrewgilley/oculus.nvim" },
     config = function() require("oculus_omarchy").setup() end,
   }
   ```

2. `./install.sh`: validates and copies the plugin to
   `~/.config/omarchy/plugins/andrewgilley.oculus/`, and links
   `~/.local/bin/oculus-activity`.
3. `omarchy bar put andrewgilley.oculus`.

The fetcher finds oculus.nvim at `~/.local/share/nvim/lazy/oculus.nvim`;
override with `OCULUS_NVIM_PATH`.

## Using it

| Where        | Action                                                       |
|--------------|--------------------------------------------------------------|
| Bar          | left: popout · right: refresh now · middle: `:OculusOpen`    |
| Panel row    | click: new Ghostty + Neovim on an empty workspace, opened on that project's activity feed (`oculus-open-project`); marks the project seen |
| Panel keys   | `r` refresh · `a` mark all seen · `o` open Oculus · Enter opens the top project |
| CLI          | `oculus-activity [--force]`, `--seen github:owner/repo`, `--seen-all` |
| IPC          | `omarchy-shell andrewgilley.oculus {toggle,refresh,markAllSeen,status}` |

## Debugging

- Plugin load errors: `qs log -i "$(qs list | awk '/^Instance/{print $2}' | tr -d :)" | grep oculus`.
  A failed reload keeps the *old* widget running, so check this first if
  changes don't show up. If the error still names a line you've already fixed,
  the shell is compiling a cached copy: `omarchy restart shell` clears it
  (`rescanPlugins` didn't).
- Don't name QML properties `top` (or other names the base `Item` defines as
  FINAL); the widget fails to load with "Cannot override FINAL property".
- Data: `jq . ~/.local/state/oculus/{activity,seen}.json`.
- Hyprland 0.56+ uses a Lua config, so `hyprctl dispatch` takes a Lua
  expression: `hyprctl dispatch 'hl.dsp.focus({ workspace = "emptym" })'`.
  The old `hyprctl dispatch workspace emptym` fails (exit 7). Trace the
  launcher with `bash -x ~/.local/bin/oculus-open-project github:owner/repo`.
- Ghostty's `-e` silently drops arguments starting with `+` (it reserves them
  for its own `+actions`), so pass Neovim commands as `-c "…"`, never `+…`.

## TODO

- A public oculus.nvim API to open a specific project's feed, so a panel click
  lands on it (the opener in `window.lua` is local today), and `User` autocmds
  (e.g. `OculusActivityLoaded`) to replace the bridge's 5 s polling.
- Conditional requests (ETag / `If-None-Match`) so quiet repos don't use up
  the rate limit.
- Include assigned issues and tracked users' activity in the counts.
- Arrow-key cursor over the project list; focus the terminal after remote-send.
- Several Neovim instances: `omarchy.json` is last-writer-wins.
