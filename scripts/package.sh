#!/bin/zsh
# Builds a Release app and zips it for sharing → build/DragWheel.zip
# Usage: scripts/package.sh            (xcodebuild)
#        SWIFTPM=1 scripts/package.sh  (SwiftPM fallback)
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${SWIFTPM:-0}" == "1" ]]; then
  scripts/package_swiftpm.sh build/Package
  APP="$PWD/build/Package/DragWheel.app"
else
  scripts/build.sh Release
  APP="$PWD/build/Build/Products/Release/DragWheel.app"
fi
rm -f build/DragWheel.zip
# ditto (not Finder's Compress / plain zip) keeps the code signature intact.
ditto -c -k --keepParent "$APP" build/DragWheel.zip
echo "Packaged: $PWD/build/DragWheel.zip"
