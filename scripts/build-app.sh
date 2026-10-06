#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
assert_app_stopped() {
    local running_status=0
    pgrep -x LazyAsk >/dev/null || running_status=$?
    case "$running_status" in
        0)
            printf 'Quit Lazy Ask, then run this command again to update the same app.\n' >&2
            exit 1
            ;;
        1) ;;
        *)
            printf 'Could not check whether Lazy Ask is running. Try from a regular Terminal window.\n' >&2
            exit 1
            ;;
    esac
}
assert_app_stopped
CONFIGURATION="${CONFIGURATION:-release}"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"
swift build --disable-sandbox --build-system native --manifest-cache local --cache-path "$PROJECT_ROOT/.build/cache" -c "$CONFIGURATION"
BIN_DIR="$(swift build --disable-sandbox --build-system native --manifest-cache local --cache-path "$PROJECT_ROOT/.build/cache" -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="$PROJECT_ROOT/dist/Lazy Ask.app"
assert_app_stopped
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
