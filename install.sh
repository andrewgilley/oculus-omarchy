#!/bin/bash
# Copy the widget into the user plugin directory, link the helper scripts, and
# hook the Oculus Page extension into Chromium-based browsers. Validates first.
# The shell hot-reloads on save, so re-run after edits (or edit in place there).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.config/omarchy/plugins/andrewgilley.oculus"

omarchy-plugin-validate "$here/oculus"
mkdir -p "$dest" "$HOME/.local/bin"
cp -r "$here/oculus/." "$dest/"
for bin in oculus-open oculus-track; do
  chmod +x "$here/nvim/bin/$bin"
  ln -sf "$here/nvim/bin/$bin" "$HOME/.local/bin/$bin"
done

# Scripts from 0.2 (update counts), now removed.
for old in oculus-activity oculus-open-project; do
  if [[ -L $HOME/.local/bin/$old && ! -e $HOME/.local/bin/$old ]]; then
    rm "$HOME/.local/bin/$old"
  fi
done

# The browser extension reports the page you're on through a native messaging
# host. Register the host for each browser profile root that exists, and load
# the extension from this checkout via the browser's flags file (the way Omarchy
# loads its own extensions); a checkout that moved replaces its old entry.
chmod +x "$here/browser/oculus-page-host"
host_manifest=$(sed "s|__HOST_PATH__|$here/browser/oculus-page-host|" "$here/browser/com.andrewgilley.oculus_page.json")
for dir in chromium google-chrome google-chrome-beta google-chrome-unstable \
  BraveSoftware/Brave-Browser BraveSoftware/Brave-Browser-Beta BraveSoftware/Brave-Browser-Nightly \
  microsoft-edge microsoft-edge-dev; do
  [[ -d $HOME/.config/$dir ]] || continue
  mkdir -p "$HOME/.config/$dir/NativeMessagingHosts"
  printf '%s\n' "$host_manifest" >"$HOME/.config/$dir/NativeMessagingHosts/com.andrewgilley.oculus_page.json"
done

ext="$here/browser/oculus-page"
for conf in chromium chrome google-chrome brave brave-beta brave-nightly brave-origin-beta microsoft-edge-stable; do
  flags="$HOME/.config/$conf-flags.conf"
  [[ -f $flags ]] || continue
  grep -qF -- "$ext" "$flags" && continue
  # Drop an entry from a checkout somewhere else, then add this one.
  sed -i --follow-symlinks -E 's#,[^,]*/browser/oculus-page(,|$)#\1#; s#^--load-extension=[^,]*/browser/oculus-page(,|$)#--load-extension=#; /^--load-extension=$/d' "$flags"
  if grep -q '^--load-extension=' "$flags"; then
    sed -i --follow-symlinks "s|^--load-extension=\(.*\)$|--load-extension=\1,$ext|" "$flags"
  else
    echo "--load-extension=$ext" >>"$flags"
  fi
  echo "Added the Oculus Page extension to $flags; restart the browser to load it"
done

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

echo "Installed to $dest (scripts: ~/.local/bin/oculus-open, ~/.local/bin/oculus-track)"
echo "Add it to the bar:  omarchy bar put andrewgilley.oculus   (or edit ~/.config/omarchy/shell.json)"
