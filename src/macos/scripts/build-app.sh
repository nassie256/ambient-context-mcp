#!/bin/bash
# macOS 版の配布物 (`Ambient Context MCP.app` と `ambient-mcp-stdio`) を組み立てる。
#
# 使う外部ツール: swift / lipo / sips / iconutil / plutil / codesign / spctl
#   すべて Command Line Tools に含まれる。xcodebuild / actool / ibtool は使わない
#   (設計書 §10)。Xcode 入りの GitHub `macos-latest` でも同じ手順で通る。
#
# 使い方:
#   scripts/build-app.sh                          # universal (arm64 + x86_64)
#   scripts/build-app.sh --arch arm64             # 単一アーキ (ローカル確認用、速い)
#   scripts/build-app.sh --version 0.8.0          # 既定は mcpb/manifest.json の version
#   scripts/build-app.sh --out /path/to/dir       # 既定は <repo>/dist/macos
#   HARDENED=1 scripts/build-app.sh               # Hardened Runtime を付与 (既定 OFF)
#
# 出力 (--out ディレクトリ直下):
#   Ambient Context MCP.app
#   ambient-mcp-stdio
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PACKAGE_DIR/../.." && pwd)"

APP_NAME="Ambient Context MCP"
EXEC_NAME="ambient-mcp"           # .app 内の実行ファイル名 (SwiftPM product は AmbientContextMac)
SWIFT_APP_PRODUCT="AmbientContextMac"
BRIDGE_NAME="ambient-mcp-stdio"
BUNDLE_ID="io.github.nassie256.ambient-context-mcp"
DEPLOYMENT_TARGET="14.0"
CONFIG="release"

VERSION=""
ARCH_MODE="universal"
OUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --arch)    ARCH_MODE="${2:?--arch needs a value}"; shift 2 ;;
    --out)     OUT_DIR="${2:?--out needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$ARCH_MODE" in
  arm64|x86_64|universal) ;;
  *) echo "--arch must be one of: arm64 | x86_64 | universal" >&2; exit 2 ;;
esac

# バージョンは mcpb/manifest.json を単一ソースにする (Windows 版と同じ規約)。
# "manifest_version" は '"version"' に一致しないので grep -m1 で安全に取れる。
if [ -z "$VERSION" ]; then
  VERSION="$(grep -m1 '"version"' "$REPO_ROOT/mcpb/manifest.json" \
    | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
fi
if [ -z "$VERSION" ]; then
  echo "could not resolve version (pass --version)" >&2
  exit 1
fi

if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$REPO_ROOT/dist/macos"
fi
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

echo "==> Ambient Context MCP $VERSION ($ARCH_MODE) -> $OUT_DIR"

cd "$PACKAGE_DIR"

# --- 1. ビルド -------------------------------------------------------------
# CLT のみの環境では `swift build --arch arm64 --arch x86_64` が XCBuild を要求して
# 失敗する (PoC 4)。--triple で 2 回ビルドして lipo で結合する方式に統一し、
# ローカルと CI で手順を割らない。
build_triple() {
  local triple="$1"
  echo "--- swift build ($triple)" >&2
  # `--product` は最後の 1 つしか効かないので product ごとに呼ぶ。
  swift build -c "$CONFIG" --triple "$triple" --product "$SWIFT_APP_PRODUCT" >&2
  swift build -c "$CONFIG" --triple "$triple" --product "$BRIDGE_NAME" >&2
  swift build -c "$CONFIG" --triple "$triple" --show-bin-path
}

ARM_BIN=""
X86_BIN=""
case "$ARCH_MODE" in
  arm64)     ARM_BIN="$(build_triple "arm64-apple-macosx$DEPLOYMENT_TARGET")" ;;
  x86_64)    X86_BIN="$(build_triple "x86_64-apple-macosx$DEPLOYMENT_TARGET")" ;;
  universal) ARM_BIN="$(build_triple "arm64-apple-macosx$DEPLOYMENT_TARGET")"
             X86_BIN="$(build_triple "x86_64-apple-macosx$DEPLOYMENT_TARGET")" ;;
esac
PRIMARY_BIN="${ARM_BIN:-$X86_BIN}"
echo "--- bin path: $PRIMARY_BIN"

# $1 = SwiftPM product 名, $2 = 出力先パス
install_binary() {
  local product="$1" dest="$2"
  if [ -n "$ARM_BIN" ] && [ -n "$X86_BIN" ]; then
    lipo -create -output "$dest" "$ARM_BIN/$product" "$X86_BIN/$product"
  else
    cp "$PRIMARY_BIN/$product" "$dest"
  fi
  lipo -info "$dest"
}

# --- 2. .app 骨格 ----------------------------------------------------------
APP="$OUT_DIR/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

