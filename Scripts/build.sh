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
if [ -f Resources/AppIcon.icns ]; then
    mkdir -p "$APP/Contents/Resources"
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# A stable signing identity matters more than it looks: Screen Recording is
# remembered against the signature, and an ad-hoc one changes with every build,
# so every rebuild would cost another trip to System Settings.
IDENTITY="Away Blur Dev"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --identifier com.dora.away-blur "$APP" >/dev/null
else
    echo "warning: '$IDENTITY' is not in the keychain; signing ad-hoc, which drops Screen Recording" >&2
    codesign --force --sign - --identifier com.dora.away-blur "$APP" >/dev/null
fi
echo "built $APP"

if [ "$1" = "--run" ]; then
    pkill -x AwayBlur 2>/dev/null || true
    open "$APP"
fi
