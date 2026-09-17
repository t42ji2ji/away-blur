#!/bin/sh
# Builds Away Blur into dist/Away Blur.app. Pass --run to relaunch it.
set -e
# Xcode 27 is installed but the shell exports a stale SDKROOT; ignore it.
unset SDKROOT
cd "$(dirname "$0")/.."

CONFIG=release
swift build -c "$CONFIG"

APP="dist/Away Blur.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/AwayBlur" "$APP/Contents/MacOS/AwayBlur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.dora.away-blur "$APP" >/dev/null
echo "built $APP"

if [ "$1" = "--run" ]; then
    pkill -x AwayBlur 2>/dev/null || true
    open "$APP"
fi
