# oculus-omarchy

Omarchy shell plugin that takes the GitHub or Codeberg page you're looking at
into [oculus.nvim](https://github.com/andrewgilley/oculus.nvim): inspect a pull
request, issue or commit, open a project's or user's activity feed, or add the
project or user to your tracking file.

```
oculus-omarchy/
├── oculus/                          # Omarchy plugin (id: andrewgilley.oculus)
│   ├── manifest.json                # bar-widget manifest + settings schema
│   ├── Panel.qml                    # bar icon, popout with item actions + tracked list
│   └── Model.js                     # URL parsing, tracking file, action list
├── nvim/
│   ├── bin/oculus-open              # new Ghostty + Neovim running an Oculus command
│   ├── bin/oculus-track             # add to tracking.json (nvim -l)
│   └── lua/oculus_omarchy/
│       ├── init.lua                 # bridge: publishes this Neovim's RPC socket
│       └── track.lua                # tracking-file edits via oculus.tracking
├── assets/
│   ├── omarchy-plugin-icon.svg      # the mark Panel.qml draws (nested squares)
│   └── omarchy-glyph-source.svg     # same path at 1000×1000, for an icon-font glyph
└── install.sh
```

The bar icon and the panel's hero mark are the `assets/omarchy-plugin-icon.svg`
path drawn with `QtQuick.Shapes`, so they take the bar's foreground colour at
any size instead of depending on an icon font. Change the path in the SVG and
copy it into `OculusMark` in `Panel.qml` to change both.

## How it works

```
Chromium ── Alt+Shift+L (copy URL) ──▶ clipboard ──wl-paste──▶ Panel.qml
                                                                 │ parse URL
         ┌───────────────────────────────────────────────────────┤
         ▼                                                       ▼
oculus-open inspect|project|user                    oculus-track github owner/repo
  Ghostty + nvim -c "OculusInspect <url>"             oculus.tracking.mutate → tracking.json
                    "OculusOpen github:o/r"           then RPC → running nvim:
                    "OculusOpen @github:login"          require("oculus").reload_tracking()
```

When the panel opens it reads the clipboard and recognises:

| URL                                         | Actions                                            |
|---------------------------------------------|----------------------------------------------------|
| `github.com/owner/repo` (any page under it) | open the project's activity · track it · open the owner's activity |
| `github.com/owner/repo/pull/N`, `/issues/N`, `/commit/SHA` | **inspect** in Oculus, plus everything above |
| `github.com/login`, `github.com/orgs/login` | open the user's activity · track them              |

Codeberg URLs work the same (`codeberg.org/owner/repo/pulls/N`). Forge pages
like `github.com/settings` are ignored.

- **Tracking** goes through oculus.nvim's own `oculus.tracking` module (the
  same validation and atomic write the Oculus UI uses). New entries go at the
  root of the Projects or Users list, and you can move them into groups in
  Oculus. Rows for things you already track show as *Tracking …* and are
  dimmed. It works with no Neovim open. If a Neovim running the bridge is up,
  it's told to reload the tracking file over RPC.
- **Tracked projects and users** from the tracking file are listed below the
  actions. Click one to open its feed.
- Inspect and open start a new Ghostty + Neovim on an empty workspace
  (`oculus-open`). "Open Oculus" (`o`, middle click) uses your running Neovim
  when the bridge reports one.

## Requirements

