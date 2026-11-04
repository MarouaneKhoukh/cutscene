#!/usr/bin/env bash
# Build Cutscene with SwiftPM and assemble a signed .app bundle in dist/.
#
# Usage: scripts/bundle.sh [debug|release]
# Env:   CODESIGN_IDENTITY   signing identity; defaults to the local
#                            "Cutscene Dev" certificate from scripts/dev-cert.sh
#                            when present, else "-" (ad-hoc).
#
# macOS grants Screen Recording, camera and microphone permission to a bundle
# with a stable identifier, not to a bare executable, so even development
# builds go through here.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Cutscene"
BUNDLE_ID="app.cutscene.Cutscene"
VERSION="0.1.0"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q '"Cutscene Dev"'; then
    IDENTITY="Cutscene Dev"
else
    IDENTITY="-"
fi

swift build --package-path "$ROOT" -c "$CONFIG"
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/$APP_NAME"

APP="$ROOT/dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- A menu-bar agent: no Dock icon or app menu; the editor flips the
       activation policy while its window is open (ARCHITECTURE §1). -->
  <key>LSUIElement</key><true/>
  <key>NSCameraUsageDescription</key><string>Cutscene records your camera for the webcam bubble.</string>
  <key>NSMicrophoneUsageDescription</key><string>Cutscene records your microphone for narration.</string>
  <!-- Without this key AVFoundation hides iPhone Continuity Cameras from
       discovery (macOS 14; the camera recorder lists them in M2-05). -->
  <key>NSCameraUseContinuityCameraDeviceType</key><true/>
  <!-- The .cutscene package: a folder the Finder shows as one document and
       opens with us (ARCHITECTURE §3; RecordingPackage.typeIdentifier). -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Cutscene Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSTypeIsPackage</key><true/>
      <key>LSItemContentTypes</key>
      <array><string>app.cutscene.project</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.cutscene.project</string>
      <key>UTTypeDescription</key><string>Cutscene Project</string>
      <key>UTTypeConformsTo</key>
      <array><string>com.apple.package</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array><string>cutscene</string></array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Under the hardened runtime, microphone and camera access need these
# entitlements on top of the usage strings (Apple, "Hardened Runtime"
# resource-access entitlements); a notarized build without them is refused
# both devices silently. Written beside the bundle so the Developer ID branch
# can hand it to codesign.
ENTITLEMENTS="$ROOT/dist/$APP_NAME.entitlements"
cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.device.camera</key><true/>
</dict>
</plist>
PLIST

# Hardened runtime and a secure timestamp are needed for notarization, so they
# apply only to Developer ID signatures; local identities skip them.
case "$IDENTITY" in
    -)
        codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
        SIGNED_WITH="ad-hoc signature"
        # macOS binds a grant to the exact ad-hoc build. A changed build can
        # never match the stored grant, and System Settings keeps showing the
        # old one as enabled, so drop it and let macOS ask fresh. Builds before
        # 2026-11-03 also persisted the asked-for set in the app's defaults,
        # which would read the fresh state as declined; that key goes too.
        NEW_HASH="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p')"
        LAST_HASH_FILE="$ROOT/.build/last-adhoc-cdhash"
        if [ ! -f "$LAST_HASH_FILE" ] || [ "$(cat "$LAST_HASH_FILE")" != "$NEW_HASH" ]; then
            if tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1; then
                echo "note: new ad-hoc build; cleared the stale Screen Recording grant, macOS will ask once." >&2
            fi
            defaults delete "$BUNDLE_ID" permissions.requested >/dev/null 2>&1 || true
        fi
        echo "$NEW_HASH" > "$LAST_HASH_FILE"
        echo "warning: ad-hoc signature; every code change re-prompts for Screen Recording. Fix once: make dev-cert" >&2
        ;;
    "Developer ID Application"*)
        codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" "$APP"
        SIGNED_WITH="$IDENTITY" ;;
    *)
        codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
        SIGNED_WITH="$IDENTITY" ;;
esac
codesign --verify --verbose=1 "$APP"
echo "Built $APP ($CONFIG, $SIGNED_WITH)"
