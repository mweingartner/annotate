#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/build.sh
app="$PWD/build/Annotate.app"
if pgrep -x Annotate >/dev/null; then
    echo "Quit Annotate before installing so macOS can finish saving your documents."
    exit 1
fi
if [[ -e /Applications/Annotate.app ]]; then
    backup="$PWD/build/Annotate-previous-$(date +%Y%m%d-%H%M%S).app"
    mv /Applications/Annotate.app "$backup"
fi
ditto "$app" /Applications/Annotate.app
codesign --verify --deep --strict /Applications/Annotate.app
open /Applications/Annotate.app
echo "Installed /Applications/Annotate.app"
