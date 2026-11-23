#!/bin/bash
# Builds "Process Code.app" into build/. Pass --install to also copy it to /Applications, or --update to
# install it and open the new copy. Pass --release to sign it for distribution and make a notarised
# build/ProcessCode.dmg, with the build/appcast.xml that tells installed copies about it (needs a Developer ID
# Application certificate, a notarytool profile and the Sparkle key, see README).
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
case "$MODE" in
  "" | --install | --update | --release) ;;
  *) echo "usage: $0 [--install | --update | --release]" >&2; exit 2 ;;
esac

# Sparkle's public key. Every released app carries it and accepts only updates signed with the private key
# that goes with it, which lives in the login keychain of the Mac that cuts releases (see README). It must
# never change: an installed copy can't take an update signed with another key.
SPARKLE_PUBLIC_KEY="NecvWgLDDagpygY3Fzyhd6aiBJqC/Ri+u6Z5iHtL0nQ="
# Where installed copies look for a new version, and where they download it from.
RELEASES="https://github.com/edsonayllon/process-code-editor/releases"
# The Sparkle that SwiftPM fetched: the framework that goes into the app, and the tools that sign an update.
SPARKLE=".build/artifacts/sparkle/Sparkle"

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
  # Before the minutes of building and notarising: the key this Mac signs with must be the one in the app.
  swift package resolve
  if [ -z "$SPARKLE_PUBLIC_KEY" ]; then
    echo "SPARKLE_PUBLIC_KEY in $0 is empty. Make the key and paste its public half there (see README)." >&2
    exit 1
  fi
  if [ "$("$SPARKLE/bin/generate_keys" -p 2>/dev/null)" != "$SPARKLE_PUBLIC_KEY" ]; then
    echo "The Sparkle key in this Mac's keychain isn't the one in SPARKLE_PUBLIC_KEY, so installed copies" >&2
    echo "would refuse this release. Import the right private key first (see README)." >&2
    exit 1
  fi
else
  # A stable signing identity keeps macOS from asking for folder access again after every rebuild.
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi

APP_NAME="Process Code"
BUNDLE_ID="com.processcode.app"
# The version is the one being released (scripts/release.sh passes it), or else the last release's tag.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-1.0.0}"
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
# Sparkle is a framework inside the app, so the binary is told to look for it there and no longer in the
# build folder, whose path SwiftPM wrote into it.
mkdir "$APP/Contents/Frameworks"
cp -R "$SPARKLE/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/"
otool -l "$APP/Contents/MacOS/ProcessCode" | sed -n 's|^ *path \(/.*\) (offset [0-9]*)$|\1|p' | while IFS= read -r rpath; do
  install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/ProcessCode"
done
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/ProcessCode"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The licences of the libraries linked into the app travel with every copy of it.
mkdir "$APP/Contents/Resources/Licenses"
cp .build/checkouts/SwiftTerm/LICENSE "$APP/Contents/Resources/Licenses/SwiftTerm.txt"
cp .build/checkouts/swift-cmark/COPYING "$APP/Contents/Resources/Licenses/cmark-gfm.txt"
cp "$SPARKLE/LICENSE" "$APP/Contents/Resources/Licenses/Sparkle.txt"

# Only a release looks for updates: a copy built here would be replaced by the last release, which is older.
UPDATE_KEYS=""
if [ "$MODE" = "--release" ]; then
  UPDATE_KEYS="<key>SUFeedURL</key><string>$RELEASES/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>"
fi

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
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUEnableAutomaticChecks</key><false/>
  $UPDATE_KEYS
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
SIGN_FLAGS=(--force --options runtime)
[ "$MODE" = "--release" ] && SIGN_FLAGS+=(--timestamp)
ENTITLEMENTS="Resources/ProcessCode.entitlements"
if [ -z "$IDENTITY" ]; then
  # The hardened runtime loads a framework only if it is signed by the app's own team, and an ad hoc
  # signature has no team, so an ad hoc build is allowed to load Sparkle anyway.
  ENTITLEMENTS="$(mktemp -d)/adhoc.entitlements"
  cp Resources/ProcessCode.entitlements "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
fi
# Sparkle's helpers are signed from the inside out, as its documentation orders them, and without the
# app's entitlements; the downloader keeps the ones it came with.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_FLAGS[@]}" --sign "${IDENTITY:--}" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements --sign "${IDENTITY:--}" "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGN_FLAGS[@]}" --sign "${IDENTITY:--}" "$FRAMEWORK/Versions/B/Autoupdate"
codesign "${SIGN_FLAGS[@]}" --sign "${IDENTITY:--}" "$FRAMEWORK/Versions/B/Updater.app"
codesign "${SIGN_FLAGS[@]}" --sign "${IDENTITY:--}" "$FRAMEWORK"
codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" --sign "${IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
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

  # The feed installed copies read: this one version, and the signature of its disk image. It is signed
  # only now because stapling changed the file. The download is the release's own, not "latest", so the
  # signature here always belongs to the file it names.
  SIGNATURE="$("$SPARKLE/bin/sign_update" -p "$DMG")"
  "$SPARKLE/bin/sign_update" --verify "$DMG" "$SIGNATURE"
  cat > build/appcast.xml <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <item>
      <title>Version $VERSION</title>
      <link>$RELEASES/tag/v$VERSION</link>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <enclosure url="$RELEASES/download/v$VERSION/ProcessCode.dmg" length="$(stat -f %z "$DMG")" type="application/octet-stream" sparkle:edSignature="$SIGNATURE" />
    </item>
  </channel>
</rss>
APPCAST
  xmllint --noout build/appcast.xml
  echo "Wrote build/appcast.xml for $VERSION"
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
