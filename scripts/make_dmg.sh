#!/bin/bash
# 构建通用架构 TabNest.app，并封装为可拖入 Applications 的压缩 DMG。
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="TabNest"
VERSION="${TABNEST_VERSION:-1.0.0}"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="dist/${DMG_NAME}"
CHECKSUM_PATH="${DMG_PATH}.sha256"
STAGING_ROOT=".build/dmg/${APP_NAME}-${VERSION}"

TABNEST_VERSION="${VERSION}" \
TABNEST_BUILD_NUMBER="${TABNEST_BUILD_NUMBER:-1}" \
TABNEST_UNIVERSAL="${TABNEST_UNIVERSAL:-1}" \
    ./scripts/make_app.sh "${CONFIG}"

rm -rf ".build/dmg"
mkdir -p "${STAGING_ROOT}"
ditto "dist/${APP_NAME}.app" "${STAGING_ROOT}/${APP_NAME}.app"
ln -s /Applications "${STAGING_ROOT}/Applications"

codesign --verify --deep --strict "${STAGING_ROOT}/${APP_NAME}.app"
hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "${STAGING_ROOT}" \
    -format UDZO \
    -ov \
    "${DMG_PATH}"
hdiutil verify "${DMG_PATH}"

(cd dist && shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256")

echo ""
echo "✅ DMG 完成: ${DMG_PATH}"
echo "   校验文件: ${CHECKSUM_PATH}"
