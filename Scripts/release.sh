#!/bin/sh
# Builds dist/Away-Blur.dmg for other people's Macs: one binary for Apple
# silicon and Intel, signed with the Developer ID, notarized and stapled.
# Pass --publish to put it on a GitHub release tagged with the Info.plist
# version.
#
# Notarization reads credentials saved once with
#   xcrun notarytool store-credentials away-blur --apple-id <id> --team-id S59943574Z
# and NOTARY_PROFILE names a different profile.
set -e
unset SDKROOT
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-away-blur}"
IDENTITY="Developer ID Application"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)

ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/AwayBlur"

STAGE=dist/release
APP="$STAGE/Away Blur.app"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AwayBlur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The hardened runtime is what notarization asks for, and under it the camera
# is refused unless the entitlement says otherwise.
codesign --force --options runtime --timestamp \
    --entitlements Resources/AwayBlur.entitlements \
    --sign "$IDENTITY" --identifier com.dora.away-blur "$APP"
# The app is notarized on its own first, so the ticket can be stapled into the
# bundle. Stapling only the DMG leaves the copy in Applications asking Apple
# about itself the first time it opens, which fails with no network.
ZIP=dist/notarize.zip
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
rm -f "$ZIP"
xcrun stapler staple "$APP"

ln -s /Applications "$STAGE/Applications"

DMG=dist/Away-Blur.dmg
rm -f "$DMG"
hdiutil create -volname "Away Blur" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "built $DMG ($VERSION)"

if [ "$1" = "--publish" ]; then
    gh release create "v$VERSION" "$DMG" --title "Away Blur $VERSION" \
        --notes "macOS 14 or later, Apple silicon and Intel."
fi
