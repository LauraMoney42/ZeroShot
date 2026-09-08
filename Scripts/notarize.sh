#!/bin/bash
#
# notarize.sh
# ZeroShot
#
# Builds a Release copy of ZeroShot, signs it by hand with the Developer ID
# certificate, submits it to Apple's notary service, staples the result, and
# packages it into a dmg that opens with zero Gatekeeper warnings on any Mac.
#
# One-time setup this script assumes is already done:
#   - A "Developer ID Application" certificate is in this Mac's keychain
#     (developer.apple.com > Certificates > Developer ID Application).
#   - Notarization credentials are stored under the keychain profile named
#     below. Create them once with:
#       xcrun notarytool store-credentials "zeroshot-notary" \
#         --apple-id YOUR_APPLE_ID --team-id G6U69FC9H3 --password AN_APP_SPECIFIC_PASSWORD
#     (app-specific password from appleid.apple.com > Sign-In and Security)
#
# Why the app is signed here instead of by Xcode: project.yml turns off
# Xcode's own code signing for Release (CODE_SIGNING_ALLOWED: NO). Xcode's
# "Manual" signing style injects the com.apple.security.get-task-allow
# entitlement whenever there is no provisioning profile, and Developer ID
# builds never have one -- that entitlement is exactly what the notary
# service rejects as "not for distribution". Signing here, after the build,
# with an explicit empty entitlements file avoids it entirely.
#

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ZeroShot"
SIGNING_IDENTITY="Developer ID Application: KindCode LLC (G6U69FC9H3)"
NOTARY_PROFILE="zeroshot-notary"
ENTITLEMENTS="Resources/ZeroShotRelease.entitlements"
DERIVED_DATA_PATH="build/Release"
BUILT_APP="${DERIVED_DATA_PATH}/Build/Products/Release/${APP_NAME}.app"
ZIP_PATH="build/${APP_NAME}-notarize.zip"
DMG_STAGING="build/dmg-staging"
DMG_PATH="build/${APP_NAME}.dmg"

echo "==> Generating Xcode project (xcodegen generate)"
xcodegen generate

echo "==> Building Release configuration (unsigned; signed below by hand)"
rm -rf "${DERIVED_DATA_PATH}"
xcodebuild -project "${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  build

if [ ! -d "${BUILT_APP}" ]; then
  echo "error: build did not produce ${BUILT_APP}" >&2
  exit 1
fi

echo "==> Signing with Developer ID (hardened runtime, secure timestamp)"
codesign --force --options runtime --timestamp \
  --entitlements "${ENTITLEMENTS}" \
  --sign "${SIGNING_IDENTITY}" \
  "${BUILT_APP}"

echo "==> Verifying signature"
codesign --verify --strict --deep --verbose=2 "${BUILT_APP}"
if codesign -d --entitlements - "${BUILT_APP}" 2>/dev/null | grep -q get-task-allow; then
  echo "error: get-task-allow is still present; notarization would be rejected" >&2
  exit 1
fi

echo "==> Verifying with spctl (accepted here just means the signature is
    valid; Gatekeeper's real check needs a notarization ticket, next)"
spctl --assess --type execute --verbose=2 "${BUILT_APP}" || true

echo "==> Staging dmg contents"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R "${BUILT_APP}" "${DMG_STAGING}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGING}/Applications"

echo "==> Creating ${DMG_PATH}"
rm -f "${DMG_PATH}"
hdiutil create -volname "${APP_NAME}" \
  -srcfolder "${DMG_STAGING}" \
  -ov -format UDZO \
  "${DMG_PATH}"
rm -rf "${DMG_STAGING}"

# A plain hdiutil dmg has no signature of its own (the app inside is signed,
# the dmg container is not); Gatekeeper rejects an unsigned dmg outright, so
# it needs its own Developer ID signature before it goes to the notary
# service.
echo "==> Signing the dmg itself"
codesign --force --timestamp --sign "${SIGNING_IDENTITY}" "${DMG_PATH}"

# Notarizing the dmg itself (rather than a zip of the app) is what lets the
# stapler attach the ticket to the dmg too, so Gatekeeper can verify it with
# no network call the moment it's downloaded, before the user even opens it.
echo "==> Submitting the dmg to Apple's notary service (this can take a few minutes)"
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait

echo "==> Stapling the notarization ticket to the dmg"
xcrun stapler staple "${DMG_PATH}"

echo "==> Verifying the stapled dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}"

rm -f "${ZIP_PATH}"

echo "==> Done: $(pwd)/${DMG_PATH}"
echo "==> Notarized and stapled. Opens on any Mac with no Gatekeeper warning."
