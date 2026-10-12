# Releasing Tweaks

Tweaks is distributed directly as a signed and notarized Apple Silicon ZIP
attached to a GitHub Release. Homebrew is intentionally deferred until the app
has a stable release cadence.

## Prerequisites

- Apple Developer Program membership.
- A **Developer ID Application** certificate and private key in the local
  keychain or in the release workflow's imported keychain.
- An App Store Connect API key authorized to submit notarization requests, or a
  local `notarytool` keychain profile.
- Xcode and XcodeGen.

If the checkout does not have a Developer ID Application identity, the release
script stops before archiving and explains what is missing.

## Local release

Use a keychain profile created for `notarytool`:

```sh
TEAM_ID="YOUR_TEAM_ID" \
NOTARY_PROFILE="Tweaks-notary" \
./scripts/release-macos.sh
```

Or provide an App Store Connect API key directly:

```sh
TEAM_ID="YOUR_TEAM_ID" \
NOTARY_KEY_ID="YOUR_KEY_ID" \
NOTARY_ISSUER_ID="YOUR_ISSUER_ID" \
NOTARY_PRIVATE_KEY_PATH="/path/to/AuthKey_KEYID.p8" \
./scripts/release-macos.sh
```

The script generates a Release archive, exports Developer ID-signed
`Tweaks.app`, submits a ZIP to Apple's notary service, staples the ticket,
and writes:

```text
.release/Tweaks-0.1.0-arm64.zip
.release/Tweaks-0.1.0-arm64.zip.sha256
```

## GitHub release

The release workflow runs when a `v*` tag is pushed. It expects these GitHub
Actions secrets:

- `APPLE_TEAM_ID`
- `DEVELOPER_ID_CERTIFICATE_P12` (base64-encoded certificate and private key)
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `NOTARY_KEY_ID`
- `NOTARY_ISSUER_ID`
- `NOTARY_PRIVATE_KEY` (base64-encoded `.p8` key)

After the secrets are configured:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The workflow verifies that the tag matches `MARKETING_VERSION`, builds and
notarizes the arm64 app, calculates a SHA-256 checksum, and creates the GitHub
Release with both files attached.

Do not commit certificates, private keys, provisioning assets, or notarization
credentials.
