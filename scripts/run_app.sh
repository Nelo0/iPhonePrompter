#!/bin/zsh
# Launches the bundled app. Extra arguments are passed to LensPrompt
# (for example --no-capture to open the UI without camera/microphone access).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d build/LensPrompt.app ]] || scripts/build_app.sh
if [[ $# -gt 0 ]]; then
  open -n build/LensPrompt.app --args "$@"
else
  open build/LensPrompt.app
fi
