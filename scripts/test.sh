#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/module-cache"
SWIFT_TOOLCHAIN_ROOT="$(cd "$(dirname "$(xcrun --find swift)")/../.." && pwd)"
TEST_FLAGS=()
if [ -d "$SWIFT_TOOLCHAIN_ROOT/Library/Developer/Frameworks/Testing.framework" ]; then
    TEST_FLAGS+=(-Xswiftc -F -Xswiftc "$SWIFT_TOOLCHAIN_ROOT/Library/Developer/Frameworks")
    TEST_FLAGS+=(-Xlinker -rpath -Xlinker "$SWIFT_TOOLCHAIN_ROOT/Library/Developer/Frameworks")
fi
if [ -d "$SWIFT_TOOLCHAIN_ROOT/usr/lib/swift/host/plugins/testing" ]; then
    TEST_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$SWIFT_TOOLCHAIN_ROOT/usr/lib/swift/host/plugins/testing")
fi
swift test --disable-sandbox --build-system native --manifest-cache local --cache-path "$PROJECT_ROOT/.build/cache" "${TEST_FLAGS[@]}"
