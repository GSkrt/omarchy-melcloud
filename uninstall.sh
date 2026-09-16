#!/usr/bin/bash
# Reverses install.sh: disables the bar widget and removes the venv it
# created. Deliberately does NOT delete your saved credentials or chosen
# device (~/.config/omarchy-melcloud/, and the "omarchy-melcloud" entry in
# your login keyring) -- those are yours to remove explicitly if you want
# them gone; see the printed instructions below.
set -euo pipefail

DIRNAME=/usr/bin/dirname
CAT=/usr/bin/cat
RM=/usr/bin/rm

cd "$("$DIRNAME" "${BASH_SOURCE[0]}")"
DATA_DIR="$HOME/.local/share/omarchy-melcloud"

echo "Removing OmaMELCloud from the bar..."
/usr/share/omarchy/bin/omarchy-plugin-disable io.github.gskrt.melcloud || true

if [[ -d $DATA_DIR ]]; then
  echo "Removing $DATA_DIR..."
  "$RM" -rf -- "$DATA_DIR"
fi

"$CAT" <<MSG

Uninstalled. Your MELCloud sign-in is still saved. To remove it too:

  rm -rf ~/.config/omarchy-melcloud
  secret-tool clear service omarchy-melcloud

MSG
