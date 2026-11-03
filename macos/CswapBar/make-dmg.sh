#!/usr/bin/env bash
# Package build/Claude Swap Bar.app (from build-app.sh) into a drag-to-install
# disk image: build/Claude-Swap-Bar-<arch>.dmg.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Claude Swap Bar.app"
if [[ ! -d "$APP" ]]; then
    echo "Build the app first: ./build-app.sh" >&2
    exit 1
fi

DMG="build/Claude-Swap-Bar-$(uname -m).dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Claude Swap Bar" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
