#!/bin/bash
set -e

cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"

echo "Building VideoWallpaper v${VERSION}..."

# Build
swift build -c release

# Update version in Info.plist
sed -i '' "s/<string>[0-9]*\.[0-9]*\.[0-9]*<\/string>/<string>${VERSION}<\/string>/g" \
    VideoWallpaper.app/Contents/Info.plist

# Copy binary into .app
cp .build/release/VideoWallpaper VideoWallpaper.app/Contents/MacOS/

# Also copy standalone binary
cp .build/release/VideoWallpaper .

# Create zip for GitHub Release
zip -r "VideoWallpaper-v${VERSION}-app.zip" VideoWallpaper.app
zip "VideoWallpaper-v${VERSION}-binary.zip" VideoWallpaper

# Clean up
rm -f VideoWallpaper
rm -rf .build

echo ""
echo "Done! Release files:"
echo "  VideoWallpaper-v${VERSION}-app.zip     (drag to /Applications)"
echo "  VideoWallpaper-v${VERSION}-binary.zip  (CLI binary)"
