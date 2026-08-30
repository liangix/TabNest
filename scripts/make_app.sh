#!/bin/bash
# 将 SwiftPM 可执行文件打包为标准 macOS .app（菜单栏应用）
set -euo pipefail

EXECUTABLE_NAME="MenuBarBrowser"
APP_NAME="TabNest"
DISPLAY_NAME="TabNest — Menu Bar Browser"
BUNDLE_ID="com.menubar.browser"
CONFIG="${1:-release}"
BUILD_DIR=".build/${CONFIG}"
APP_DIR="dist/${APP_NAME}.app"
ICON_SOURCE="Resources/AppIcon.png"
ICONSET_DIR=".build/AppIcon.iconset"
ICON_FILE=".build/AppIcon.icns"

# AppIcon.png 必须是满幅方形图稿。macOS 会在 Finder、Dock、启动台等位置
# 统一应用系统圆角遮罩；源图若自带透明圆角，会形成双层圆角和额外留白。

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

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

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
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
echo "   运行: open ${APP_DIR}"
echo "   安装: cp -R ${APP_DIR} /Applications/"
