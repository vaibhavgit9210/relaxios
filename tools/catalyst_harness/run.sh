#!/bin/bash
# Runtime check of the app's playback logic as a Mac Catalyst build (no Xcode needed).
# Builds 8 s HEVC test loops (plus one corrupt file), links the app sources with
# Harness.swift, then drives launch, rotation (window resize), swipes, a failing
# file, pause/resume and looping. Opens a small window for ~26 s. Exit 0 = all pass.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; defaults delete dev.vaibhavkumar.relaxios.harness >/dev/null 2>&1 || true' EXIT
SDK="$(xcrun --show-sdk-path)"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
APP="$WORK/Relaxios.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Videos"

for scene in window plains sea; do
  for orientation in portrait landscape; do
    size=1280x720; [ "$orientation" = portrait ] && size=720x1280
    out="$APP/Contents/Resources/Videos/${scene}_${orientation}_720.mp4"
    if [ "$scene$orientation" = seaportrait ]; then head -c 200000 /dev/urandom > "$out"; continue; fi
    "$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=${size}:rate=30:duration=8" \
      -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -tag:v hvc1 \
      -x265-params log-level=error:keyint=60 -movflags +faststart "$out"
  done
done

clang -c -target arm64-apple-ios16.0-macabi -isysroot "$SDK" -fobjc-arc "$HERE/boot.m" -o "$WORK/boot.o"
swiftc -module-name Relaxios -target arm64-apple-ios16.0-macabi -sdk "$SDK" \
  -Fsystem "$SDK/System/iOSSupport/System/Library/Frameworks" -I "$SDK/System/iOSSupport/usr/include" \
  -L "$SDK/System/iOSSupport/usr/lib" -L "$SDK/System/iOSSupport/usr/lib/swift" \
  "$ROOT"/Relaxios/*.swift "$HERE/Harness.swift" "$WORK/boot.o" -o "$APP/Contents/MacOS/Relaxios"

sed -e 's/$(DEVELOPMENT_LANGUAGE)/en/; s/$(EXECUTABLE_NAME)/Relaxios/; s/$(PRODUCT_NAME)/Relaxios/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/dev.vaibhavkumar.relaxios.harness/; s/$(PRODUCT_BUNDLE_PACKAGE_TYPE)/APPL/' \
    -e 's/$(MARKETING_VERSION)/1.0/; s/$(CURRENT_PROJECT_VERSION)/1/; s/$(PRODUCT_MODULE_NAME)/Relaxios/' \
    "$ROOT/Relaxios/Info.plist" > "$APP/Contents/Info.plist"
plutil -remove LSRequiresIPhoneOS "$APP/Contents/Info.plist"
plutil -insert UIDeviceFamily -json '[2,6]' "$APP/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string 13.0 "$APP/Contents/Info.plist"
codesign -s - --force "$APP" 2>/dev/null
defaults delete dev.vaibhavkumar.relaxios.harness >/dev/null 2>&1 || true

"$APP/Contents/MacOS/Relaxios" 2>/dev/null &
PID=$!
( sleep 60; kill "$PID" 2>/dev/null ) &
WATCHDOG=$!
STATUS=0
wait "$PID" || STATUS=$?
kill "$WATCHDOG" 2>/dev/null || true
exit "$STATUS"
