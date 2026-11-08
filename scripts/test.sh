#!/bin/zsh
# Runs the unit tests with xcodebuild (hosted in the app). Use `swift test` if xcodebuild is unavailable.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project DragWheel.xcodeproj -scheme DragWheel -configuration Debug \
  -derivedDataPath build/DerivedData.noindex -destination 'platform=macOS' test
