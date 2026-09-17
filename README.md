# oculus-omarchy

Omarchy shell plugin that takes the GitHub or Codeberg page you're looking at
into [oculus.nvim](https://github.com/andrewgilley/oculus.nvim): it recognises
the project or user the page is about, tells you whether Oculus already tracks
it and whether you have it cloned, and offers to track it, clone it, open its
activity feed, or inspect a pull request, issue or commit.

The bar icon and the panel's hero mark are the `assets/omarchy-plugin-icon.svg`
path drawn with `QtQuick.Shapes`, so they take the bar's foreground colour at
any size instead of depending on an icon font. Change the path in the SVG and
copy it into `OculusMark` in `Panel.qml` to change both.

## How it works

The Oculus Page browser extension (`browser/oculus-page`) reports the active
tab of the browser window you last used whenever it changes, through a native
messaging host (`browser/oculus-page-host`) that writes
`~/.local/state/oculus/browser.json`. The panel watches that file, so it knows
the page you're on with nothing to copy. It recognises:

| URL                                         | Actions                                            |
|---------------------------------------------|----------------------------------------------------|
| `github.com/owner/repo` (any page under it) | **track the project** · open its activity · **clone it** · **track the owner** · open the owner's activity |
| `github.com/owner/repo/pull/N`, `/issues/N`, `/commit/SHA` | **inspect** in Oculus, plus everything above |
| `github.com/login`, `github.com/orgs/login` | **track the user** · open their activity           |

Codeberg URLs work the same (`codeberg.org/owner/repo/pulls/N`). Forge pages
like `github.com/settings`, and anything that isn't a forge URL, are ignored —
the panel says so instead of offering actions.

- **Only GitHub and Codeberg are visible.** The extension's host permissions
  cover `github.com` and `codeberg.org` and nothing else, so Chromium never
  hands it the URL of any other page; those are recorded as an empty URL.
- The page stays current while the panel is open: switch tabs and it follows.
  If the browser has quit since, the panel says so rather than showing the last
  page.

- **Already tracking it?** The hero carries a *Tracked* / *Not tracked* pill
  for the thing the page is about, and any row whose target is already in the
  tracking file reads *Tracking …*, is dimmed, and carries a ✓ instead of a
  number. The number keys only ever count the rows you can actually press, so
  `1`–`n` stay in step as things become tracked.
- Every repo page offers its **owner** as well as the project, so you can pick
  up a user you follow from any page of one of their repos.
- **Got it locally?** Every repo page checks your source folder
  (`~/Dev/source`, or the widget's *Source folder* setting) for that project
  and says where it is, matching on the checkout's `origin` remote rather than
  the folder name, so a same-named clone of someone else's fork doesn't count.
  If it isn't there, **Clone** fetches it into that folder with `git clone`.
  The clone runs in the background — close the panel and it carries on, and a
  notification says when it lands.
- **Tracking** asks in the panel which group to put the entry in (type to
  filter, or type a new group's name) and then what to call it (Enter twice
  keeps the top level and no name). It goes through
  oculus.nvim's own `oculus.tracking` module (the same validation and atomic
  write the Oculus UI uses) and works with no Neovim open. If a Neovim running the bridge is up,
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
- `git`, for cloning
- Chromium, or another Chromium-based browser with a `~/.config/<browser>-flags.conf`

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
   `~/.config/omarchy/plugins/andrewgilley.oculus/`, and links `oculus-open`,
   `oculus-track` and `oculus-clone` into `~/.local/bin`. It registers
   `oculus-page-host` as a native messaging host and adds `browser/oculus-page`
   to the `--load-extension` line of your browser's flags file, the way Omarchy loads
   its own extensions. It also removes the links left by 0.2
   (`oculus-activity`, `oculus-open-project`).
3. Restart the browser so it loads the extension.
4. `omarchy bar put andrewgilley.oculus`.

After a lazy.nvim update, run `install.sh` again to pick up widget changes.

`oculus-track` finds oculus.nvim at `~/.local/share/nvim/lazy/oculus.nvim`;
override with `OCULUS_NVIM_PATH`. If your `tracking_file` isn't
`~/.config/oculus/tracking.json`, set the widget's *Tracking file* setting, and
if your clones don't live in `~/Dev/source`, set *Source folder*.

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

## The overlay

For everything beyond the page you're on, there's a full-screen search in the
style of Omarchy's clipboard and emoji pickers. Right-click the bar icon, or bind it
to a key:

```lua
-- ~/.config/hypr/bindings.lua
o.bind("SUPER + SHIFT + O", "Oculus: search tracked",
  [[omarchy-shell shell toggle andrewgilley.oculus '{}']])
```

It lists every project and user in your tracking file with its group, plus the
page open in the browser, and searches across names, groups and providers.
Type or paste (`Ctrl+V`) a GitHub or Codeberg URL to act on that instead. The
selected row's actions are on the right:

- **Tracked entries:** open the activity feed, open on GitHub/Codeberg, move
  to a group, untrack (asks first).
- **The page, or a URL:** inspect a pull request, issue or commit, track the
  project or its owner, open their feeds.

Tracking and moving open a group picker in the same card; type a name that
isn't there to create a new top-level group. Tracking then asks for the display
name Oculus shows; leave it empty to show the repository or login. `summon` takes an optional
starting query: `omarchy-shell shell summon andrewgilley.oculus '{"query": "zig"}'`.

## Using it

| Where      | Action                                                          |
|------------|-----------------------------------------------------------------|
| Bar        | left: popout on the current page · middle: `:OculusOpen` · right: overlay, or close the popout |
| Panel      | with no page, click anywhere in it to open Oculus, right-click to close |
| Panel keys | `1`–`n` run an action · Enter runs the first · `o` open Oculus · `q` or Esc close |
| Overlay keys | type to search · ↑↓ select · Enter runs the first action · Tab into the actions · Alt+Enter open in browser · Del untrack · Ctrl+V paste · Esc clear, back, close |
| Tracked    | dimmed row, ✓ instead of a number — it's already in the tracking file, or already cloned |
| IPC        | `omarchy-shell andrewgilley.oculus toggle` opens the panel on the current page; `item <url>` on any URL; `status` · `omarchy-shell shell toggle andrewgilley.oculus '{}'` the overlay |
| CLI        | `oculus-open inspect <url>` · `oculus-open project github:owner/repo` · `oculus-open user github:login` · `oculus-track github owner/repo` · `oculus-track codeberg login` · `oculus-track --group /Editors/ --name Name github owner/repo` · `oculus-track --move / github owner/repo` · `oculus-track --remove github owner/repo` · `oculus-clone --dir ~/Dev/source github owner/repo` · `oculus-clone --check --dir ~/Dev/source github owner/repo` |

To get from a page to the panel in one key press, bind the IPC call to a key
in Hyprland:

```lua
-- ~/.config/hypr/bindings.lua
o.bind("SUPER + ALT + O", "Oculus: act on this page",
  [[omarchy-shell andrewgilley.oculus toggle]])
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
- Clone errors show in the panel, under the rows. Run
  `oculus-clone --dir ~/Dev/source github owner/repo` in a terminal to see the
  whole of what git said; `--check` prints `<state>\t<path>` for the folder it
  would use.
- Bridge: `jq . ~/.local/state/oculus/omarchy.json`.
- Browser page: `jq . ~/.local/state/oculus/browser.json` should change as you
  switch tabs. If the file never appears, check that `chrome://extensions`
  lists *Oculus Page* (restart the browser after `install.sh`) and that the
  host manifest in `~/.config/chromium/NativeMessagingHosts/` points at
  `oculus-page-host`; the extension's service worker console shows host errors.
- Hyprland 0.56+ uses a Lua config, so `hyprctl dispatch` takes a Lua
  expression: `hyprctl dispatch 'hl.dsp.focus({ workspace = "emptym" })'`.
  The old `hyprctl dispatch workspace emptym` fails (exit 7). Trace the
  launcher with `bash -x ~/.local/bin/oculus-open project github:owner/repo`.
- Ghostty's `-e` silently drops arguments starting with `+` (it reserves them
  for its own `+actions`), so pass Neovim commands as `-c "…"`, never `+…`.
