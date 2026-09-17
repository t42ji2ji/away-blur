#!/bin/sh
# Renders the icon out of the app itself — the same blur, the same cat — and
# packs it into Resources/AppIcon.icns. Run it after the art changes.
set -e
unset SDKROOT
cd "$(dirname "$0")/.."

APP="dist/Away Blur.app/Contents/MacOS/AwayBlur"
[ -x "$APP" ] || { echo "build first: Scripts/build.sh" >&2; exit 1; }

SET=$(mktemp -d)/AppIcon.iconset
"$APP" --iconset "$SET" >/dev/null
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$SET")"
echo "wrote Resources/AppIcon.icns"
