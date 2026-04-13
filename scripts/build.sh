#!/bin/bash
# Dual-variant build:
#   ./scripts/build.sh 3.0.0            -> stable (no scene)
#   ./scripts/build.sh 3.0.0-beta.1     -> beta (scene enabled, auto-detected)
#   ./scripts/build.sh 3.0.0 beta       -> force beta regardless of version
set -e

cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
MODE="${2:-}"

if [ -z "$MODE" ]; then
    case "$VERSION" in
        *beta*|*alpha*|*rc*) MODE="beta" ;;
        *) MODE="stable" ;;
    esac
fi

SWIFT_FLAGS=""
if [ "$MODE" = "beta" ]; then
    SWIFT_FLAGS="-Xswiftc -DENABLE_SCENE"
    echo "Building VideoWallpaper v${VERSION} (BETA, scene enabled)..."
else
    echo "Building VideoWallpaper v${VERSION} (STABLE, no scene)..."
fi

# Build
rm -rf .build
swift build -c release $SWIFT_FLAGS

# Update version in Info.plist
sed -i '' "s/<string>[0-9][^<]*<\/string>/<string>${VERSION}<\/string>/" \
    VideoWallpaper.app/Contents/Info.plist || true
# Targeted version-key rewrites (robust)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" \
    VideoWallpaper.app/Contents/Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
    VideoWallpaper.app/Contents/Info.plist 2>/dev/null || true

# Copy binary into .app
cp .build/release/VideoWallpaper VideoWallpaper.app/Contents/MacOS/

# Strip extended attributes (xattr leftovers break codesign)
xattr -cr VideoWallpaper.app

# Ad-hoc code sign
codesign --force --deep --sign - VideoWallpaper.app

# Standalone binary
cp .build/release/VideoWallpaper .

# Zip names include variant tag
if [ "$MODE" = "beta" ]; then
    APP_ZIP="VideoWallpaper-v${VERSION}-app.zip"
    BIN_ZIP="VideoWallpaper-v${VERSION}-binary.zip"
else
    APP_ZIP="VideoWallpaper-v${VERSION}-app.zip"
    BIN_ZIP="VideoWallpaper-v${VERSION}-binary.zip"
fi

rm -f "$APP_ZIP" "$BIN_ZIP"
zip -r "$APP_ZIP" VideoWallpaper.app
zip "$BIN_ZIP" VideoWallpaper

# Clean up
rm -f VideoWallpaper
rm -rf .build

echo ""
echo "Done ($MODE)! Release files:"
echo "  $APP_ZIP    (drag to /Applications)"
echo "  $BIN_ZIP    (CLI binary)"
