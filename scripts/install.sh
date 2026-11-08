#!/bin/zsh
# Builds a Release app and installs it to /Applications, then launches it.
# Usage: scripts/install.sh            (xcodebuild)
#        SWIFTPM=1 scripts/install.sh  (SwiftPM fallback if xcodebuild is broken)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${SWIFTPM:-0}" == "1" ]]; then
  scripts/package_swiftpm.sh build/Package
  APP="$PWD/build/Package/DragWheel.app"
else
  scripts/build.sh Release
  APP="$PWD/build/Build/Products/Release/DragWheel.app"
fi

pkill -x DragWheel 2>/dev/null || true
sleep 0.5
rm -rf /Applications/DragWheel.app
ditto "$APP" /Applications/DragWheel.app
xattr -dr com.apple.quarantine /Applications/DragWheel.app 2>/dev/null || true
open /Applications/DragWheel.app
echo "Installed and launched /Applications/DragWheel.app"
