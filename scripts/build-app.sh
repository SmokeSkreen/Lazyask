#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
CONFIGURATION="${CONFIGURATION:-release}"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"
swift build --disable-sandbox --build-system native --manifest-cache local --cache-path "$PROJECT_ROOT/.build/cache" -c "$CONFIGURATION"
BIN_DIR="$(swift build --disable-sandbox --build-system native --manifest-cache local --cache-path "$PROJECT_ROOT/.build/cache" -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="$PROJECT_ROOT/dist/Lazy Ask.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/LazyAsk" "$APP_DIR/Contents/MacOS/LazyAsk"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
# Desktop sync can add Finder metadata that interferes with code signing.
xattr -dr com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP_DIR" 2>/dev/null || true
codesign --force --sign - --identifier app.lazyask.desktop "$APP_DIR"
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
codesign --verify --deep --strict "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
