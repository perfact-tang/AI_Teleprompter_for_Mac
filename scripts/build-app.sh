#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo 'Usage: build-app.sh [debug|release]' >&2; exit 2;; esac
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swift build --disable-sandbox -c "$configuration"
bin_dir="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)"
app="$PWD/dist/LocalPrompter.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/LocalPrompter" "$app/Contents/MacOS/LocalPrompter"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --identifier com.perfacttang.LocalPrompter "$app"
echo "Built: $app"
