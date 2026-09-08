#!/bin/bash
#
# build-dmg.sh
# ZeroShot
#
# Builds a Release copy of ZeroShot and packages it into a .dmg for moving to
# another Mac: double-click the dmg, drag ZeroShot into Applications.
#
# Signing note: this is signed with the "Apple Development" identity from
# project.yml, not a Developer ID. That is fine for the Mac it was built on,
# but a Mac that has never trusted this developer certificate will refuse to
# open it with "cannot be opened because the developer cannot be verified".
# On the other Mac: right-click ZeroShot.app in Applications, choose Open,
# then confirm in the dialog. After that first approval it opens normally.
#

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ZeroShot"
DERIVED_DATA_PATH="build/Release"
DMG_STAGING="build/dmg-staging"
DMG_PATH="build/${APP_NAME}.dmg"

echo "==> Generating Xcode project (xcodegen generate)"
xcodegen generate

echo "==> Building Release configuration"
xcodebuild -project "${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  build

BUILT_APP="${DERIVED_DATA_PATH}/Build/Products/Release/${APP_NAME}.app"

if [ ! -d "${BUILT_APP}" ]; then
  echo "error: build did not produce ${BUILT_APP}" >&2
  exit 1
fi

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

echo "==> Done: $(pwd)/${DMG_PATH}"
echo "==> On the other Mac: open the dmg, drag ${APP_NAME} into Applications,"
echo "    then right-click ${APP_NAME} and choose Open the first time (unsigned"
echo "    for distribution, so Gatekeeper needs one manual approval)."
