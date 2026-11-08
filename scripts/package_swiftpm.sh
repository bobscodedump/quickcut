#!/bin/zsh
# Fallback packaging when xcodebuild is unavailable: builds with SwiftPM and wraps the binary in an ad-hoc signed .app.
# Usage: scripts/package_swiftpm.sh [output-dir]   (default: ./build/Package)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/Package}"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/DragWheel"
APP="$OUT/DragWheel.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/DragWheel"
sed -e 's/$(EXECUTABLE_NAME)/DragWheel/g' -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/local.dragwheel.DragWheel/g' \
    -e 's/$(PRODUCT_NAME)/DragWheel/g' -e 's/$(MACOSX_DEPLOYMENT_TARGET)/14.0/g' DragWheel/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
