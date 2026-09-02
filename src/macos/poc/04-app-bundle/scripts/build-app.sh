#!/bin/bash
# SwiftPM のみ (Xcode 不要) で .app バンドルを組み立てる PoC スクリプト。
#
# 使う外部ツール: swift / swiftc / plutil / iconutil / codesign / spctl
#   いずれも Command Line Tools に含まれる。xcodebuild / actool / ibtool は使わない。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP_NAME="AmbientPoc"
EXEC_NAME="AmbientPocApp"
BUNDLE_ID="io.github.nassie256.ambient-context-mcp.poc"
VERSION="0.0.1"
BUILD_NUMBER="1"
CONFIG="release"

# --- 1. ビルド -------------------------------------------------------------
# 重要 (CLT のみの環境での検証結果):
#   swift build --arch arm64 --arch x86_64 は XCBuild を要求し、Xcode 無しでは
#     error: xcbuild executable at '/Library/Developer/SharedFrameworks/XCBuild.framework/...'
#     does not exist or is not executable
#   で失敗する。代わりに --triple で 2 回ビルドして lipo で結合すれば CLT だけで
#   Universal バイナリを作れる (検証済み)。
UNIVERSAL="${UNIVERSAL:-0}"
swift build -c "$CONFIG"
ARM_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BUILD_DIR="$ARM_DIR"
if [ "$UNIVERSAL" = "1" ]; then
  swift build -c "$CONFIG" --triple x86_64-apple-macosx14.0
  X86_DIR="$(swift build -c "$CONFIG" --triple x86_64-apple-macosx14.0 --show-bin-path)"
fi
echo "build dir: $BUILD_DIR"

# --- 2. .app 骨格 ----------------------------------------------------------
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "$UNIVERSAL" = "1" ]; then
  lipo -create -output "$APP/Contents/MacOS/$EXEC_NAME" "$ARM_DIR/$EXEC_NAME" "$X86_DIR/$EXEC_NAME"
  lipo -info "$APP/Contents/MacOS/$EXEC_NAME"
else
  cp "$BUILD_DIR/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
fi

# SwiftPM のリソースバンドルは実行ファイルの隣に出る。Bundle.module は
# Bundle.main.resourceURL (= Contents/Resources) も探すので、そこにコピーする。
cp -R "$BUILD_DIR/${EXEC_NAME}_${EXEC_NAME}.bundle" "$APP/Contents/Resources/"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- 3. Info.plist ---------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>Ambient Context MCP (PoC)</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>Copyright (c) 2026 nassie256. MIT License.</string>
  <key>NSAppleEventsUsageDescription</key><string>Ambient Context MCP reads the now-playing track from Music and Spotify when you enable media context.</string>
  <key>NSAccessibilityUsageDescription</key><string>Ambient Context MCP reads the frontmost window title when you enable window-title context.</string>
  <key>CFBundleLocalizations</key>
  <array><string>en</string><string>ja</string></array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

# --- 4. アイコン (actool 不要: コード描画 PNG -> iconutil) -----------------
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
swiftc -O -o "$DIST/make-icon" "$ROOT/scripts/make-icon.swift"
"$DIST/make-icon" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$DIST/make-icon"

# --- 5. 署名 ---------------------------------------------------------------
# Developer ID が無いため ad-hoc (-s -)。--options runtime (Hardened Runtime) は
# ad-hoc でも付与できるが、公証しない配布では利点が無く、DYLD 系の制約だけが増える。
# HARDENED=1 で切り替えて比較できるようにしてある。
HARDENED="${HARDENED:-0}"
SIGN_OPTS=(--force --deep --sign -)
if [ "$HARDENED" = "1" ]; then
  SIGN_OPTS+=(--options runtime)
fi
codesign "${SIGN_OPTS[@]}" "$APP"

echo "--- codesign -dv --verbose=2 ---"
codesign -dv --verbose=2 "$APP" 2>&1 || true
echo "--- codesign --verify --strict ---"
codesign --verify --strict --verbose=2 "$APP" 2>&1 || true
echo "--- spctl -a -t exec -vv (未公証なので reject される想定) ---"
spctl -a -t exec -vv "$APP" 2>&1 || true

echo "done: $APP"
