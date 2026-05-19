#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "Building PawTerm.app…"
swift build -c release --arch arm64 --arch x86_64

APP="PawTerm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Sources/PawTerm/Info.plist "$APP/Contents/Info.plist"
cp .build/apple/Products/Release/PawTerm "$APP/Contents/MacOS/PawTerm"

SIZE=$(du -sh "$APP/Contents/MacOS/PawTerm" | awk '{print $1}')
APP_SIZE=$(du -sh "$APP" | awk '{print $1}')

echo ""
echo "Built $APP  (binary: $SIZE, total: $APP_SIZE)"
echo ""
echo "Install:"
echo "  mv $APP /Applications/"
echo "  xattr -d com.apple.quarantine /Applications/$APP"
