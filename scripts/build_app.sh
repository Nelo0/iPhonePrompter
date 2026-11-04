#!/bin/zsh
# Builds build/LensPrompt.app (release, arm64) and signs it locally.
# Usage: scripts/build_app.sh [--debug]
# Env: CODESIGN_IDENTITY  signing identity (default "-" = ad-hoc). A stable local identity
#                         keeps macOS camera/microphone permissions across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG=release
[[ "${1:-}" == "--debug" ]] && CONFIG=debug
IDENTITY="${CODESIGN_IDENTITY:--}"
BUNDLE_ID="${BUNDLE_IDENTIFIER:-io.github.Nelo0.iPhonePrompter}"

echo "==> swift build -c $CONFIG --product LensPrompt"
swift build -c "$CONFIG" --product LensPrompt
BIN="$(swift build -c "$CONFIG" --show-bin-path)/LensPrompt"

APP="$ROOT/build/LensPrompt.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LensPrompt"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ ! -f "$ROOT/build/AppIcon.icns" ]]; then
  "$ROOT/scripts/make_icon.sh" "$ROOT/build/AppIcon.icns" || echo "   (icon generation skipped)"
fi
[[ -f "$ROOT/build/AppIcon.icns" ]] && cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
plutil -lint "$APP/Contents/Info.plist"

echo "==> Signing with identity: $IDENTITY"
codesign --force --sign "$IDENTITY" --entitlements "$ROOT/Resources/LensPrompt.entitlements" \
  --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --verbose=1 "$APP"
echo "==> Built $APP"
