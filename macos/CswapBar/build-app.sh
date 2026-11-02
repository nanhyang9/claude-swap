#!/usr/bin/env bash
# Build "Claude Swap Bar.app" — a self-contained menu bar app.
#
# The bundle carries its own Python runtime (python-build-standalone) with
# claude-swap from this checkout installed into it, so nothing else needs to be
# installed on the Mac (Claude Code itself excepted).
#
#   ./build-app.sh            -> build/Claude Swap Bar.app
#   ./build-app.sh --install  -> also copy it to /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"
REPO_ROOT="$(cd ../.. && pwd)"

APP_NAME="Claude Swap Bar"

# Pinned runtime: https://github.com/astral-sh/python-build-standalone
# (release tag, CPython version, and the SHA-256 values from that release's
# SHA256SUMS). Bump all three together.
PY_RELEASE="20261026"
PY_VERSION="3.13.18"
case "$(uname -m)" in
    arm64)
        PY_ARCH="aarch64"
        PY_SHA256="e5af2fde6a937a0e0c795a0c595c4efb70578d57463a2657c819992b9b9acbac"
        ;;
    x86_64)
        PY_ARCH="x86_64"
        PY_SHA256="708be9e7df297f68bdae589ea9e62a621db5abe7708f79e851c41410347452d1"
        ;;
    *)
        echo "Unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac
PY_ASSET="cpython-${PY_VERSION}+${PY_RELEASE}-${PY_ARCH}-apple-darwin-install_only.tar.gz"
PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_RELEASE}/${PY_ASSET//+/%2B}"

# 1. The Swift app.
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/$APP_NAME.app"
RES="$APP/Contents/Resources"
RUNTIME="$RES/runtime"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"
cp "$BIN_DIR/CswapBar" "$APP/Contents/MacOS/CswapBar"
cp Info.plist "$APP/Contents/Info.plist"

# 2. The Python runtime (downloaded once, checksum-verified, cached).
mkdir -p .cache
ARCHIVE=".cache/$PY_ASSET"
if [[ ! -f "$ARCHIVE" ]]; then
    echo "Downloading $PY_ASSET"
    curl -fL --retry 3 -o "$ARCHIVE.part" "$PY_URL"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
echo "$PY_SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null || {
    echo "Checksum mismatch for $ARCHIVE — deleting it; run the script again." >&2
    rm -f "$ARCHIVE"
    exit 1
}
mkdir -p "$RUNTIME"
tar -xzf "$ARCHIVE" -C "$RUNTIME" --strip-components 1

# 3. claude-swap from this checkout, into the bundled runtime.
PY="$RUNTIME/bin/python3"
"$PY" -m pip install --quiet --no-cache-dir --disable-pip-version-check \
    --no-warn-script-location "$REPO_ROOT"

# Drop what a headless CLI never uses (Tk GUI toolkit, IDLE, headers, docs,
# and pip itself once claude-swap is in).
rm -rf "$RUNTIME"/lib/python3.*/{idlelib,tkinter,turtledemo,ensurepip} \
       "$RUNTIME"/lib/python3.*/site-packages/pip "$RUNTIME"/lib/python3.*/site-packages/pip-* \
       "$RUNTIME"/bin/pip* \
       "$RUNTIME"/lib/python3.*/lib-dynload/_tkinter* \
       "$RUNTIME"/lib/{tcl9,tcl9.0,tk9.0,itcl*,thread*} \
       "$RUNTIME"/lib/libtcl* \
       "$RUNTIME"/bin/idle* \
       "$RUNTIME"/include "$RUNTIME"/share

# pip's console-script wrappers hard-code this build directory in their
# shebang and would break once the app moves; the app and the launcher below
# run `python3 -m claude_swap` instead.
rm -f "$RUNTIME"/bin/cswap "$RUNTIME"/bin/claude-swap

# Precompile so the runtime never has to write bytecode into the signed bundle.
"$PY" -m compileall -q "$RUNTIME/lib" >/dev/null || true

# A `cswap` launcher that runs the bundled copy; link it onto your PATH to use
# the same claude-swap from a terminal (see README).
mkdir -p "$RES/bin"
cat > "$RES/bin/cswap" <<'LAUNCHER'
#!/bin/sh
# Runs the claude-swap bundled in Claude Swap Bar.app.
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
RUNTIME="$(cd "$(dirname "$SELF")/../runtime" && pwd)"
PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 exec "$RUNTIME/bin/python3" -m claude_swap "$@"
LAUNCHER
chmod +x "$RES/bin/cswap"

# 4. Sign. Every Mach-O inside the runtime first, then the app itself.
# Ad-hoc signatures are enough to run on this Mac; distributing to other Macs
# needs a Developer ID signature and notarization.
find "$RUNTIME" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0 |
    while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q 'Mach-O'; then
            codesign --force --sign - "$f"
        fi
    done
codesign --force --sign - "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x CswapBar >/dev/null 2>&1 || true  # stop a running copy first
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$APP_NAME.app"
    echo "Installed to /Applications/$APP_NAME.app"
fi
