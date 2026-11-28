#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
info="$source_dir/Info.plist"
app_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info")"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")"
app="$source_dir/build/$app_name.app"
resources="$app/Contents/Resources"
frameworks="$app/Contents/Frameworks"
mkdir -p "$app/Contents/MacOS" "$resources" "$frameworks"
cp "$info" "$app/Contents/Info.plist"
/usr/bin/plutil -lint "$app/Contents/Info.plist" >&2

sparkle="$("$source_dir/scripts/sparkle.sh")"
framework="$frameworks/Sparkle.framework"
/usr/bin/ditto "$sparkle/Sparkle.framework" "$framework"
cp "$sparkle/LICENSE" "$resources/Sparkle-LICENSE.txt"

icon_work="$(mktemp -d -t display-brightness-icon)"
trap '/usr/bin/find "$icon_work" -depth -delete' EXIT
iconset="$icon_work/DisplayBrightness.iconset"
mkdir "$iconset"
logo="$source_dir/assets/display-brightness-logo.png"
for size in 16 32 128 256 512; do
    double_size=$((size * 2))
    /usr/bin/sips -z "$size" "$size" "$logo" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    /usr/bin/sips -z "$double_size" "$double_size" "$logo" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
icon_file="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info")"
/usr/bin/iconutil -c icns "$iconset" -o "$resources/$icon_file"

/usr/bin/xcrun --sdk macosx swiftc -target arm64-apple-macos13.0 -O \
    -F "$frameworks" -framework Sparkle -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    "$source_dir/main.swift" "$source_dir/DisplayControl.swift" \
    "$source_dir/BrightnessFeedback.swift" "$source_dir/Shortcuts.swift" \
    "$source_dir/BrightnessSettings.swift" -o "$app/Contents/MacOS/$executable"

sign_args=(--force --sign "${MACOS_SIGN_IDENTITY:--}")
if [[ -n ${MACOS_SIGN_IDENTITY:-} ]]; then
    sign_args+=(--options runtime --timestamp)
fi
sparkle_version="$framework/Versions/Current"
for helper in "$sparkle_version"/XPCServices/*.xpc "$sparkle_version/Autoupdate" "$sparkle_version/Updater.app"; do
    /usr/bin/codesign "${sign_args[@]}" --preserve-metadata=entitlements "$helper"
done
/usr/bin/codesign "${sign_args[@]}" "$framework"
/usr/bin/codesign "${sign_args[@]}" "$app"
/usr/bin/codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
