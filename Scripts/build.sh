#!/bin/zsh
# Builds Annotate.app. By default a local build: ad-hoc signed, and sandboxed exactly like
# the store build so what you test is what ships. The release scripts set:
#   ANNOTATE_APP            where to put the app (default build/Annotate.app)
#   ANNOTATE_SIGN_IDENTITY  signing identity (default "-", ad-hoc)
#   ANNOTATE_ENTITLEMENTS   entitlements file (default Resources/Annotate.entitlements)
#   ANNOTATE_PROFILE        provisioning profile to embed (App Store builds)
#   ANNOTATE_TIMESTAMP=1    request a secure timestamp (Developer ID builds)
#   ANNOTATE_SCRATCH        SwiftPM build folder (default .build)
set -euo pipefail
cd "$(dirname "$0")/.."
app="${ANNOTATE_APP:-$PWD/build/Annotate.app}"
identity="${ANNOTATE_SIGN_IDENTITY:--}"
entitlements="${ANNOTATE_ENTITLEMENTS:-$PWD/Resources/Annotate.entitlements}"
scratch="${ANNOTATE_SCRATCH:-.build}"

swift build -c release --scratch-path "$scratch"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$scratch/release/Annotate" "$app/Contents/MacOS/Annotate"
cp Resources/Info.plist "$app/Contents/Info.plist"

# The asset catalog: the app icon at every size, and Lagoon, Atrium's accent, for people
# who choose Multicolor in System Settings.
partial=$(mktemp -t annotate-assets).plist
xcrun actool Resources/Assets.xcassets --compile "$app/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist "$partial" \
    --output-format human-readable-text --notices --warnings >/dev/null
/usr/libexec/PlistBuddy -c "Merge $partial" "$app/Contents/Info.plist" >/dev/null
rm -f "$partial"
# actool's AppIcon.icns keeps only the small sizes; the App Store also checks the .icns for
# 512 and 1024 pixels, so write it from the same icon set at every size.
icons=$(mktemp -d -t annotate-icon)
mkdir "$icons/AppIcon.iconset"
cp Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png "$icons/AppIcon.iconset/"
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$icons/AppIcon.iconset"
rm -rf "$icons"

# What Xcode records about the toolchain; App Store Connect checks the SDK and Xcode used.
sdk_version=$(xcrun --sdk macosx --show-sdk-version)
sdk_build=$(xcrun --sdk macosx --show-sdk-build-version)
xcode_version=$(xcodebuild -version | awk '/^Xcode/ { split($2, v, "."); printf "%d%d%d", v[1], v[2], v[3] }')
xcode_build=$(xcodebuild -version | awk '/Build version/ { print $3 }')
plist="$app/Contents/Info.plist"
for entry in "DTPlatformName string macosx" "DTPlatformVersion string $sdk_version" "DTPlatformBuild string $sdk_build" \
             "DTSDKName string macosx$sdk_version" "DTSDKBuild string $sdk_build" "DTXcode string $xcode_version" \
             "DTXcodeBuild string $xcode_build" "DTCompiler string com.apple.compilers.llvm.clang.1_0" \
             "BuildMachineOSBuild string $(sw_vers -buildVersion)"; do
    key=${entry%% *}
    /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :$entry" "$plist"
done

if [[ -n "${ANNOTATE_PROFILE:-}" ]]; then cp "$ANNOTATE_PROFILE" "$app/Contents/embedded.provisionprofile"; fi
timestamp=(--timestamp=none)
if [[ "${ANNOTATE_TIMESTAMP:-0}" == 1 ]]; then timestamp=(--timestamp); fi
codesign --force --options runtime "${timestamp[@]}" --entitlements "$entitlements" --sign "$identity" "$app"
codesign --verify --strict "$app"
echo "Built $app"
