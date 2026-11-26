#!/bin/bash
set -euo pipefail

: "${MACOS_SIGN_IDENTITY:?Set MACOS_SIGN_IDENTITY to a Developer ID Application identity}"
: "${MACOS_NOTARY_PROFILE:?Set MACOS_NOTARY_PROFILE to a notarytool Keychain profile}"
export MACOS_SIGN_IDENTITY

source_dir="$(cd "$(dirname "$0")" && pwd)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_dir/Info.plist")"
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Invalid release version in Info.plist: %s\n' "$version" >&2
    exit 1
fi

app="$("$source_dir/build.sh")"
signing_info="$(/usr/bin/codesign -dv --verbose=4 "$app" 2>&1)"
if [[ $signing_info != *"Authority=Developer ID Application:"* ]]; then
    printf 'A Developer ID Application signature is required for distribution.\n' >&2
    exit 1
fi

staging="$(mktemp -d -t rv100-release)"
trap '/usr/bin/find "$staging" -depth -delete' EXIT
artifact="RV100-Brightness-$version-macos-arm64.dmg"
mkdir "$staging/volume"

# Staple the application before putting it on the disk image.
/usr/bin/ditto -c -k --keepParent "$app" "$staging/app.zip"
/usr/bin/xcrun notarytool submit "$staging/app.zip" --keychain-profile "$MACOS_NOTARY_PROFILE" --wait
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"
/usr/sbin/spctl --assess --type execute --verbose "$app"

/usr/bin/ditto "$app" "$staging/volume/RV100 Brightness.app"
ln -s /Applications "$staging/volume/Applications"
cp "$source_dir/LICENSE" "$staging/volume/LICENSE.txt"
/usr/bin/hdiutil create -volname "RV100 Brightness" -srcfolder "$staging/volume" -format UDZO "$staging/$artifact"
/usr/bin/codesign --force --timestamp --sign "$MACOS_SIGN_IDENTITY" "$staging/$artifact"
/usr/bin/xcrun notarytool submit "$staging/$artifact" --keychain-profile "$MACOS_NOTARY_PROFILE" --wait
/usr/bin/xcrun stapler staple "$staging/$artifact"
/usr/bin/xcrun stapler validate "$staging/$artifact"
/usr/bin/hdiutil verify "$staging/$artifact"
(
    cd "$staging"
    /usr/bin/shasum -a 256 "$artifact" > SHA256SUMS.txt
)

mkdir -p "$source_dir/dist"
mv "$staging/$artifact" "$staging/SHA256SUMS.txt" "$source_dir/dist/"
printf 'Verified release: %s/dist/%s\n' "$source_dir" "$artifact"
