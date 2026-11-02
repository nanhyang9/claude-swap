#!/usr/bin/env bash
# Build "Claude Swap Bar.app" from this Swift package.
#   ./build-app.sh            -> build/Claude Swap Bar.app
#   ./build-app.sh --install  -> also copy it to /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Claude Swap Bar"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CswapBar" "$APP/Contents/MacOS/CswapBar"
cp Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature: enough to run on this Mac. Distributing to other Macs
# needs a Developer ID signature and notarization.
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x CswapBar >/dev/null 2>&1 || true  # stop a running copy first
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$APP_NAME.app"
    echo "Installed to /Applications/$APP_NAME.app"
fi
