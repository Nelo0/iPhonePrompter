#!/bin/zsh
# Runs the deterministic test suite (no camera, microphone or network needed).
set -euo pipefail
cd "$(dirname "$0")/.."
swift test "$@"
