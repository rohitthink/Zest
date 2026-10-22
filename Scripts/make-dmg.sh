#!/bin/zsh
# Build a shareable disk image: the universal Zest.app, an Applications
# shortcut to drag it onto, and "Read Me First.pdf" (rendered from
# Packaging/Guide/guide.html). Friends get it by AirDrop, a USB stick or a
# download link.
#
# Usage: Scripts/make-dmg.sh            (rebuilds the app first)
#        Scripts/make-dmg.sh --no-build (packs the existing dist/Zest.app)
#
# The app is ad-hoc signed, not notarized: the guide walks friends through
# macOS's one-time "Open Anyway". A Developer ID + notarization removes that.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Zest.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Packaging/Info.plist")"
DMG="$DIST/Zest-$VERSION.dmg"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zest-dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ "$1" != "--no-build" ]; then
    "$ROOT/Scripts/package-app.sh" release
fi
[ -d "$APP" ] || { echo "no app at $APP — run Scripts/package-app.sh"; exit 1; }

echo ">> rendering Read Me First.pdf"
swiftc -O "$ROOT/Packaging/Guide/render-pdf.swift" -o "$WORK/render-pdf" 2>/dev/null
"$WORK/render-pdf" "$ROOT/Packaging/Guide/guide.html" "$WORK/Read Me First.pdf"

echo ">> staging"
STAGE="$WORK/Zest"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Zest.app"
ln -s /Applications "$STAGE/Applications"
cp "$WORK/Read Me First.pdf" "$STAGE/Read Me First.pdf"
cp "$WORK/Read Me First.pdf" "$DIST/Read Me First.pdf"   # a copy to preview or send on its own

echo ">> creating $DMG"
rm -f "$DMG"
hdiutil create -volname "Zest $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" 2>/dev/null >/dev/null
hdiutil verify "$DMG" 2>/dev/null >/dev/null && echo "   verified"

echo ">> done: $DMG ($(du -h "$DMG" | cut -f1))"
echo "   share it by AirDrop; friends open it, drag Zest to Applications, and read the PDF."