install_binary "$SWIFT_APP_PRODUCT" "$APP/Contents/MacOS/$EXEC_NAME"
install_binary "$BRIDGE_NAME" "$OUT_DIR/$BRIDGE_NAME"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- 3. リソース -----------------------------------------------------------
# Package.swift は AmbientContextMac の Resources を exclude しているので SwiftPM の
# リソースバンドルは生成されない。.lproj をそのまま Contents/Resources/ に置き、
# アプリ側は Bundle.main から読む (設計書 §3.1 / PoC 4 §5)。
LOCALIZATIONS=()
for lproj in "$PACKAGE_DIR/Sources/AmbientContextMac/Resources"/*.lproj; do
  [ -d "$lproj" ] || continue
  cp -R "$lproj" "$APP/Contents/Resources/"
  rm -f "$APP/Contents/Resources/$(basename "$lproj")/.gitkeep"
  LOCALIZATIONS+=("$(basename "$lproj" .lproj)")
done
if [ ${#LOCALIZATIONS[@]} -eq 0 ]; then
  LOCALIZATIONS=(en ja)
fi
echo "--- localizations: ${LOCALIZATIONS[*]}"

# .lproj 以外のリソース (契約フィクスチャ等) を将来足す場合もここに置く。
for extra in "$PACKAGE_DIR/Sources/AmbientContextMac/Resources"/*; do
  [ -e "$extra" ] || continue
  case "$extra" in *.lproj) continue ;; esac
  cp -R "$extra" "$APP/Contents/Resources/"
done

# --- 4. アイコン (actool 不要: 元 PNG -> sips -> iconutil) -----------------
ICON_SRC="$PACKAGE_DIR/Resources/AppIcon-1024.png"
if [ -f "$ICON_SRC" ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  # icns に必要な 10 枚。sips でダウンスケールするだけ (第三者ツール不要)。
  for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
              "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
              "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
    px="${spec%%:*}"
    name="${spec#*:}"
    sips -z "$px" "$px" "$ICON_SRC" --out "$ICONSET/$name.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET")"
  echo "--- icon: $(basename "$ICON_SRC") -> AppIcon.icns"
else
  echo "--- icon: $ICON_SRC not found; skipping (.app will use the generic icon)" >&2
fi

# --- 5. Info.plist ---------------------------------------------------------
LOCALIZATION_XML=""
for loc in "${LOCALIZATIONS[@]}"; do
  LOCALIZATION_XML="$LOCALIZATION_XML<string>$loc</string>"
done

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
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>$DEPLOYMENT_TARGET</string>
  <key>NSHumanReadableCopyright</key><string>Copyright (c) 2026 nassie256. MIT License.</string>
  <key>NSAppleEventsUsageDescription</key><string>「メディア」のコンテキストを有効にしたときだけ、再生中の曲を Music / Spotify から読み取ります。 / Ambient Context MCP reads the now-playing track from Music and Spotify, only while you enable the media context.</string>
  <key>NSAccessibilityUsageDescription</key><string>「ウィンドウタイトル」のコンテキストを有効にしたときだけ、最前面ウィンドウのタイトルを読み取ります。 / Ambient Context MCP reads the frontmost window title, only while you enable the window-title context.</string>
  <key>CFBundleLocalizations</key>
  <array>$LOCALIZATION_XML</array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

# --- 6. 署名 ---------------------------------------------------------------
# Developer ID が無いため ad-hoc (-s -)。Hardened Runtime は公証の前提条件であって、
# 公証しない配布では利点がゼロ (PoC 4 §6.1) なので既定 OFF。
# `--deep` は使わず、ヘルパー (ambient-mcp-stdio) → .app の順に個別署名する。
HARDENED="${HARDENED:-0}"
SIGN_OPTS=(--force --sign -)
if [ "$HARDENED" = "1" ]; then
  SIGN_OPTS+=(--options runtime)
fi

codesign "${SIGN_OPTS[@]}" "$OUT_DIR/$BRIDGE_NAME"
codesign "${SIGN_OPTS[@]}" "$APP"

echo "--- codesign -dv --verbose=2 ---"
codesign -dv --verbose=2 "$APP" 2>&1 || true
echo "--- codesign --verify --strict ---"
codesign --verify --strict --verbose=2 "$APP" 2>&1 || true
codesign --verify --strict --verbose=2 "$OUT_DIR/$BRIDGE_NAME" 2>&1 || true
# 公証していないので rejected が正常。CI で失敗扱いにしない (PoC 4 §9)。
echo "--- spctl -a -t exec -vv (未公証のため rejected が想定どおり) ---"
spctl -a -t exec -vv "$APP" 2>&1 || true

echo ""
echo "built:"
echo "  $APP"
echo "  $OUT_DIR/$BRIDGE_NAME"
