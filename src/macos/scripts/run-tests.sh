#!/bin/bash
# swift test のラッパ。
#
# Command Line Tools だけの環境 (Xcode 未導入) では swift-testing の Testing.framework が
# 既定の検索パスに入っておらず、素の `swift test` が
#   error: no such module 'Testing'
# あるいは実行時の dlopen 失敗になる。Xcode がある環境ではフラグ無しで動くので、
# CLT のフレームワークが存在するときだけ -F / -rpath を足す。
set -euo pipefail

cd "$(dirname "$0")/.."

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

EXTRA_ARGS=()
if [ -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
  EXTRA_ARGS=(
    -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS"
    -Xlinker -F -Xlinker "$CLT_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS"
    -Xlinker -rpath -Xlinker "$CLT_LIB"
  )
fi

exec swift test "${EXTRA_ARGS[@]}" "$@"
