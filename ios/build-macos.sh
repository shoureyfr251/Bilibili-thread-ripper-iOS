#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/ios/build"
mkdir -p "$OUT"
STAGING="$(mktemp -d "$OUT/staging.XXXXXX")"
APP="$STAGING/Payload/BTRTransportTest.app"
# macOS/Xcode only. No login, profile, signing key or Apple account is used.
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$APP"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 \
  -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter \
  -framework Foundation -framework UIKit -framework JavaScriptCore -framework AVFoundation \
  "$ROOT/ios/BTRRangeDownloader.m" "$ROOT/ios/Host.m" \
  "$ROOT/ios/diagnostics/BTRProcessProbe.m" -o "$APP/BTRTransportTest"
cp "$ROOT/ios/Info.plist" "$APP/Info.plist"
cp "$ROOT/src/range-core.js" "$APP/range-core.js"
cp "$ROOT/ios/policy.js" "$APP/policy.js"
plutil -lint "$APP/Info.plist"
file "$APP/BTRTransportTest"
(cd "$STAGING" && zip -q -r BTRTransportTest-unsigned.ipa Payload/BTRTransportTest.app)
mv -f "$STAGING/BTRTransportTest-unsigned.ipa" "$OUT/BTRTransportTest-unsigned.ipa"
echo "$OUT/BTRTransportTest-unsigned.ipa (requires local signing before installation)"
