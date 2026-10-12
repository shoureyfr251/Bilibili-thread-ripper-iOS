#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/ios/build"
mkdir -p "$OUT"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -dynamiclib -arch arm64 -isysroot "$SDK" \
  -miphoneos-version-min=15.0 -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter \
  -framework Foundation -framework UIKit -framework AVFoundation -framework JavaScriptCore \
  -install_name @rpath/libBTRProcessProbe.dylib \
  "$ROOT/ios/diagnostics/BTRProcessProbe.m" \
  "$ROOT/ios/BTRRangeDownloader.m" "$ROOT/ios/BTRLoopbackRangeAdapter.m" \
  -o "$OUT/libBTRProcessProbe.dylib"
file "$OUT/libBTRProcessProbe.dylib"
echo "$OUT/libBTRProcessProbe.dylib (requires approved same-process integration and signing)"
