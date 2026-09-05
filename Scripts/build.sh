#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app="$PWD/build/Annotate.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Annotate "$app/Contents/MacOS/Annotate"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"
