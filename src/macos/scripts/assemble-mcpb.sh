#!/bin/bash
# Windows と macOS 双方のビルド成果物を 1 つの `.mcpb` に詰める。
#
# .mcpb はクロスプラットフォームの単一ファイルにする方針 (設計書 §9) なので、
# 中身は 2 つの CI ランナー (windows-latest / macos-latest) の出力を合成する必要がある。
# このスクリプトはその合成専用で、ビルドは行わない。
#
#   <staging>/
#   ├─ manifest.json                     mcpb/manifest.json をコピー
#   ├─ icon.png                          mcpb/icon.png があればコピー
#   └─ server/
#      ├─ ambient-mcp-stdio.exe          (win) Claude Desktop が win32 で起動する stdio シム
#      ├─ ambient-mcp.exe + *.dll        (win) トレイ本体と WinUI / .NET の依存
#      ├─ ambient-mcp-stdio              (mac) darwin の platform_overrides.command
#      └─ Ambient Context MCP.app/       (mac) メニューバー常駐アプリ (シムが open で spawn)
#
# 使い方:
#   scripts/assemble-mcpb.sh --win-server dist/win/server --mac-server dist/macos
#   scripts/assemble-mcpb.sh --mac-server dist/macos            # mac だけで動作確認する場合
#       (--win-server 無しのときは manifest の entry_point / win32 command を darwin の
#        バイナリに書き換える。ステージングに .exe が無く検証も起動も失敗するため。リリース用ではない)
#   scripts/assemble-mcpb.sh ... --version 0.8.0 --out dist
#
# mcpb CLI (`npm i -g @anthropic-ai/mcpb`) があれば manifest を検証して pack し、
# 無ければ zip にフォールバックする (tools/build-release.ps1 と同じ方針・検証なし)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WIN_SERVER=""
MAC_SERVER=""
VERSION=""
DIST_DIR="$REPO_ROOT/dist"

while [ $# -gt 0 ]; do
  case "$1" in
    --win-server) WIN_SERVER="${2:?--win-server needs a value}"; shift 2 ;;
    --mac-server) MAC_SERVER="${2:?--mac-server needs a value}"; shift 2 ;;
    --version)    VERSION="${2:?--version needs a value}"; shift 2 ;;
    --out)        DIST_DIR="${2:?--out needs a value}"; shift 2 ;;
    -h|--help)    sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

MANIFEST="$REPO_ROOT/mcpb/manifest.json"
if [ -z "$VERSION" ]; then
  VERSION="$(grep -m1 '"version"' "$MANIFEST" \
    | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
fi
if [ -z "$VERSION" ]; then
  echo "could not resolve version (pass --version)" >&2
  exit 1
fi

if [ -z "$WIN_SERVER" ] && [ -z "$MAC_SERVER" ]; then
  echo "at least one of --win-server / --mac-server is required" >&2
  exit 2
fi

mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
MCPB_PATH="$DIST_DIR/ambient-context-mcp-v$VERSION.mcpb"

STAGING="$DIST_DIR/mcpb-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING/server"

cp "$MANIFEST" "$STAGING/manifest.json"
# mac だけで組む場合、既定の manifest が指す entry_point / command
# (server/ambient-mcp-stdio.exe) はステージングに存在しない = 検証も起動も失敗する。
# darwin 側の実体を指すように書き換える (.exe は entry_point と win32 の command の 2 箇所だけ。
# platform_overrides.darwin は元から拡張子なし)。動作確認専用で、リリース用ではない。
if [ -z "$WIN_SERVER" ]; then
  echo "--- mac-only bundle: rewriting entry_point/command to the darwin binary (not for release)"
  sed 's#server/ambient-mcp-stdio\.exe#server/ambient-mcp-stdio#g' "$STAGING/manifest.json" \
    > "$STAGING/manifest.json.tmp"
  mv "$STAGING/manifest.json.tmp" "$STAGING/manifest.json"
fi

if [ -f "$REPO_ROOT/mcpb/icon.png" ]; then
  cp "$REPO_ROOT/mcpb/icon.png" "$STAGING/icon.png"
fi

copy_server_payload() {
  local label="$1" src="$2"
  [ -n "$src" ] || return 0
  if [ ! -d "$src" ]; then
    echo "$label server dir not found: $src" >&2
    exit 1
  fi
  echo "--- $label payload: $src"
  # ディレクトリ (.app) も含めて中身をそのまま server/ 直下へ。
  # ditto は .app の署名と拡張属性を保つ (PoC 4 §6.2)。
  if command -v ditto >/dev/null 2>&1; then
    ditto "$src" "$STAGING/server"
  else
    cp -R "$src"/. "$STAGING/server/"
  fi
}

copy_server_payload "windows" "$WIN_SERVER"
copy_server_payload "macos"   "$MAC_SERVER"

rm -f "$MCPB_PATH"

if command -v mcpb >/dev/null 2>&1; then
  echo "==> packing with the mcpb CLI (validates the manifest)"
  ( cd "$STAGING" && mcpb validate manifest.json && mcpb pack . "$MCPB_PATH" )
else
  echo "==> mcpb CLI not found; falling back to zip (manifest is NOT validated)" >&2
  TMP_ZIP="${MCPB_PATH%.mcpb}.zip"
  rm -f "$TMP_ZIP"
  ( cd "$STAGING" && zip -r -q -y "$TMP_ZIP" . )
  mv "$TMP_ZIP" "$MCPB_PATH"
fi

size="$(stat -f %z "$MCPB_PATH" 2>/dev/null || stat -c %s "$MCPB_PATH")"
mb="$(awk -v b="$size" 'BEGIN { printf "%.2f", b / 1048576 }')"
if command -v shasum >/dev/null 2>&1; then
  sha="$(shasum -a 256 "$MCPB_PATH" | awk '{print $1}')"
else
  sha="$(sha256sum "$MCPB_PATH" | awk '{print $1}')"
fi

echo ""
echo "Artifact:"
echo "  $MCPB_PATH"
echo "    size:    $mb MB ($size bytes)"
echo "    sha256:  $sha"
