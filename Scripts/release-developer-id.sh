#!/bin/zsh
# Builds the notarized download for GitHub releases: built with the release Xcode, signed
# with Developer ID, notarized by Apple and stapled, so it opens without "Open Anyway".
# Notarization uses a keychain profile created once with
#   xcrun notarytool store-credentials annotate-notary --apple-id <you> --team-id X2J8TBQJWE
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
team=X2J8TBQJWE
identity=$(security find-identity -v -p codesigning | awk -F'"' "/Developer ID Application: .*\\($team\\)/ { print \$2; exit }")
[[ -n "$identity" ]] || { echo "No Developer ID Application certificate for team $team in the keychain" >&2; exit 1; }

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
app="$PWD/build/DeveloperID/Annotate.app"
zip="$PWD/build/DeveloperID/Annotate-$version-macOS-arm64.zip"
mkdir -p "$PWD/build/DeveloperID"
ANNOTATE_APP="$app" ANNOTATE_SIGN_IDENTITY="$identity" ANNOTATE_TIMESTAMP=1 ANNOTATE_SCRATCH=.build-release ./Scripts/build.sh
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "${ANNOTATE_NOTARY_PROFILE:-annotate-notary}" --wait
xcrun stapler staple "$app"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
spctl --assess --type execute -vv "$app"
shasum -a 256 "$zip"
