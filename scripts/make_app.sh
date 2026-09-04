#!/bin/bash
# 将 SwiftPM 可执行文件打包为标准 macOS .app（菜单栏应用）
set -euo pipefail

EXECUTABLE_NAME="MenuBarBrowser"
APP_NAME="TabNest"
DISPLAY_NAME="TabNest — Menu Bar Browser"
BUNDLE_ID="com.menubar.browser"
CONFIG="${1:-release}"
VERSION="${TABNEST_VERSION:-1.0.3}"
BUILD_NUMBER="${TABNEST_BUILD_NUMBER:-1}"
APP_DIR="dist/${APP_NAME}.app"
ICON_SOURCE="Resources/AppIcon.png"
ICONSET_DIR=".build/AppIcon.iconset"
ICON_FILE=".build/AppIcon.icns"

# AppIcon.png 必须是满幅方形图稿。macOS 会在 Finder、Dock、启动台等位置
# 统一应用系统圆角遮罩；源图若自带透明圆角，会形成双层圆角和额外留白。

BUILD_ARGS=(-c "${CONFIG}")
if [[ "${TABNEST_UNIVERSAL:-0}" == "1" ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

echo "==> swift build ${BUILD_ARGS[*]}"
swift build "${BUILD_ARGS[@]}"
BUILD_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
RESOURCE_BUNDLE="${BUILD_DIR}/${EXECUTABLE_NAME}_${EXECUTABLE_NAME}.bundle"

echo "==> 生成应用图标"
rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"

while read -r filename size; do
    sips -z "${size}" "${size}" "${ICON_SOURCE}" --out "${ICONSET_DIR}/${filename}" >/dev/null
done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES

iconutil -c icns "${ICONSET_DIR}" -o "${ICON_FILE}"

echo "==> 组装 ${APP_DIR}"
rm -rf dist
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/${EXECUTABLE_NAME}" "${APP_DIR}/Contents/MacOS/${EXECUTABLE_NAME}"
cp "${ICON_FILE}" "${APP_DIR}/Contents/Resources/AppIcon.icns"
if [[ -d "${RESOURCE_BUNDLE}" ]]; then
    ditto "${RESOURCE_BUNDLE}" \
        "${APP_DIR}/Contents/Resources/${EXECUTABLE_NAME}_${EXECUTABLE_NAME}.bundle"
fi
for localization in en zh-Hans; do
    source_dir="Sources/${EXECUTABLE_NAME}/Resources/${localization}.lproj"
    if [[ -d "${source_dir}" ]]; then
        mkdir -p "${APP_DIR}/Contents/Resources/${localization}.lproj"
        cp "${source_dir}/InfoPlist.strings" \
            "${APP_DIR}/Contents/Resources/${localization}.lproj/InfoPlist.strings"
    fi
done

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>zh-Hans</string></array>
    <key>CFBundleExecutable</key><string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Allow websites you approve to use the microphone for recording, voice input, or calls.</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

cat > "${APP_DIR}/Contents/PkgInfo" <<PKG
APPL????
PKG

echo "==> Ad-hoc 签名"
codesign --force --sign - "${APP_DIR}"

echo ""
echo "✅ 完成: ${APP_DIR}"
echo "   版本: ${VERSION} (${BUILD_NUMBER})"
echo "   运行: open ${APP_DIR}"
echo "   安装: cp -R ${APP_DIR} /Applications/"
