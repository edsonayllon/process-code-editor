#!/bin/bash
# Builds "Process Code.app" into build/. Pass --install to also copy it to /Applications, or --update to
# install it and open the new copy. Pass --release to sign it for distribution and make a notarised
# build/ProcessCode.dmg (needs a Developer ID Application certificate and a notarytool profile, see README).
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
case "$MODE" in
  "" | --install | --update | --release) ;;
  *) echo "usage: $0 [--install | --update | --release]" >&2; exit 2 ;;
esac

# The keychain profile saved with `xcrun notarytool store-credentials`.
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
if [ "$MODE" = "--release" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  if [ -z "$IDENTITY" ]; then
    echo "No Developer ID Application certificate in the keychain. Create one first (see README)." >&2
    exit 1
  fi
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "No notarytool profile named \"$NOTARY_PROFILE\". Save one first (see README)." >&2
    exit 1
  fi
else
  # A stable signing identity keeps macOS from asking for folder access again after every rebuild.
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi

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
# The licences of the libraries linked into the app travel with every copy of it.
mkdir "$APP/Contents/Resources/Licenses"
cp .build/checkouts/SwiftTerm/LICENSE "$APP/Contents/Resources/Licenses/SwiftTerm.txt"
cp .build/checkouts/swift-cmark/COPYING "$APP/Contents/Resources/Licenses/cmark-gfm.txt"

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

# Every build runs under the hardened runtime that notarisation requires, so a local build behaves like the
# one people download. Only a release needs the secure timestamp, which asks Apple's server.
SIGN_FLAGS=(--force --options runtime --entitlements Resources/ProcessCode.entitlements)
[ "$MODE" = "--release" ] && SIGN_FLAGS+=(--timestamp)
codesign "${SIGN_FLAGS[@]}" --sign "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"

if [ "$MODE" = "--release" ]; then
  DMG="build/ProcessCode.dmg"
  STAGE="$(mktemp -d)"
  MOUNT="$(mktemp -d)"
  trap 'hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; rm -rf "$STAGE"' EXIT
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs APFS -format UDZO "$DMG"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"

  # --timeout keeps a stuck submission from waiting forever; Apple usually answers in a few minutes.
  echo "Notarising $DMG..."
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 20m \
    > build/notarytool.log 2>&1 || true
  if ! grep -q "status: Accepted" build/notarytool.log; then
    cat build/notarytool.log >&2
    echo "Notarisation failed. For the reasons: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
  fi
  xcrun stapler staple -q "$DMG"

  # Check it the way Gatekeeper will on someone else's Mac: the disk image, then the app inside it.
  xcrun stapler validate -q "$DMG"
  spctl -a -t open --context context:primary-signature "$DMG"
  hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
  spctl -a -t exec "$MOUNT/$APP_NAME.app"
  echo "Notarised $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
  exit 0
fi

if [ -n "$MODE" ]; then
  # Run from Process Code's own terminal, quitting the app takes this script down with it: the app
  # ends its terminals, and a shell or agent that is ending kills what it started. So the quit, the
  # copy and the reopen run in a process of their own, in a new session and no longer a child of
  # this one, with every signal that can be ignored ignored. What it says goes to a log, which is
  # shown here if this script is still around to show it.
  LOG="$PWD/build/install.log"
  DONE="$PWD/build/install.status"
  rm -f "$DONE"
  APP_NAME="$APP_NAME" APP="$PWD/$APP" MODE="$MODE" DONE="$DONE" \
    perl -MPOSIX -e 'exit if fork; setsid(); $SIG{$_} = "IGNORE" for qw(HUP TERM INT PIPE); exec @ARGV' \
    /bin/bash -c '
      finish() { echo "$1" > "$DONE"; exit "$1"; }
      osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
      # Quitting can be cancelled from the app'"'"'s "still running" prompt, so wait for it to go.
      for _ in $(seq 100); do
        pgrep -x ProcessCode >/dev/null || break
        sleep 0.1
      done
      if pgrep -x ProcessCode >/dev/null; then
        echo "$APP_NAME is still running, so it was not replaced. Quit it and run this again."
        finish 1
      fi
      rm -rf "/Applications/$APP_NAME.app"
      cp -R "$APP" "/Applications/$APP_NAME.app" || finish 1
      echo "Installed /Applications/$APP_NAME.app"
      if [ "$MODE" = "--update" ]; then
        # Just after a quit the system can still count the app as open and do nothing, so ask
        # until the new copy is running.
        for _ in 1 2 3 4 5; do
          open "/Applications/$APP_NAME.app" || true
          for _ in $(seq 20); do
            pgrep -x ProcessCode >/dev/null && finish 0
            sleep 0.1
          done
        done
        echo "Installed, but $APP_NAME did not open."
        finish 1
      fi
      finish 0
    ' </dev/null >"$LOG" 2>&1

  # At most about 25 seconds: ten for the quit, ten for the reopen, and the copy.
  trap '' HUP
  for _ in $(seq 250); do
    [ -f "$DONE" ] && break
    sleep 0.1
  done
  cat "$LOG" 2>/dev/null || true
  [ -f "$DONE" ] && exit "$(cat "$DONE")"
  echo "The install did not finish; see $LOG" >&2
  exit 1
fi
