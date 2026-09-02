#!/bin/bash
# macOS 版のリリース成果物 (.zip / .dmg) を作る。tools/build-release.ps1 の macOS 版。
#
#   dist/ambient-context-mcp-v<Version>-macos-universal.zip
#       `Ambient Context MCP.app` と `ambient-mcp-stdio` をフラットに含む。
#       Claude Code / Streamable HTTP ユーザ向け。展開 → /Applications へ移動して起動。
#
#   dist/ambient-context-mcp-v<Version>-macos-universal.dmg
#       `Ambient Context MCP.app` + `Applications` シンボリックリンク。
#
# クロスプラットフォームの `.mcpb` は Windows 側の成果物も要るのでここでは作らない。
# CI が両ランナーの server/ ディレクトリを集めて scripts/assemble-mcpb.sh で 1 つに詰める。
#
# 使い方:
#   scripts/package-release.sh                     # universal, version は mcpb/manifest.json
#   scripts/package-release.sh --version 0.8.0 --arch arm64
#   scripts/package-release.sh --skip-dmg
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PACKAGE_DIR/../.." && pwd)"

APP_NAME="Ambient Context MCP"
BRIDGE_NAME="ambient-mcp-stdio"

VERSION=""
ARCH_MODE="universal"
DIST_DIR="$REPO_ROOT/dist"
SKIP_ZIP=0
SKIP_DMG=0

while [ $# -gt 0 ]; do
  case "$1" in
    --version)  VERSION="${2:?--version needs a value}"; shift 2 ;;
    --arch)     ARCH_MODE="${2:?--arch needs a value}"; shift 2 ;;
    --out)      DIST_DIR="${2:?--out needs a value}"; shift 2 ;;
    --skip-zip) SKIP_ZIP=1; shift ;;
    --skip-dmg) SKIP_DMG=1; shift ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$VERSION" ]; then
  VERSION="$(grep -m1 '"version"' "$REPO_ROOT/mcpb/manifest.json" \
    | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
fi
if [ -z "$VERSION" ]; then
  echo "could not resolve version (pass --version)" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
# server/ に相当するステージング。CI ではこのディレクトリをそのまま artifact として
# アップロードし、assemble-mcpb.sh の --mac-server に渡す。
STAGING="$DIST_DIR/macos"

"$SCRIPT_DIR/build-app.sh" --version "$VERSION" --arch "$ARCH_MODE" --out "$STAGING"

ZIP_PATH="$DIST_DIR/ambient-context-mcp-v$VERSION-macos-universal.zip"
DMG_PATH="$DIST_DIR/ambient-context-mcp-v$VERSION-macos-universal.dmg"

# --- .zip ------------------------------------------------------------------
# ditto は署名と拡張属性を保ったまま往復できる (PoC 4 §6.2)。--keepParent を付けないと
# STAGING の中身がアーカイブ直下に入る = .app と ambient-mcp-stdio がトップレベル。
if [ "$SKIP_ZIP" = "0" ]; then
  echo "==> packing zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc "$STAGING" "$ZIP_PATH"
fi

# --- .dmg ------------------------------------------------------------------
if [ "$SKIP_DMG" = "0" ]; then
  echo "==> packing dmg"
  rm -f "$DMG_PATH"
  DMG_SRC="$(mktemp -d)/dmg"
  mkdir -p "$DMG_SRC"
  cp -R "$STAGING/$APP_NAME.app" "$DMG_SRC/"
  ln -s /Applications "$DMG_SRC/Applications"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_SRC" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG_PATH" >/dev/null
  rm -rf "$(dirname "$DMG_SRC")"
fi

# --- サマリ ----------------------------------------------------------------
echo ""
echo "Artifacts:"
for path in "$ZIP_PATH" "$DMG_PATH"; do
  [ -f "$path" ] || continue
  size="$(stat -f %z "$path")"
  mb="$(awk -v b="$size" 'BEGIN { printf "%.2f", b / 1048576 }')"
  sha="$(shasum -a 256 "$path" | awk '{print $1}')"
  echo "  $path"
  echo "    size:    $mb MB ($size bytes)"
  echo "    sha256:  $sha"
done
echo ""
echo "staging (mcpb server/ payload): $STAGING"
