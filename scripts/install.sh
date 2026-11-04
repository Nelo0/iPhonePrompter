#!/bin/zsh
# Copies the built app to ~/Applications (creates it if needed).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d build/LensPrompt.app ]] || scripts/build_app.sh
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/LensPrompt.app"
cp -R build/LensPrompt.app "$HOME/Applications/LensPrompt.app"
echo "Installed to $HOME/Applications/LensPrompt.app"
