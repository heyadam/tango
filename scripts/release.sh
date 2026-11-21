#!/bin/bash
# Build, sign, notarize and package Tango as a DMG.
#
#   scripts/release.sh 0.2            # build/release/Tango-0.2.dmg, signed, notarized and stapled
#   SKIP_NOTARIZE=1 scripts/release.sh 0.2   # signed only (quick check of the signing)
#   UNSIGNED=1 scripts/release.sh 0.2        # ad hoc, no Apple account needed (the DMG warns on other Macs)
#
# Signing: a "Developer ID Application" certificate in the keychain. Set TEAM_ID, or it is read
# from that certificate.
#
# Notarizing, one of:
#   NOTARY_PROFILE=tango        a profile made once with `xcrun notarytool store-credentials tango`
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER   an App Store Connect API key (what CI uses)
#
# The build number is the commit count, so every release is higher than the last.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>, e.g. 0.2}"
VERSION="${VERSION#v}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}"
ARCHIVE="$OUT/Tango.xcarchive"
APP="$OUT/export/Tango.app"
DMG="$OUT/Tango-$VERSION.dmg"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

rm -rf "$OUT"
mkdir -p "$OUT"
cd "$ROOT"

step "Generating the project"
xcodegen generate --quiet

if [[ -n "${UNSIGNED:-}" ]]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
  SKIP_NOTARIZE=1
else
  if [[ -z "${TEAM_ID:-}" ]]; then
    TEAM_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"Developer ID Application: .*(\([A-Z0-9]\{10\}\))".*/\1/p' | head -1)"
  fi
  if [[ -z "$TEAM_ID" ]]; then
    echo "No Developer ID Application certificate in the keychain. See RELEASING.md." >&2
    exit 1
  fi
  SIGN_ARGS=(
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=Developer ID Application"
    DEVELOPMENT_TEAM="$TEAM_ID"
    "OTHER_CODE_SIGN_FLAGS=--timestamp"
  )
fi

step "Archiving Tango $VERSION ($BUILD_NUMBER)"
xcodebuild archive \
  -project Tango.xcodeproj -scheme Tango -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$OUT/DerivedData" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet "${SIGN_ARGS[@]}"

mkdir -p "$OUT/export"
if [[ -n "${UNSIGNED:-}" ]]; then
  cp -R "$ARCHIVE/Products/Applications/Tango.app" "$APP"
else
  step "Exporting for Developer ID"
  cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
EOF
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export"

  step "Checking the signature"
  codesign --verify --deep --strict --verbose=2 "$APP"
  codesign -d --entitlements - "$APP" 2>/dev/null | grep -q device.camera \
    || { echo "The app lost its entitlements" >&2; exit 1; }
fi

step "Making the DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Tango $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [[ -z "${UNSIGNED:-}" ]]; then
  codesign --sign "Developer ID Application" --timestamp "$DMG"
fi

if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
  step "Notarizing (a few minutes)"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  else
    echo "Set NOTARY_PROFILE or NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER, or SKIP_NOTARIZE=1. See RELEASING.md." >&2
    exit 1
  fi
  if ! xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait --output-format json > "$OUT/notary.json"; then
    cat "$OUT/notary.json" >&2
    exit 1
  fi
  STATUS="$(/usr/bin/plutil -extract status raw "$OUT/notary.json")"
  if [[ "$STATUS" != "Accepted" ]]; then
    ID="$(/usr/bin/plutil -extract id raw "$OUT/notary.json")"
    xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
    echo "Notarization: $STATUS" >&2
    exit 1
  fi
  xcrun stapler staple "$DMG"
  step "Gatekeeper"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "$DMG"
