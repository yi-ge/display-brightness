#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
app="$source_dir/build/RV100 Brightness.app"
mkdir -p "$app/Contents/MacOS"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
/usr/bin/plutil -lint "$app/Contents/Info.plist" >&2
/usr/bin/xcrun --sdk macosx swiftc -target arm64-apple-macos13.0 -O \
    "$source_dir/main.swift" "$source_dir/DisplayControl.swift" \
    "$source_dir/BrightnessFeedback.swift" -o "$app/Contents/MacOS/RV100Brightness"

if [[ -n ${MACOS_SIGN_IDENTITY:-} ]]; then
    /usr/bin/codesign --force --options runtime --timestamp --sign "$MACOS_SIGN_IDENTITY" "$app"
else
    /usr/bin/codesign --force --sign - "$app"
fi
/usr/bin/codesign --verify --strict "$app"
printf '%s\n' "$app"
