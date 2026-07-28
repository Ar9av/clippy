#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/Clippy.app"
CONTENTS_DIR="$APP_DIR/Contents"
DMG_ROOT="$BUILD_DIR/dmg"
DMG_PATH="$BUILD_DIR/Clippy-macOS-universal.dmg"
SOURCE_ICON="$PROJECT_DIR/Resources/ClippyIcon.png"
ICONSET_DIR="$BUILD_DIR/Clippy.iconset"
SWIFT_BUILD_DIR="$PROJECT_DIR/.build/apple/Products/Release"

cd "$PROJECT_DIR"
swift build -c release --arch arm64 --arch x86_64

rm -rf "$APP_DIR" "$DMG_ROOT" "$ICONSET_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$DMG_ROOT" "$ICONSET_DIR"

cp "$SWIFT_BUILD_DIR/Clippy" "$CONTENTS_DIR/MacOS/Clippy"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Sources/ClippyMac/Resources/ClippySprites.png" "$CONTENTS_DIR/Resources/ClippySprites.png"
cp "$PROJECT_DIR/Sources/ClippyMac/Resources/ClippyAnimations.json" "$CONTENTS_DIR/Resources/ClippyAnimations.json"

PADDED_ICON="$BUILD_DIR/clippy-square.png"
cp "$SOURCE_ICON" "$PADDED_ICON"
sips -p 512 512 --padColor FFFFFF "$PADDED_ICON" >/dev/null

for spec in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"; do
    size="${spec%% *}"
    filename="${spec#* }"
    sips -z "$size" "$size" "$PADDED_ICON" --out "$ICONSET_DIR/$filename" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$CONTENTS_DIR/Resources/Clippy.icns"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$CODESIGN_IDENTITY"
else
    SIGN_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/Apple Development:/ { print $2; exit }'
    )"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
echo "Signing with: $SIGN_IDENTITY"
# Clippy.entitlements grants com.apple.security.automation.apple-events —
# ScreenTypingService.performPasteWithSystemEvents sends System Events Apple
# Events to paste generated text, and under the hardened runtime
# (--options runtime below) that requires this entitlement or the request is
# silently denied. Keep the entitlements plist itself comment-free: AMFI's
# entitlements parser (unlike a general plist parser) rejects XML comments.
codesign --force --options runtime --entitlements "$SCRIPT_DIR/Clippy.entitlements" --sign "$SIGN_IDENTITY" "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"

cp -R "$APP_DIR" "$DMG_ROOT/Clippy.app"
ln -s /Applications "$DMG_ROOT/Applications"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "Clippy" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
hdiutil verify "$DMG_PATH"

echo "$DMG_PATH"
