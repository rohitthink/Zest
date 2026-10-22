#!/bin/zsh
# Package the SwiftPM ZestApp executable into a real macOS .app bundle so the
# zest:// URL scheme and the Shortcuts action register system-wide.
# Usage: Scripts/package-app.sh [debug|release]
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
DIST="$ROOT/dist"
APP="$DIST/Zest.app"

echo ">> building ZestApp + zest CLI ($CONFIG)"
swift build -c "$CONFIG" --product ZestApp --package-path "$ROOT"
swift build -c "$CONFIG" --product zest --package-path "$ROOT"
BINDIR="$(swift build -c "$CONFIG" --product ZestApp --package-path "$ROOT" --show-bin-path)"
BIN="$BINDIR/ZestApp"
[ -x "$BIN" ] || { echo "build output not found: $BIN"; exit 1; }
[ -x "$BINDIR/zest" ] || { echo "build output not found: $BINDIR/zest"; exit 1; }

echo ">> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/ZestApp"
# The CLI ships inside the app; Settings › Shortcuts shows the one-line symlink.
cp "$BINDIR/zest" "$APP/Contents/Helpers/zest"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# AppIntents metadata — only available with a full Xcode toolchain; the URL
# scheme works without it.
PROC="$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)"
if [ -n "$PROC" ]; then
    echo ">> extracting AppIntents metadata"
    "$PROC" --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
        --module-name ZestApp --output "$APP/Contents/Resources" \
        --source-files "$ROOT/Sources/ZestApp/"*.swift \
        --binary-file "$APP/Contents/MacOS/ZestApp" 2>/dev/null \
        && echo "   AppIntents metadata written" \
        || echo "   (extractor failed; build via Xcode for the Shortcuts action — URL scheme unaffected)"
else
    echo ">> appintentsmetadataprocessor not found (Command Line Tools only)"
    echo "   The Shortcuts action needs an Xcode build; the zest:// URL scheme works regardless."
fi

echo ">> ad-hoc codesign"
codesign --force --deep --sign - "$APP" 2>&1 | sed 's/^/   /' || true

echo ">> register with Launch Services"
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$APP" || echo "   (lsregister unavailable; 'open $APP' once to register)"

echo ">> done: $APP"
echo "   launch:  open \"$APP\""
echo "   test URL scheme:  open \"zest://convert?input=\$HOME/Desktop/photo.heic&to=jpg\""
echo "   CLI on PATH:      sudo mkdir -p /usr/local/bin && sudo ln -sf \"$APP/Contents/Helpers/zest\" /usr/local/bin/zest"
