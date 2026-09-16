# oculus-omarchy

Omarchy shell plugin that takes the GitHub or Codeberg page you're looking at
into [oculus.nvim](https://github.com/andrewgilley/oculus.nvim): it recognises
the project or user the page is about, tells you whether Oculus already tracks
it, and offers to track it, open its activity feed, or inspect a pull request,
issue or commit.

The bar icon and the panel's hero mark are the `assets/omarchy-plugin-icon.svg`
path drawn with `QtQuick.Shapes`, so they take the bar's foreground colour at
any size instead of depending on an icon font. Change the path in the SVG and
copy it into `OculusMark` in `Panel.qml` to change both.

## How it works

When the panel opens it reads the clipboard and recognises:

| URL                                         | Actions                                            |
|---------------------------------------------|----------------------------------------------------|
| `github.com/owner/repo` (any page under it) | **track the project** · open its activity · **track the owner** · open the owner's activity |
| `github.com/owner/repo/pull/N`, `/issues/N`, `/commit/SHA` | **inspect** in Oculus, plus everything above |
| `github.com/login`, `github.com/orgs/login` | **track the user** · open their activity           |

Codeberg URLs work the same (`codeberg.org/owner/repo/pulls/N`). Forge pages
like `github.com/settings`, and anything that isn't a forge URL, are ignored —
the panel says so instead of offering actions.

- **Already tracking it?** The hero carries a *Tracked* / *Not tracked* pill
  for the thing the page is about, and any row whose target is already in the
  tracking file reads *Tracking …*, is dimmed, and carries a ✓ instead of a
  number. The number keys only ever count the rows you can actually press, so
  `1`–`n` stay in step as things become tracked.
- Every repo page offers its **owner** as well as the project, so you can pick
  up a user you follow from any page of one of their repos.
- **Tracking** goes through oculus.nvim's own `oculus.tracking` module (the
  same validation and atomic write the Oculus UI uses). New entries go at the
  root of the Projects or Users list, and you can move them into groups in
  Oculus. It works with no Neovim open. If a Neovim running the bridge is up,
  it's told to reload the tracking file over RPC.
- The panel only ever talks about the page you're on. Browse the things you
  already track in Oculus itself (`o`, or middle-click the bar icon).
- Inspect and open start a new Ghostty + Neovim on an empty workspace
  (`oculus-open`). "Open Oculus" (`o`, middle click) uses your running Neovim
  when the bridge reports one.

## Requirements

- [Omarchy] (https://omarchy.org) 
- [oculus.nvim] (https://github.com/andrewgilley/oculus.nvim) 
- [Ghostty] (https://github.com/ghostty-org/ghostty)

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
| Tracked    | dimmed row, ✓ instead of a number — it's already in the tracking file |
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
