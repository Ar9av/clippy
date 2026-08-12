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

# Built one architecture at a time and stitched together, rather than with
# SwiftPM's own `--arch arm64 --arch x86_64`. That combined form fails while
# resolving the package graph — "duplicate key found: ID(moduleName:
# "ArgmaxCLI" ...)" from the WhisperKit dependency — so the universal build had
# been broken and only arm64 slices were shipping. Each arch resolves fine on
# its own, and `lipo` produces exactly the same fat binary.
swift build -c release --arch arm64
swift build -c release --arch x86_64
ARM64_BIN="$PROJECT_DIR/.build/arm64-apple-macosx/release/Clippy"
X86_BIN="$PROJECT_DIR/.build/x86_64-apple-macosx/release/Clippy"
UNIVERSAL_BIN="$BUILD_DIR/Clippy-universal"
mkdir -p "$BUILD_DIR"
lipo -create -output "$UNIVERSAL_BIN" "$ARM64_BIN" "$X86_BIN"

rm -rf "$APP_DIR" "$DMG_ROOT" "$ICONSET_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$DMG_ROOT" "$ICONSET_DIR"

cp "$UNIVERSAL_BIN" "$CONTENTS_DIR/MacOS/Clippy"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp -R "$PROJECT_DIR/Sources/ClippyMac/Resources/Characters" "$CONTENTS_DIR/Resources/Characters"

# The Prismor policy that defines every on-screen refusal. Clippy fails closed
# without it — a shipped app missing this file would refuse every screen
# action rather than run unguarded — so a build that somehow lost it is a
# broken build, not a degraded one. Recompile from the YAML first so the
# shipped policy can never lag the source of truth.
"$SCRIPT_DIR/compile-policy.sh"
POLICY_SOURCE="$PROJECT_DIR/Sources/ClippyCore/Resources/prismor-policy.json"
cp "$POLICY_SOURCE" "$CONTENTS_DIR/Resources/prismor-policy.json"
if [[ ! -s "$CONTENTS_DIR/Resources/prismor-policy.json" ]]; then
    echo "error: the Prismor policy is missing from the app bundle" >&2
    exit 1
fi

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
# silently denied. It also grants com.apple.security.device.audio-input, which
# the hardened runtime likewise requires for dictation: without it
# AVCaptureDevice.requestAccess(for: .audio) is refused outright, with no
# system prompt and no entry under Privacy & Security > Microphone, so
# dictation just reports "Microphone permission is required" forever.
# Keep the entitlements plist itself comment-free: AMFI's
# entitlements parser (unlike a general plist parser) rejects XML comments.
codesign --force --options runtime --entitlements "$SCRIPT_DIR/Clippy.entitlements" --sign "$SIGN_IDENTITY" "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"

# A DMG that silently lost its Intel slice would only be discovered by an
# Intel user, so check here instead.
ARCHS="$(lipo -archs "$CONTENTS_DIR/MacOS/Clippy")"
for required in arm64 x86_64; do
    case " $ARCHS " in
        *" $required "*) ;;
        *) echo "error: shipped binary is missing $required (got: $ARCHS)" >&2; exit 1 ;;
    esac
done
echo "Universal binary: $ARCHS"

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
