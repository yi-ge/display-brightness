# Signing and releasing

The standard `./build.sh` command compiles and ad-hoc signs the app for local use. To sign a distribution build, set `MACOS_SIGN_IDENTITY` to a **Developer ID Application** identity with its private key in the local Keychain.

## Prepare a release

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in [Info.plist](Info.plist). Add the version to [CHANGELOG.md](CHANGELOG.md).
2. Check the available signing identities with `security find-identity -v -p codesigning`. Store Apple notarization credentials in a Keychain profile with `xcrun notarytool store-credentials`. Apple documents [distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/) and [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
3. Run the release script from the source revision you are publishing.

```sh
export MACOS_SIGN_IDENTITY='Developer ID Application: Example Name (TEAMID)'
export MACOS_NOTARY_PROFILE='rv100-brightness-notary'
./release.sh
```

The script signs with Hardened Runtime and a secure timestamp, notarizes and staples the app and DMG, then writes the verified DMG and its SHA-256 checksum to `dist/`. Signing or notarization errors stop packaging.

Check that the DMG opens and that the extracted app launches. Attach the DMG and `SHA256SUMS.txt` to the matching GitHub Release. A source release can be published with the GitHub-generated source archives while distribution signing is pending.
