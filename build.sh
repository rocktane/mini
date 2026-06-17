#!/bin/bash
set -euo pipefail

VERSION="${1:-0.1.0}"

cd "$(dirname "$0")"

echo "==> Cleaning previous artifacts..."
rm -rf "Mini.app"

echo "==> Building release (MiniApp + MiniCLI)..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
APP_DIR="Mini.app/Contents"
mkdir -p "$APP_DIR/MacOS" "$APP_DIR/Resources"

echo "==> Bundling Mini.app (v$VERSION)..."
sed "s/VERSION/$VERSION/g" Resources/Info.plist > "$APP_DIR/Info.plist"
cp "$BIN_PATH/MiniApp" "$APP_DIR/MacOS/MiniApp"
cp "$BIN_PATH/MiniCLI" "$APP_DIR/Resources/mini-cli"

echo "==> Done: $(pwd)/Mini.app"
echo ""
echo "Run with:  open Mini.app"
