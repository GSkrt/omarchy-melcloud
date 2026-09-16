#!/usr/bin/bash
# Builds this plugin's Python virtual environment and enables the bar widget.
#
# Usage, run once, after this plugin is linked/checked out under
# ~/.config/omarchy/plugins/io.github.gskrt.melcloud:
#   ~/.config/omarchy/plugins/io.github.gskrt.melcloud/install.sh
# Safe to run from anywhere: everything below is relative to this script's
# own directory, not the caller's.
#
# No sudo/pacman step here (unlike some other third-party plugins): python3
# and venv are already part of a base Arch/Omarchy install, so the only
# thing missing is pymelcloud/aiohttp, and those install into a private venv
# rather than system site-packages.
set -euo pipefail

DIRNAME=/usr/bin/dirname
CAT=/usr/bin/cat

cd "$("$DIRNAME" "${BASH_SOURCE[0]}")"
PLUGIN_DIR="$(pwd)"
DATA_DIR="$HOME/.local/share/omarchy-melcloud"
VENV_DIR="$DATA_DIR/venv"

echo "Creating a Python virtual environment for pymelcloud at $VENV_DIR..."
/usr/bin/python3 -m venv "$VENV_DIR"
# --require-hashes: refuses to install anything -- pip itself included --
# that isn't listed in requirements.txt with a matching sha256, rather than
# pulling whatever the package index currently serves. See that file's own
# header for how it's generated and verified.
"$VENV_DIR/bin/pip" install --require-hashes -r "$PLUGIN_DIR/requirements.txt"

echo "Adding OmaMELCloud to the bar..."
/usr/share/omarchy/bin/omarchy-plugin-enable io.github.gskrt.melcloud

"$CAT" <<MSG

Installed. Click the new "AC" icon in the bar and choose "Sign in" to open a
setup terminal -- it asks for your MELCloud email and password (used only to
talk to https://app.melcloud.com) and saves the password in your login
keyring via secret-tool, not in a plain file. If the account has more than
one air conditioner, it asks which one this plugin should control.

Or run setup directly from a terminal:
  "$VENV_DIR/bin/python3" -I "$PLUGIN_DIR/bin/melcloud-setup"

MSG
