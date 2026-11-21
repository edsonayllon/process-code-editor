#!/bin/bash
# Builds "Process Code.app" into build/. Pass --install to also copy it to /Applications, or --update to
# install it and open the new copy.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
case "$MODE" in
  "" | --install | --update) ;;
  *) echo "usage: $0 [--install | --update]" >&2; exit 2 ;;
esac

APP_NAME="Process Code"
BUNDLE_ID="com.processcode.app"
VERSION="1.0.0"
APP="build/$APP_NAME.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ProcessCode"

# The icon is drawn by a script and kept in the repo; redraw it only if it's missing.
if [ ! -f Resources/AppIcon.icns ]; then
  TMP="$(mktemp -d)"
  swift scripts/make-icon.swift "$TMP/icon.png"
  mkdir "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ProcessCode"
strip -x "$APP/Contents/MacOS/ProcessCode"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The usage descriptions cover the app and everything run in its terminal: macOS asks on the
# app's behalf when a command there first reaches into a protected folder or another app.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>ProcessCode</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Text</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.text</string><string>public.source-code</string><string>public.data</string></array>
    </dict>
  </array>
  <key>NSDocumentsFolderUsageDescription</key><string>Process Code opens the folders you choose, and commands in its terminal read and write files there.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Process Code opens the folders you choose, and commands in its terminal read and write files there.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Process Code opens the folders you choose, and commands in its terminal read and write files there.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Process Code opens the folders you choose, and commands in its terminal read and write files there.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Process Code opens the folders you choose, and commands in its terminal read and write files there.</string>
  <key>NSAppleEventsUsageDescription</key><string>A command in Process Code's terminal wants to control another app. Coding agents use this to read an image from the clipboard.</string>
  <key>NSCameraUsageDescription</key><string>A command in Process Code's terminal wants to use the camera.</string>
  <key>NSMicrophoneUsageDescription</key><string>A command in Process Code's terminal wants to use the microphone.</string>
  <key>NSLocalNetworkUsageDescription</key><string>A command in Process Code's terminal wants to reach a device on your local network, such as a development server.</string>
</dict>
</plist>
PLIST

# A stable signing identity keeps macOS from asking for folder access again after every rebuild.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"

if [ -n "$MODE" ]; then
  # Run from Process Code's own terminal, quitting the app hangs up this script and closes its output.
  # Ignore the hangup and let the messages fail, so the install still finishes.
  trap '' HUP
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  # Quitting can be cancelled from the app's "still running" prompt, so wait for it to go.
  for _ in $(seq 100); do
    pgrep -x ProcessCode >/dev/null || break
    sleep 0.1
  done
  if pgrep -x ProcessCode >/dev/null; then
    echo "$APP_NAME is still running, so it was not replaced. Quit it and run this again." >&2
    exit 1
  fi
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  echo "Installed /Applications/$APP_NAME.app" 2>/dev/null || true
  if [ "$MODE" = "--update" ]; then
    open "/Applications/$APP_NAME.app"
  fi
fi
