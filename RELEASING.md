# Releasing Code CLI Bar

Code CLI Bar uses an annotated Git tag as the release boundary. Pushing the
tag runs `.github/workflows/release.yml`, which tests the tagged source,
packages the app, preserves the artifacts in GitHub Actions, and creates a
**draft** GitHub Release for a maintainer to inspect before publishing.

The pipeline works without repository secrets. That baseline produces an
ad-hoc-signed ZIP and a SHA-256 checksum. Apple Developer ID, notarization,
and Sparkle signing are optional capabilities that become active when their
secrets and public configuration are added.

## Prepare a version

1. Update both values in `Resources/Info.plist` on a release branch:
   - `CFBundleShortVersionString` — the user-facing SemVer version.
   - `CFBundleVersion` — a monotonically increasing integer.
2. Merge the version change to `main` through a pull request.
3. Run `swift test` and `./Scripts/build_app.sh release`.
4. Create an annotated tag on the exact `main` commit being released.

The standalone repository inherited tags through `v1.4.1`. Its first new
stable version must therefore be newer than `v1.4.1`; do not reuse an
inherited tag because it points to the old product history.

For a stable release:

```sh
git tag -a v1.5.0 -m "Code CLI Bar 1.5.0"
git push origin v1.5.0
```

The stable tag must be exactly `v` plus `CFBundleShortVersionString`.

For a development preview, append the build number:

```sh
git tag -a v1.5.0-dev.51 -m "Code CLI Bar 1.5.0 Dev build 51"
git push origin v1.5.0-dev.51
```

The workflow rejects lightweight tags, mismatched versions, failed tests,
invalid signatures, missing resources, and sandboxed entitlements. A manual
rerun is available under Actions → Release and requires an existing annotated
tag; it does not invent or move tags.

## What CI produces

Every successful run uploads an Actions artifact and creates or refreshes a
draft GitHub Release containing at least:

```text
Code-CLI-Bar-1.5.0-macOS-arm64.zip
Code-CLI-Bar-1.5.0-macOS-arm64.zip.sha256
```

The architecture label is derived from the packaged executable. Review the
draft's generated notes, download and open the ZIP on a clean Mac if possible,
verify its checksum, and then select **Publish release** in GitHub.

Without Apple signing, Gatekeeper will require users to right-click the app,
choose **Open**, and confirm once. Do not describe an ad-hoc build as notarized.

## Run the packager locally

The reusable local command is:

```sh
./Scripts/release_app.sh --channel main --skip-appcast v1.5.0
```

It reads the version from `Resources/Info.plist`, runs the full test suite,
builds `.build/Code CLI Bar.app`, verifies the bundle, and writes release
assets under `.build/release/`.

## Enable Developer ID signing and notarization

Add all five Actions secrets together:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64-encoded Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Password used to export the `.p12` |
| `APPLE_ID` | Apple Developer account email |
| `APPLE_TEAM_ID` | Apple Developer team ID |
| `APPLE_APP_PASSWORD` | App-specific password for `notarytool` |

When the certificate is present, CI refuses a half-configured release. It
imports the identity into a temporary keychain, signs with hardened runtime,
submits the ZIP to Apple, staples the ticket, and runs Gatekeeper assessment.
Secrets, certificates, Apple IDs, and notarization profiles must never be
committed to the repository or printed in logs.

For a local notarized build, import the certificate into the login Keychain
and use a stored notary profile:

```sh
CODE_CLI_BAR_CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
CODE_CLI_BAR_NOTARY_KEYCHAIN_PROFILE="code-cli-bar-release" \
./Scripts/release_app.sh --channel main --skip-appcast v1.5.0
```

## Optional Sparkle update feed

Downloadable GitHub Releases do not require Sparkle. Enable in-app updates only
after all three pieces exist:

1. `SUPublicEDKey` in `Resources/Info.plist`.
2. `SUFeedURL` in `Resources/Info.plist`, pointing at this repository's
   `updates/appcast.xml`.
3. The matching private key in the Actions secret
   `SPARKLE_ED_PRIVATE_KEY`.

With those configured, `release_app.sh` adds a signed `appcast.xml` to the
draft. Publishing the GitHub Release then runs
`.github/workflows/publish-update-feed.yml`, which reconstructs the newest
stable and development channel heads and writes the shared feed to the
machine-managed `updates` branch.

If the Sparkle secret is absent, feed publication exits successfully with a
notice. It never turns a normal GitHub Release into a failed deployment.
