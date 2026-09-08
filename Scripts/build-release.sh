#!/bin/bash
#
# build-release.sh
# ZeroShot
#
# Regenerates the Xcode project, builds a Release archive-quality binary, and
# installs it to /Applications, replacing any previous copy. Run this any
# time you want to update the installed app after making changes.
#
# Signing note: project.yml pins CODE_SIGN_IDENTITY to "Apple Development"
# and DEVELOPMENT_TEAM to G6U69FC9H3, so every build (Debug or Release) gets
# the same stable signing identity. That is what keeps macOS from re-asking
# for Screen Recording permission after each rebuild.
#

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ZeroShot"
DERIVED_DATA_PATH="build/Release"
INSTALL_PATH="/Applications/${APP_NAME}.app"

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

echo "==> Quitting any running ${APP_NAME} instance"
pkill -x "${APP_NAME}" 2>/dev/null || true

echo "==> Installing to ${INSTALL_PATH}"
rm -rf "${INSTALL_PATH}"
cp -R "${BUILT_APP}" "${INSTALL_PATH}"

echo "==> Installed: ${INSTALL_PATH}"
