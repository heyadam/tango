# Releasing Tango

A release is a signed, notarized `Tango-<version>.dmg` on a GitHub release. People download it, open it, and drag Tango into Applications; Gatekeeper opens it with no warning.

```bash
git tag v0.2 && git push origin v0.2     # CI builds it and makes a draft release
```

Review the draft on GitHub (notes are generated from the commits), then Publish. The Actions tab can also run **Release** by hand with a version, for a build from any branch.

`scripts/release.sh <version>` is what CI runs, and runs the same on this Mac. It archives a Release build, exports it signed with Developer ID (hardened runtime, with the camera, microphone and location entitlements in `App/Tango.entitlements`), puts it in a DMG with an Applications link, signs the DMG, notarizes it, staples the ticket, and checks it with Gatekeeper. The output is in `build/release/`. The version is what you pass; the build number is the commit count, so each release is higher than the last.

## One-time setup

You need a paid Apple Developer Program membership (the Account Holder or an Admin role, to make a Developer ID certificate).

### 1. The Developer ID certificate

Xcode > Settings > Accounts > your team > Manage Certificates… > **+** > **Developer ID Application**. It lands in your login keychain. Check:

```bash
security find-identity -v -p codesigning
```

There should be a line `Developer ID Application: <Name> (<TEAMID>)`. Apple allows only a few of these per team, and they last five years: make one, and keep it.

Export it for CI: Keychain Access > My Certificates > the Developer ID Application certificate (with its private key under it) > right-click > Export… > `.p12`, with a strong password. Keep the `.p12` somewhere safe (a password manager) — it is the identity that every copy of Tango is signed with.

### 2. Notarization credentials

For this Mac, store an app-specific password once (make one at account.apple.com > Sign-In and Security > App-Specific Passwords):

```bash
xcrun notarytool store-credentials tango --apple-id <your Apple ID> --team-id <TEAMID>
```

For CI, use an App Store Connect API key, which needs no password or two-factor: App Store Connect > Users and Access > Integrations > App Store Connect API > Team Keys > **+**, role **Developer**. Download the `.p8` (it can be downloaded only once) and note its Key ID and the Issuer ID above the list.

### 3. GitHub secrets

Settings > Secrets and variables > Actions > New repository secret, or with `gh`:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERT_P12` | `base64 -i DeveloperID.p12 \| gh secret set DEVELOPER_ID_CERT_P12` |
| `DEVELOPER_ID_CERT_PASSWORD` | the `.p12`'s password |
| `TEAM_ID` | the 10 characters in the certificate's name |
| `NOTARY_KEY_P8` | `gh secret set NOTARY_KEY_P8 < AuthKey_XXXXXXXXXX.p8` |
| `NOTARY_KEY_ID` | the API key's Key ID |
| `NOTARY_ISSUER` | the Issuer ID |

CI imports the certificate into a keychain of its own for the run and deletes it afterwards.

## Releasing from this Mac

```bash
NOTARY_PROFILE=tango scripts/release.sh 0.2
gh release create v0.2 build/release/Tango-0.2.dmg build/release/Tango-0.2.dmg.sha256 --generate-notes --draft
```

`SKIP_NOTARIZE=1` stops after signing (to check the signing quickly). `UNSIGNED=1` needs no Apple account at all: an ad hoc build in a DMG, which other Macs will refuse to open without right-click > Open.

## When it goes wrong

- **Notarization: Invalid.** The script prints Apple's log. Usually a binary in the bundle that is not signed with the hardened runtime and a timestamp. Everything in the app today is built by Xcode, so it is signed; anything added that ships its own binary must be signed too.
- **"No Developer ID Application certificate in the keychain."** The certificate is missing, or only its public half is there (the private key must be under it in Keychain Access).
- **CI: "No Xcode 27 on this runner."** The runner image has not got the Xcode the project needs. Change `runs-on`, or run the script on this Mac.
- **The camera, microphone or location never asks.** The hardened runtime blocks them without the entitlement; the script checks that the entitlements survived signing.

## Not yet

- Updates inside the app (Sparkle, with an appcast on the releases). Until then people download each new DMG.
- An app icon and a DMG window background.
- The bundle id is `com.tango.app`; change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to one you own before the first public release, since macOS ties a person's settings and keychain items to it.
