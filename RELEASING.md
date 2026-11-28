# Signing and releasing

The standard `./build.sh` command compiles and ad-hoc signs the app for local use. To sign a distribution build, set `MACOS_SIGN_IDENTITY` to a **Developer ID Application** identity with its private key in the local Keychain.

## Prepare a release

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in [Info.plist](Info.plist). Add the version to [CHANGELOG.md](CHANGELOG.md).
2. Merge the release commit into `main`. Create a tag that matches the version in the plist, for example `v1.3.2`, and push it.
3. Check the **Release macOS** workflow run. It signs the arm64 app and disk image, notarizes and staples the disk image, then signs the final disk image and update feed with Sparkle. It publishes the DMG, checksum, and `appcast.xml` together. The updater reads `appcast.xml` from the latest stable GitHub Release.

Run **Release macOS** manually from `main` to verify the pipeline. The manual run produces the same assets as a workflow artifact without publishing a Release.

The `macos-release` GitHub environment provides these secrets to the packaging job. Use the team API key from App Store Connect for Apple notarization.

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded PKCS#12 containing the Developer ID Application certificate and private key |
| `DEVELOPER_ID_P12_PASSWORD` | PKCS#12 export password |
| `ASC_KEY_P8_BASE64` | Base64-encoded App Store Connect team private key |
| `ASC_KEY_ID` | Key ID for that team private key |
| `ASC_ISSUER_ID` | Team API key issuer ID |
| `SPARKLE_ED_PRIVATE_KEY` | Exported Sparkle EdDSA key for this app. Its public key must match `SUPublicEDKey` in [Info.plist](Info.plist). |

Keep the Sparkle key in the maintainer's Keychain and an encrypted backup. To export it, use `bin/generate_keys --account local.rv100-brightness -x /path/to/private.key` from the Sparkle distribution. Preserve the key across releases so installed copies of the app can verify updates.

## Package locally

Check the available signing identities with `security find-identity -v -p codesigning`. Store Apple notarization credentials in a Keychain profile with `xcrun notarytool store-credentials`. Apple documents [distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/) and [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

```sh
export MACOS_SIGN_IDENTITY='Developer ID Application: Example Name (TEAMID)'
export MACOS_NOTARY_PROFILE='display-brightness-notary'
export SPARKLE_ED_KEY_FILE='/path/to/private.key'
./release.sh
```

For an App Store Connect team key, set `MACOS_NOTARY_KEY_PATH`, `MACOS_NOTARY_KEY_ID`, and `MACOS_NOTARY_ISSUER_ID` instead of `MACOS_NOTARY_PROFILE`.

The script signs the app with Hardened Runtime and a secure timestamp. It signs the DMG, notarizes the outer disk image, attaches the ticket, and writes the verified DMG, its SHA-256 checksum, and the signed update feed to `dist/`. Signing, notarization, or feed verification errors stop packaging.

Check that the DMG opens and that the extracted app launches. Test the keyboard shortcuts and brightness adjustment on a physical Mac with a compatible display.
