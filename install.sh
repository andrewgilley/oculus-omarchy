#!/bin/bash
# Copy the widget into the user plugin directory, link the fetcher CLI, validate.
# The shell hot-reloads on save, so re-run after edits (or edit in place there).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.config/omarchy/plugins/andrewgilley.oculus"

omarchy-plugin-validate "$here/oculus"
mkdir -p "$dest" "$HOME/.local/bin"
cp -r "$here/oculus/." "$dest/"
for bin in oculus-activity oculus-open-project; do
  chmod +x "$here/nvim/bin/$bin"
  ln -sf "$here/nvim/bin/$bin" "$HOME/.local/bin/$bin"
done
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

echo "Installed to $dest (fetcher: ~/.local/bin/oculus-activity)"
echo "Add it to the bar:  omarchy bar put andrewgilley.oculus   (or edit ~/.config/omarchy/shell.json)"