- [Omarchy](https://omarchy.org) with its Quickshell-based shell, on
  Hyprland 0.56 or newer (the launcher uses its Lua `hyprctl dispatch` syntax).
- [oculus.nvim](https://github.com/andrewgilley/oculus.nvim) with `open_user`
  (`:OculusOpen @login`), installed with lazy.nvim and configured with a
  [tracking file](https://github.com/andrewgilley/oculus.nvim/blob/main/docs/tracking.md):
  `tracking_file = vim.fn.expand("~/.config/oculus/tracking.json")`.
- Ghostty as your default terminal (Omarchy's default), and `wl-clipboard`.

## Setup

1. Add the plugin to lazy.nvim. The Neovim side lives in the repo's `nvim/`
   folder, so the spec adds that folder to the runtime path:

   ```lua
   {
     "andrewgilley/oculus-omarchy",
     dependencies = { "andrewgilley/oculus.nvim" },
     config = function(plugin)
       vim.opt.rtp:append(plugin.dir .. "/nvim")
       require("oculus_omarchy").setup()
     end,
   }
   ```

2. Restart Neovim so lazy.nvim clones the repo, then install the bar widget
   and the two scripts from that clone:

   ```bash
   ~/.local/share/nvim/lazy/oculus-omarchy/install.sh
   ```

   This validates the plugin, copies it to
   `~/.config/omarchy/plugins/andrewgilley.oculus/`, and links `oculus-open`
   and `oculus-track` into `~/.local/bin`. It also removes the links left by
   0.2 (`oculus-activity`, `oculus-open-project`).
3. `omarchy bar put andrewgilley.oculus`.

After a lazy.nvim update, run `install.sh` again to pick up widget changes.

`oculus-track` finds oculus.nvim at `~/.local/share/nvim/lazy/oculus.nvim`;
override with `OCULUS_NVIM_PATH`. If your `tracking_file` isn't
`~/.config/oculus/tracking.json`, set the widget's *Tracking file* setting.

### Working on a local checkout

Point lazy.nvim at your clone instead, and run `./install.sh` from it:

```lua
{
  dir = "~/Dev/oculus-omarchy/nvim",
  name = "oculus-omarchy",
  dependencies = { "andrewgilley/oculus.nvim" },
  config = function() require("oculus_omarchy").setup() end,
}
```

## Using it

| Where      | Action                                                          |
|------------|-----------------------------------------------------------------|
| Chromium   | `Alt+Shift+L` copies the current URL (Omarchy's Copy URL extension) |
| Bar        | left: popout · middle: `:OculusOpen`                            |
| Panel keys | `1`–`n` run an action · Enter runs the first · `p` re-read the clipboard · `o` open Oculus |
| IPC        | `omarchy-shell andrewgilley.oculus item <url>` opens the panel on a URL; also `toggle`, `status` |
| CLI        | `oculus-open inspect <url>` · `oculus-open project github:owner/repo` · `oculus-open user github:login` · `oculus-track github owner/repo` · `oculus-track codeberg login` |

To get from a page to the panel in one key press, bind the IPC call to a key
in Hyprland. It opens the panel on whatever URL is on the clipboard:

```lua
-- ~/.config/hypr/bindings.lua
o.bind("SUPER + ALT + O", "Oculus: act on copied URL",
  [[sh -c 'omarchy-shell andrewgilley.oculus item "$(wl-paste -n)"']])
```

## Debugging

- Plugin load errors: `qs log -i "$(qs list | awk '/^Instance/{print $2}' | tr -d :)" | grep oculus`.
  A failed reload keeps the *old* widget running, so check this first if
  changes don't show up. If the error still names a line you've already fixed,
  the shell is compiling a cached copy: `omarchy restart shell` clears it
  (`rescanPlugins` didn't).
- Don't name QML properties `top` (or other names the base `Item` defines as
  FINAL); the widget fails to load with "Cannot override FINAL property".
- Tracking errors show in the panel. Run `oculus-track github owner/repo` in
  a terminal to see the full message.
- Bridge: `jq . ~/.local/state/oculus/omarchy.json`.
- Hyprland 0.56+ uses a Lua config, so `hyprctl dispatch` takes a Lua
  expression: `hyprctl dispatch 'hl.dsp.focus({ workspace = "emptym" })'`.
  The old `hyprctl dispatch workspace emptym` fails (exit 7). Trace the
  launcher with `bash -x ~/.local/bin/oculus-open project github:owner/repo`.
- Ghostty's `-e` silently drops arguments starting with `+` (it reserves them
  for its own `+actions`), so pass Neovim commands as `-c "…"`, never `+…`.

## TODO

- Read the URL straight from the focused browser tab instead of the
  clipboard (Chromium doesn't expose it without a native-messaging host).
- Choose a group when tracking, instead of the list root.
- Send inspect/open to the running Neovim and focus its terminal, instead of
  starting a new one.
- Arrow-key cursor over the panel rows.
