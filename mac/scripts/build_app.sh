#!/bin/bash
# 拼出「StackChan Butler.app」，可选再做成 .dmg、签名、公证。
#
#   scripts/build_app.sh                 # 编译 + 拼 .app（本机自用：临时签名）
#   SIGN_ID="Developer ID Application: 名字 (TEAMID)" scripts/build_app.sh dmg
#   SIGN_ID=… NOTARY_PROFILE=小管家公证 scripts/build_app.sh dmg   # 再提交公证
#
# 需要：Xcode、固件已编译（firmware 目录 pio run）、build/vendor 里有 esptool（见下面的 fetch_esptool）。
set -euo pipefail
cd "$(dirname "$0")/.."
MAC_DIR=$(pwd)
ROOT=$(cd .. && pwd)
APP_NAME="StackChan Butler"
APP="build/$APP_NAME.app"
APP_VERSION="2.0.0"
BUNDLE_ID="com.aihelper.StackChanButler"
SIGN_ID="${SIGN_ID:--}"
FW_BUILD="$ROOT/firmware/.pio/build/stackchan"
BOOT_APP0="$HOME/.platformio/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin"
ESPTOOL_VER="v5.6.0"

fetch_esptool() {
  # 乐鑫官方的独立版烧录工具（GPLv2，乐鑫自己签过名），原样放进应用
  for arch in arm64 amd64; do
    d="build/vendor/esptool-$arch"
    if [ ! -x "$d/esptool-macos-$arch/esptool" ]; then
      mkdir -p "$d"
      gh release download "$ESPTOOL_VER" -R espressif/esptool -p "esptool-$ESPTOOL_VER-macos-$arch.tar.gz" -D build/vendor --clobber
      tar -xzf "build/vendor/esptool-$ESPTOOL_VER-macos-$arch.tar.gz" -C "$d"
    fi
  done
}

echo "== 编译 =="
swift build -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

echo "== 拼 .app =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/firmware" "$APP/Contents/Resources/esptool"
cp "$BIN_DIR/Butler" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/preview.html "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] || swift scripts/make_icon.swift Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# 机器人固件
for f in bootloader.bin partitions.bin firmware.bin; do cp "$FW_BUILD/$f" "$APP/Contents/Resources/firmware/"; done
cp "$BOOT_APP0" "$APP/Contents/Resources/firmware/"
grep -o 'FW_VERSION "[^"]*"' "$ROOT/firmware/src/app.h" | cut -d'"' -f2 > "$APP/Contents/Resources/firmware/VERSION"
cp "$ROOT/firmware/fonts/OFL-"*.txt "$APP/Contents/Resources/firmware/"

# 烧录工具
fetch_esptool
cp "build/vendor/esptool-arm64/esptool-macos-arm64/esptool" "$APP/Contents/Resources/esptool/esptool-arm64"
cp "build/vendor/esptool-amd64/esptool-macos-amd64/esptool" "$APP/Contents/Resources/esptool/esptool-x86_64"
cp "build/vendor/esptool-arm64/esptool-macos-arm64/LICENSE" "$APP/Contents/Resources/esptool/LICENSE"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"

# 三种语言的应用名
for l in zh-Hans ja en; do mkdir -p "$APP/Contents/Resources/$l.lproj"; done
printf 'CFBundleDisplayName = "小管家";\nCFBundleName = "小管家";\n' > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
printf 'CFBundleDisplayName = "StackChan Butler";\nCFBundleName = "StackChan Butler";\n' > "$APP/Contents/Resources/ja.lproj/InfoPlist.strings"
printf 'CFBundleDisplayName = "StackChan Butler";\nCFBundleName = "StackChan Butler";\n' > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>ja</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>NSLocalNetworkUsageDescription</key><string>小管家要在局域网里让 StackChan 找到这台 Mac，并把额度和提醒发给它。 / Lets your StackChan find this Mac on the local network.</string>
  <key>NSBonjourServices</key><array><string>_aihelper._tcp</string></array>
</dict>
</plist>
PLIST

echo "== 签名（$SIGN_ID）=="
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --sign - "$APP/Contents/MacOS/$APP_NAME"
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/$APP_NAME"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "签名检查通过"

if [ "${1:-}" = "dmg" ]; then
  echo "== 做 dmg =="
  DMG="build/StackChan-Butler-$APP_VERSION.dmg"
  STAGE=build/dmg
  rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME $APP_VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  [ "$SIGN_ID" != "-" ] && codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "== 公证（几分钟）=="
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
  echo "做好了：$DMG"
fi
echo "做好了：$APP"
