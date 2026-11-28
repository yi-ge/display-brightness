#!/bin/bash
set -euo pipefail

: "${MACOS_SIGN_IDENTITY:?Set MACOS_SIGN_IDENTITY to a Developer ID Application identity}"
: "${SPARKLE_ED_KEY_FILE:?Set SPARKLE_ED_KEY_FILE to the Sparkle EdDSA signing key file}"
test -s "$SPARKLE_ED_KEY_FILE"
export MACOS_SIGN_IDENTITY

if [[ -n ${MACOS_NOTARY_KEY_PATH:-} ]]; then
    : "${MACOS_NOTARY_KEY_ID:?Set MACOS_NOTARY_KEY_ID for the team API key}"
    : "${MACOS_NOTARY_ISSUER_ID:?Set MACOS_NOTARY_ISSUER_ID for the team API key}"
    notary_args=(--key "$MACOS_NOTARY_KEY_PATH" --key-id "$MACOS_NOTARY_KEY_ID" --issuer "$MACOS_NOTARY_ISSUER_ID")
else
    : "${MACOS_NOTARY_PROFILE:?Set MACOS_NOTARY_PROFILE to a notarytool Keychain profile}"
    notary_args=(--keychain-profile "$MACOS_NOTARY_PROFILE")
fi

source_dir="$(cd "$(dirname "$0")" && pwd)"
info="$source_dir/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
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

bundle_name="${app##*/}"
display_name="${bundle_name%.app}"
staging="$(mktemp -d -t display-brightness-release)"
trap '/usr/bin/find "$staging" -depth -delete' EXIT
artifact="${display_name// /-}-$version-macos-arm64.dmg"
image="$staging/$artifact"
mkdir "$staging/volume"

/usr/bin/ditto "$app" "$staging/volume/$bundle_name"
ln -s /Applications "$staging/volume/Applications"
cp "$source_dir/LICENSE" "$staging/volume/LICENSE.txt"
/usr/bin/hdiutil create -volname "$display_name" -srcfolder "$staging/volume" -format UDZO "$image"
/usr/bin/codesign --timestamp --identifier "$bundle_id.disk-image" --sign "$MACOS_SIGN_IDENTITY" "$image"

# The disk image is the distribution container. Apple also scans the nested app.
/usr/bin/xcrun notarytool submit "$image" "${notary_args[@]}" --wait --timeout 20m --output-format json \
    | tee "$staging/notarization.json"
if [[ "$(/usr/bin/plutil -extract status raw "$staging/notarization.json")" != Accepted ]]; then
    printf 'Apple did not accept the disk image for notarization.\n' >&2
    exit 1
fi

/usr/bin/xcrun stapler staple "$image"
/usr/bin/xcrun stapler validate "$image"
/usr/bin/codesign --verify --strict "$image"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose "$image"
/usr/sbin/spctl --assess --type execute --verbose "$app"
/usr/bin/hdiutil verify "$image"

# Generate the feed after stapling so the signature covers exactly the uploaded DMG.
sparkle="$("$source_dir/scripts/sparkle.sh")"
release_url="https://github.com/yi-ge/display-brightness/releases/tag/v$version"
/usr/bin/awk -v heading="## $version " '
    index($0, heading) == 1 { notes = 1; next }
    notes && /^## / { exit }
    notes { print }
' "$source_dir/CHANGELOG.md" > "$staging/${artifact%.dmg}.md"
"$sparkle/bin/generate_appcast" --ed-key-file "$SPARKLE_ED_KEY_FILE" \
    --download-url-prefix "https://github.com/yi-ge/display-brightness/releases/download/v$version/" \
    --link "$release_url" --embed-release-notes --maximum-deltas 0 "$staging"
"$sparkle/bin/sign_update" --ed-key-file "$SPARKLE_ED_KEY_FILE" --verify "$staging/appcast.xml"
signature="$(/usr/bin/xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$staging/appcast.xml")"
test -n "$signature"
"$sparkle/bin/sign_update" --ed-key-file "$SPARKLE_ED_KEY_FILE" --verify "$image" "$signature"

(
    cd "$staging"
    /usr/bin/shasum -a 256 "$artifact" > SHA256SUMS.txt
)

mkdir -p "$source_dir/dist"
mv "$staging/$artifact" "$staging/SHA256SUMS.txt" "$staging/appcast.xml" "$source_dir/dist/"
printf 'Verified release: %s/dist/%s\n' "$source_dir" "$artifact"
