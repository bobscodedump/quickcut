#!/bin/zsh
# Builds a Release app and installs it to /Applications, then launches it.
# Usage: scripts/install.sh            (xcodebuild)
#        SWIFTPM=1 scripts/install.sh  (SwiftPM fallback if xcodebuild is broken)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${SWIFTPM:-0}" == "1" ]]; then
  scripts/package_swiftpm.sh build/Package.noindex
  APP="$PWD/build/Package.noindex/DragWheel.app"
else
  scripts/build.sh Release
  APP="$PWD/build/DerivedData.noindex/Build/Products/Release/DragWheel.app"
fi

# The app is shown and installed as "Zest" (the project, executable and bundle ID are still DragWheel).
DEST=/Applications/Zest.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
pkill -x DragWheel 2>/dev/null || true
sleep 0.5
# Remove the copy installed under the old name, so there's only one app.
if [[ -d /Applications/DragWheel.app ]]; then
  "$LSREGISTER" -u /Applications/DragWheel.app 2>/dev/null || true
  rm -rf /Applications/DragWheel.app
  echo "Removed old /Applications/DragWheel.app"
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
open "$DEST"
echo "Installed and launched $DEST"
