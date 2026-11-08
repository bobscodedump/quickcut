#!/bin/zsh
# Builds a Release app and zips it for sharing → build/Zest.zip (containing Zest.app)
# Usage: scripts/package.sh            (xcodebuild)
#        SWIFTPM=1 scripts/package.sh  (SwiftPM fallback)
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${SWIFTPM:-0}" == "1" ]]; then
  scripts/package_swiftpm.sh build/Package.noindex
  APP="$PWD/build/Package.noindex/DragWheel.app"
else
  scripts/build.sh Release
  APP="$PWD/build/DerivedData.noindex/Build/Products/Release/DragWheel.app"
fi
STAGE=build/Share.noindex
rm -rf "$STAGE" build/Zest.zip && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Zest.app"
# ditto (not Finder's Compress / plain zip) keeps the code signature intact.
ditto -c -k --keepParent "$STAGE/Zest.app" build/Zest.zip
rm -rf "$STAGE"
echo "Packaged: $PWD/build/Zest.zip"
