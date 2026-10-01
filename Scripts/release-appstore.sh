#!/bin/zsh
# Builds the Mac App Store package: built with the release Xcode, signed with Apple
# Distribution and the App Store provisioning profile, wrapped in an installer package
# signed for upload. Upload the package with Transporter.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
team=X2J8TBQJWE
profile="${ANNOTATE_PROFILE:-$PWD/build/signing/Annotate_App_Store.provisionprofile}"
[[ -f "$profile" ]] || { echo "Missing the App Store provisioning profile at $profile" >&2; exit 1; }
app_identity=$(security find-identity -v -p codesigning | awk -F'"' "/Apple Distribution: .*\\($team\\)/ { print \$2; exit }")
installer_identity=$(security find-identity -v | awk -F'"' "/(3rd Party Mac Developer Installer|Mac Installer Distribution): .*\\($team\\)/ { print \$2; exit }")
[[ -n "$app_identity" ]] || { echo "No Apple Distribution certificate for team $team in the keychain" >&2; exit 1; }
[[ -n "$installer_identity" ]] || { echo "No Mac Installer Distribution certificate for team $team in the keychain" >&2; exit 1; }

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
app="$PWD/build/AppStore/Annotate.app"
pkg="$PWD/build/AppStore/Annotate-$version.pkg"
mkdir -p "$PWD/build/AppStore"
ANNOTATE_APP="$app" ANNOTATE_SIGN_IDENTITY="$app_identity" ANNOTATE_PROFILE="$profile" \
    ANNOTATE_ENTITLEMENTS="$PWD/Resources/Annotate-AppStore.entitlements" ANNOTATE_SCRATCH=.build-release ./Scripts/build.sh
rm -f "$pkg"
productbuild --component "$app" /Applications --sign "$installer_identity" "$pkg"
pkgutil --check-signature "$pkg" | head -3
echo "Built $pkg"
