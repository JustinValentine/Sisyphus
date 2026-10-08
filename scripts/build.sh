#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
swift build -c release --product Sisyphus --disable-sandbox --cache-path "$PWD/.build/cache"
APP="$PWD/build/Sisyphus.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Replace rather than overwrite in place: macOS kills a signed binary whose pages change underneath it.
rm -f "$APP/Contents/MacOS/Sisyphus"
cp .build/release/Sisyphus "$APP/Contents/MacOS/Sisyphus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
ICONSET="$PWD/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
"$APP/Contents/MacOS/Sisyphus" --render-icon "$PWD/.build/AppIcon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PWD/.build/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$PWD/.build/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
python3 scripts/package_icon.py "$ICONSET" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
