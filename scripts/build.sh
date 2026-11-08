#!/bin/zsh
# Builds DragWheel.app with xcodebuild. Signs with your Apple Development certificate if you have one,
# otherwise ad-hoc (the Accessibility grant may then need re-granting after each rebuild).
# Usage: scripts/build.sh [Release|Debug]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Release}"
# Build products live in *.noindex folders, which Spotlight / Launchpad skip (otherwise every build
# shows up as another "DragWheel" app).

IDENTITY="$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
SIGN_ARGS=()
if [[ -n "$IDENTITY" ]]; then
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY")
  echo "Signing with: $IDENTITY"
else
  echo "No Apple Development certificate found: ad-hoc signing."
  echo "  -> macOS may ask you to re-grant Accessibility after every rebuild."
fi

xcodebuild -project DragWheel.xcodeproj -scheme DragWheel -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData.noindex -destination 'platform=macOS' "${SIGN_ARGS[@]}" build

echo "Built: $PWD/build/DerivedData.noindex/Build/Products/$CONFIG/DragWheel.app"
