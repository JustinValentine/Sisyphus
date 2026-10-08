#!/bin/bash
# Drives the app's real ride recording and Strava code against a temporary folder, a temporary
# Keychain item and a stubbed Strava, so nothing touches your rides, credentials or the network.
# Takes about 45 seconds, mostly a real-time ride long enough to autosave.
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
OUT="$PWD/.build/integration"
mkdir -p "$OUT"
swiftc -emit-library -static -parse-as-library -module-name SisyphusCore \
    -emit-module -emit-module-path "$OUT/SisyphusCore.swiftmodule" Sources/SisyphusCore/*.swift -o "$OUT/libSisyphusCore.a"
APP_SOURCES=()
for file in Sources/Sisyphus/*.swift; do [[ "$file" == */SisyphusApp.swift ]] || APP_SOURCES+=("$file"); done
swiftc -parse-as-library -swift-version 5 -module-name Integration -I "$OUT" -L "$OUT" -lSisyphusCore \
    Tests/Integration/Harness.swift "${APP_SOURCES[@]}" -o "$OUT/integration"
"$OUT/integration"
