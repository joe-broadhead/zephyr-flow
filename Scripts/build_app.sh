#!/usr/bin/env bash
# Build ZephyrFlow.app from the SwiftPM executable (no full Xcode required).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
ARCH="$(uname -m)"
APP_NAME="ZephyrFlow"
BUNDLE_ID="dev.zephyrflow.app"
BUILD_DIR="$ROOT/.build"
APP_DIR="$BUILD_DIR/App/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "→ Building $APP_NAME ($CONFIG, $ARCH)…"

# Resolve + build
swift build -c "$CONFIG" --product ZephyrFlow 2>&1

BIN="$(swift build -c "$CONFIG" --show-bin-path)/ZephyrFlow"
if [[ ! -x "$BIN" ]]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi

echo "→ Assembling app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES_DIR"

cp "$BIN" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

# Info.plist
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# Entitlements copy (for reference / codesign)
cp "$ROOT/Resources/ZephyrFlow.entitlements" "$RESOURCES_DIR/ZephyrFlow.entitlements"

# PkgInfo
echo -n "APPL????" > "$CONTENTS/PkgInfo"

# App icon
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  echo "→ Generating AppIcon.icns…"
  if [[ -x "$ROOT/.venv/bin/python" ]]; then
    "$ROOT/.venv/bin/python" "$ROOT/Scripts/generate_app_icon.py" || true
  else
    python3 "$ROOT/Scripts/generate_app_icon.py" || true
  fi
fi
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$CONTENTS/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$CONTENTS/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconName AppIcon" "$CONTENTS/Info.plist" 2>/dev/null || true
fi

# Ad-hoc codesign (required on Apple Silicon). Stable --identifier helps TCC
# associate rebuilds with the same app entry in Accessibility.
echo "→ Codesigning (ad-hoc)…"
codesign --force --deep --sign - \
  --identifier "$BUNDLE_ID" \
  --entitlements "$ROOT/Resources/ZephyrFlow.entitlements" \
  "$APP_DIR" 2>&1 || codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_DIR"

# Install into /Applications or local Dist
DIST="$ROOT/Dist"
mkdir -p "$DIST"
rm -rf "$DIST/$APP_NAME.app"
cp -R "$APP_DIR" "$DIST/$APP_NAME.app"

echo "✓ Built $DIST/$APP_NAME.app"
echo ""
echo "To install & run:"
echo "  cp -R \"$DIST/$APP_NAME.app\" /Applications/"
echo "  open /Applications/$APP_NAME.app"
echo ""
echo "Or run directly:"
echo "  open \"$DIST/$APP_NAME.app\""
echo ""
echo "First launch: grant Microphone + Accessibility when prompted."
echo "Default hotkey: hold Fn to dictate."
