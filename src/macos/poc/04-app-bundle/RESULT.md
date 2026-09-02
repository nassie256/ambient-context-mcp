# Phase 0 PoC #4: SwiftPM だけで .app バンドル (LSUIElement + NSStatusItem) を作る

- 実施日: 2026-09-03
- 環境: macOS 26.6.2 (25G83) arm64 / Apple Swift 6.3.3 (swiftlang-6.3.3.1.3) / **Command Line Tools のみ** (`xcode-select -p` = `/Library/Developer/CommandLineTools`)
- 検証対象: 設計書 §2.2 (ツールチェーン) / §3.1 (ディレクトリ構成・Resources) / §3.3 のトレイ・設定ウィンドウ・自動起動・ローカライズ行 / §9 (ad-hoc 署名) / §10 (Xcode の要否) / §4 Phase 0 項目 4
- 結論: **成立**。Xcode 無し (SwiftPM + `codesign` + `iconutil` + `plutil` + `lipo`) で LSUIElement な .app を組み立て、`NSStatusItem`・SwiftUI 設定ウィンドウ・`SMAppService` ログイン項目・ja/en ローカライズがすべて動作した。ただし **Universal ビルドの手順** と **SwiftPM リソースバンドルの配置** で設計書の記述を修正する必要がある (§7)。

## 1. Xcode 系ツールの実際の可否

```
$ xcodebuild -version
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory
'/Library/Developer/CommandLineTools' is a command line tools instance
$ actool --version   # 同じエラー (ibtool も同様)
```

`/usr/bin/` に shim は存在するが実体は無い。一方 `swift` / `swiftc` / `codesign` / `iconutil` / `plutil` / `hdiutil` / `lipo` / `spctl` / `xattr` / `ditto` はすべて CLT で利用可能。設計書 §10 の前提は正しい。

## 2. 成果物

```
src/macos/poc/04-app-bundle/
├─ Package.swift                    executableTarget "AmbientPocApp" (macOS 14, Swift 6 mode)
├─ scripts/build-app.sh             swift build → .app 組立 → icns → codesign → 検証
├─ scripts/make-icon.swift          AppIcon を AppKit で描いて .iconset PNG を書き出す (actool 代替)
└─ Sources/AmbientPocApp/
   ├─ main.swift                    NSApplication 手組み (nib/storyboard 無し) + .accessory
   ├─ AppDelegate.swift             NSStatusItem / NSMenu / NSPasteboard / 設定ウィンドウ / selftest
   ├─ SettingsView.swift            SwiftUI TabView 2 タブ (MCP サーバ / 送信設定)
   ├─ LoginItem.swift               SMAppService.mainApp ラッパ
   ├─ Strings.swift                 リソースバンドル解決 + NSLocalizedString
   ├─ PocLog.swift                  stdout + ファイルへのログ (画面が見えない環境用)
   └─ Resources/{en,ja}.lproj/Localizable.strings
```

`Package.swift` で `defaultLocalization: "en"` は **必須** (無いと `error: manifest property 'defaultLocalization' not set; it is required in the presence of localized resources`)。`.lproj` を含む `.process("Resources")` を書くだけでは通らない。

画面を見ずに検証できるよう、環境変数で自動実行するモードを入れてある:

| 環境変数 | 効果 |
|---|---|
| `AMBIENT_POC_LOG=<path>` | ログを stdout とファイルの両方へ |
| `AMBIENT_POC_SELFTEST=1` | 起動直後にコピー 3 種・pause トグル・メニュー構築・設定ウィンドウ open/close/再 open を実行 |
| `AMBIENT_POC_LOGINITEM=cycle` | `SMAppService.mainApp` を register → unregister |
| `AMBIENT_POC_AUTOQUIT=<秒>` | N 秒後に `NSApp.terminate` |

`open --env KEY=VALUE` で .app 起動時にも渡せる (macOS 26 で確認)。

## 3. ビルドと .app 組立

```
$ ./scripts/build-app.sh
Building for production...
Build complete! (26.77s)
build dir: .../.build/arm64-apple-macosx/release
.../dist/AmbientPoc.app/Contents/Info.plist: OK          # plutil -lint
wrote 10 pngs to .../dist/AppIcon.iconset                # make-icon (AppKit 描画)
--- codesign -dv --verbose=2 ---
Executable=.../dist/AmbientPoc.app/Contents/MacOS/AmbientPocApp
Identifier=io.github.nassie256.ambient-context-mcp.poc
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20400 size=644 flags=0x2(adhoc) hashes=13+3 location=embedded
Signature=adhoc
Info.plist entries=16
TeamIdentifier=not set
Sealed Resources version=2 rules=13 files=4
--- codesign --verify --strict ---
.../AmbientPoc.app: valid on disk
.../AmbientPoc.app: satisfies its Designated Requirement
--- spctl -a -t exec -vv ---
.../AmbientPoc.app: rejected
```

`spctl` の出力は **`rejected` の 1 行のみ** (`source=...` 行は出ない)。公証が無いので想定どおり。

Info.plist に入れたキー: `CFBundleIdentifier` = `io.github.nassie256.ambient-context-mcp.poc`, `CFBundleExecutable`, `CFBundleName`, `CFBundleDisplayName`, `CFBundlePackageType=APPL`, `CFBundleShortVersionString=0.0.1`, `CFBundleVersion=1`, `CFBundleIconFile=AppIcon`, `LSUIElement=true`, `LSMinimumSystemVersion=14.0`, `NSHumanReadableCopyright`, `NSAppleEventsUsageDescription`, `NSAccessibilityUsageDescription`, `CFBundleLocalizations=[en, ja]`。`PkgInfo` は `APPL????`。

### アイコン (actool 不要)

`scripts/make-icon.swift` を `swiftc -O` でその場でコンパイルし、`icon_16x16.png` … `icon_512x512@2x.png` の 10 枚を `.iconset` に描画 → `iconutil -c icns` で `AppIcon.icns` を生成。Asset Catalog は一切使わない。設計書 §10 の想定どおり動く。

メニューバーアイコンはさらに単純で、`NSImage(size:flipped:)` の描画クロージャで弧 3 本 + ドットを描き `isTemplate = true` にするだけ。**画像ファイル自体が不要**なので、テンプレート画像を Resources に置く必要すらない。

## 4. 動作確認

### 4.1 メニューバーアイテム (見えない画面の代わりに AX で確認)

```
$ osascript -e 'tell application "System Events" to get properties of menu bar item 1 of menu bar 1 of process "AmbientPocApp"'
position:1119, 7, class:menu bar item, role description:状況メニュー, title:,
size:36, 24, help:Ambient Context MCP, enabled:true, role:AXMenuBarItem, subrole:AXMenuExtra
```

- `menu bar 2` は **存在しない** (`-1719 invalid index`)。LSUIElement アプリ自身のプロセスから見ると status item は **`menu bar 1`** に入る。指示にあった `menu bar 2` は「通常アプリのアプリメニューが menu bar 1」の場合の話で、accessory アプリでは 1 になる。
- `NSApp.activationPolicy().rawValue` = **1** (`.accessory`)。`.prohibited` が 2。
- `statusitem created visible=true length=-1.0 hasImage=true template=true`

### 4.2 左クリック / 右クリックの分岐

`button.sendAction(on: [.leftMouseUp, .rightMouseUp])` + `NSApp.currentEvent?.type` で分岐する実装で、
右クリック時のみ `NSMenu` を組んで `statusItem.menu = menu; button.performClick(nil); statusItem.menu = nil` で表示する
(menu を張りっぱなしにすると左クリックもメニューになるため、Windows 版の `TrackPopupMenu` と同じく毎回作って外す)。
実クリックは無人環境で発生させられないため、**メニュー構築とアクション実行を selftest で直接叩いて検証**した。

```
menu items=["Ambient Context MCP — :37690 (paused)", "", "Settings", "",
            "Copy MCP URL", "Copy Token", "Copy Claude Code snippet", "", "Resume", "", "Quit"]
pasteboard copy url ok=true readback=true
pasteboard copy token ok=true readback=true
pasteboard copy snippet ok=true readback=true
pause toggled paused=true / false
```

Windows 版 `TrayHost.cs` の 8 項目 (状態行 disabled / Settings / URL / Token / Snippet / Pause↔Resume / Quit + セパレータ) と同じ構成を再現できた。状態行は `NSMenuItem.isEnabled = false`、`autoenablesItems` はデフォルトのままでも `action == nil` なので灰色になる。

### 4.3 設定ウィンドウ

```
settings window created autosave=SettingsWindow frame={{854, 681}, {520, 392}}
settings window closed; app stays alive (LSUIElement/.accessory)
settings window reuse frame={{854, 681}, {520, 392}}
settings window same instance on reopen=true
```

- `NSHostingController(rootView: SettingsView())` を `NSWindow(contentViewController:)` に載せるだけで SwiftUI `TabView` が動く。
- `isReleasedWhenClosed = false` と `applicationShouldTerminateAfterLastWindowClosed → false` の 2 つで「閉じても終了しない・同一インスタンスを再表示」を担保。
- `setFrameAutosaveName("SettingsWindow")` は `NSWindow "SettingsWindow"` キーで `UserDefaults` に保存され、再起動後も同じ frame が復元された。

### 4.4 ログイン項目 (SMAppService)

**実 .app バンドルから `open` で起動した場合のみ成功**する。ad-hoc 署名でも Developer ID 無しで通った。

```
loginitem initial status=notFound          # 一度も登録していない状態
loginitem register ok status=enabled
loginitem unregister ok status=notRegistered
loginitem final status=notRegistered       # ← 最終状態。登録は残していない
```

- `.build/.../release/AmbientPocApp` を直接実行した場合は `Bundle.main` が .app でないため `status=notFound` のまま。
- `sfltool dumpbtm` は **管理者認証ダイアログを出すため使用しない** (ユーザ環境でパスワードを要求してしまう)。検証は `SMAppService.mainApp.status` のみで行った。最終状態は `notRegistered` = ログイン項目に何も残していない。
- 実装上の注意: `register()` が失敗してもトグルが ON のままにならないよう、`onChange` の最後で `LoginItem.isEnabled` を読み直してトグルを実状態に合わせている。

### 4.5 ローカライズ (ja / en)

```
$ ./dist/AmbientPoc.app/Contents/MacOS/AmbientPocApp -AppleLanguages "(en)"
i18n bundle=.../AmbientPoc.app/Contents/Resources/AmbientPocApp_AmbientPocApp.bundle
i18n localizations=["en", "ja"]
i18n tray.settings=Settings / tray.pause=Pause / settings.tab.mcpServer=MCP Server
menu items=[... "Settings", "Copy MCP URL", "Copy Token", "Copy Claude Code snippet", "Resume", "Quit"]

$ ./dist/AmbientPoc.app/Contents/MacOS/AmbientPocApp -AppleLanguages "(ja)"
i18n tray.settings=設定 / tray.pause=一時停止 / settings.tab.mcpServer=MCP サーバ
menu items=["Ambient Context MCP — :37690 (一時停止中)", "", "設定", "",
            "MCP URL をコピー", "トークンをコピー", "Claude Code 用設定をコピー", "", "再開", "", "終了"]
```

引数 `-AppleLanguages "(ja)"` は `NSUserDefaults` の argument domain として効くので、**再起動なしのテストに使える** (製品版の言語切替は設計書どおり `UserDefaults` へ書いて再起動)。

## 5. ★ 最大の落とし穴: SwiftPM リソースバンドルの配置

`swift build` は `AmbientPocApp_AmbientPocApp.bundle` (shallow bundle。`Contents/` 無しで直下に `en.lproj` / `ja.lproj` / `Info.plist`) を実行ファイルと同じディレクトリに出す。SwiftPM が自動生成する `Bundle.module` は次のコードになっている:

```swift
let mainPath = Bundle.main.bundleURL.appendingPathComponent("AmbientPocApp_AmbientPocApp.bundle").path
let buildPath = "/Users/takumi/.../.build/arm64-apple-macosx/release/AmbientPocApp_AmbientPocApp.bundle"
guard let bundle = Bundle(path: mainPath) ?? Bundle(path: buildPath) else { fatalError(...) }
```

問題が 2 つある。

1. `mainPath` は `Bundle.main.bundleURL` = **`AmbientPoc.app/` 直下**であって `Contents/Resources/` ではない。標準の `Contents/Resources/` に置くと `Bundle.module` は見つけられず、**`fatalError: could not load resource bundle`** でクラッシュする (実測)。
2. 見つからない場合のフォールバックが **ビルドマシンの絶対パス**。開発機では `.build/` が残っているため “動いてしまい”、他人の Mac で初めてクラッシュする。実際、最初の検証は `.build` のバンドルを掴んでいた (`bundle=.../.build/arm64-apple-macosx/release/...`)。

`.app 直下`に置けば `Bundle.module` は通るが、今度は署名が落ちる:

```
$ cp -R ..._AmbientPocApp.bundle dist/AmbientPoc.app/ && codesign --force --deep --sign - dist/AmbientPoc.app
dist/AmbientPoc.app: unsealed contents present in the bundle root
$ codesign --verify --strict --verbose=2 dist/AmbientPoc.app
dist/AmbientPoc.app: unsealed contents present in the bundle root
```

→ **`Contents/Resources/` に置き、`Bundle.module` を使わず自前アクセサで解決する**のが唯一の正解:

```swift
enum PocResources {
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AmbientPocApp_AmbientPocApp.bundle"),
           let b = Bundle(url: url) { return b }
        return Bundle.module   // swift run など非 .app 実行時のフォールバック
    }()
}
```

`.build` のバンドルを退避してもこの経路で ja/en とも解決できることを確認済み。

## 6. 署名・Gatekeeper・quarantine

### 6.1 Hardened Runtime (`--options runtime`) は付けても動くが、付けない

`HARDENED=1 ./scripts/build-app.sh` で比較した。

| | flags | 動作 |
|---|---|---|
| ad-hoc のみ | `flags=0x2(adhoc)` | 起動・status item・SMAppService すべて OK |
| ad-hoc + hardened | `flags=0x10002(adhoc,runtime)`, `Runtime Version=26.5.0` | 同上、**問題は起きなかった** |

いずれも `spctl -a -t exec -vv` は `rejected`。Hardened Runtime は「公証の前提条件」であり、公証しない配布では利点がゼロで、Library Validation や JIT/DYLD 制限が増えるだけ。さらに `Runtime Version` がビルド機の SDK (26.5) で刻まれ、将来 dylib やプラグインを足したときに突然壊れうる。**既定は付けない** (`HARDENED=1` で切替できるようにだけしてある)。

`--deep` は Apple 的には非推奨だが、今回の .app は `Contents/Resources/*.bundle` に実行コードを含まないため、実質 `codesign --force --sign - <app>` と同じ。将来ヘルパー実行ファイル (`ambient-mcp-stdio`) を同梱するときは **内側から順に個別署名**へ切り替えるべき。

### 6.2 zip 往復と quarantine

```
$ ditto -c -k --sequesterRsrc --keepParent dist/AmbientPoc.app gk/AmbientPoc.zip   # 163K
$ ditto -x -k gk/AmbientPoc.zip gk/extracted
$ xattr -l gk/extracted/AmbientPoc.app
com.apple.provenance:
$ codesign --verify --strict --verbose=2 gk/extracted/AmbientPoc.app
... valid on disk / satisfies its Designated Requirement
```

`ditto` での zip 往復では署名は壊れず、quarantine も付かない (quarantine を付けるのはダウンロードしたアプリ側)。

ダウンロードを模して `com.apple.quarantine` を書いたときの挙動は **フラグ値で 2 通りに割れる**:

| 設定した値 | 結果 |
|---|---|
| `0083;...;Safari;` (指示にあった値。0x0080 = `QTN_FLAG_USER_APPROVED` を含む) | ダイアログ **無し**で起動する。ただし **App Translocation** され、`/private/var/folders/.../AppTranslocation/<UUID>/d/AmbientPoc.app` の読み取り専用コピーとして走る。`open --env` で渡した環境変数も届かなかった |
| `0001;...;Safari;` (`QTN_FLAG_DOWNLOAD` のみ = 実際のダウンロード直後の状態) | プロセスは即座に終了。`CoreServicesUIAgent` が「"AmbientPoc.app"は開いていません / Appleは、"AmbientPoc.app"にMacに損害を与えたり、プライバシーを侵害する可能性のあるマルウェアが含まれていないことを検証できませんでした。」を表示 (数秒で自動的に消える通知型) |

`spctl -a -t exec -vv` はどちらも `rejected` (exit code 3)。

回避策の確認:

```
$ xattr -d -r com.apple.quarantine gk/extracted2/AmbientPoc.app
$ open -n gk/extracted2/AmbientPoc.app     # 正常起動、translocation もされない
```

App Translocation は「quarantine 付きのまま起動されると読み取り専用の別パスで走る」ため、**`~/Library/Application Support/` への設定書き込みは動くが、`SMAppService.mainApp` の登録先パスや `mcp-api.json` の discovery が壊れる**。README には「zip を展開したら `/Applications` へ移動 → `xattr -d -r com.apple.quarantine /Applications/AmbientContextMcp.app`、または右クリック → 開く」を明記する必要がある (`xattr` は **`-r` 付き**が確実。トップレベルだけ消しても内部に残ることがある)。

## 7. Universal バイナリ: CLT だけで作れる (ただし設計書の手順は誤り)

```
$ swift build -c release --arch arm64 --arch x86_64
error: xcbuild executable at '/Library/Developer/SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild'
does not exist or is not executable
```

`--arch` を 2 つ渡す方式は **XCBuild (Xcode 同梱) を要求するので CLT のみでは使えない**。代替として `--triple` で 2 回ビルドし `lipo` で結合すれば成功する:

```
$ swift build -c release                                   # .build/arm64-apple-macosx/release
$ swift build -c release --triple x86_64-apple-macosx14.0  # .build/x86_64-apple-macosx/release
$ lipo -create -output <app>/Contents/MacOS/AmbientPocApp <arm>/AmbientPocApp <x86>/AmbientPocApp
$ lipo -info ...
Architectures in the fat file: ... are: x86_64 arm64
$ codesign -dv --verbose=2 dist/AmbientPoc.app
Format=app bundle with Mach-O universal (x86_64 arm64)
```

`scripts/build-app.sh` は `UNIVERSAL=1` でこの経路を通す。リソースバンドルは arch 非依存なので arm64 側のものを 1 つコピーすれば足りる。x86_64 スライスの実機動作 (Rosetta ではなく Intel Mac) は本機では検証不可 (Apple Silicon のみ)。

## 8. 最終的な build-app.sh の構成

1. `swift build -c release` (+ `UNIVERSAL=1` なら `--triple x86_64-apple-macosx14.0` も)
2. `dist/AmbientPoc.app/Contents/{MacOS,Resources}` を作り、実行ファイルを `cp` (Universal なら `lipo -create`)
3. `AmbientPocApp_AmbientPocApp.bundle` を **`Contents/Resources/`** へ `cp -R`
4. `Info.plist` をヒアドキュメントで書き `plutil -lint` で検証、`PkgInfo` に `APPL????`
5. `swiftc -O scripts/make-icon.swift` → `.iconset` 10 枚 → `iconutil -c icns`
6. `codesign --force --deep --sign -` (既定。`HARDENED=1` で `--options runtime` を追加)
7. `codesign -dv --verbose=2` / `codesign --verify --strict` / `spctl -a -t exec -vv` を出力

Xcode 依存ゼロ。`hdiutil` (dmg) と `ditto` (zip) も CLT にあるので、Phase 5 の `package-release.sh` も同じ方針で書ける。

## 9. 設計書への反映提案

### §2.2 (対応 OS / ツールチェーン)

- 「Universal」の作り方を明記する。**`swift build --arch arm64 --arch x86_64` は Xcode (XCBuild) 必須で CLT では失敗する**。CLT で作るなら `--triple x86_64-apple-macosx14.0` と既定 (arm64) の 2 回ビルド + `lipo -create`。CI の `macos-latest` は Xcode 入りなので `--arch` でも通るが、ローカルと CI で手順が割れないよう **`--triple` + `lipo` に統一**することを推奨。
- `Package.swift` に `defaultLocalization: "en"` が必須である旨を追記。

### §3.1 (ディレクトリ構成)

- `Resources/` の説明から `Assets.xcassets` を落とす (§10 と矛盾している)。メニューバーアイコンは **画像ファイルを持たず `NSImage` の描画クロージャ + `isTemplate = true`**、AppIcon は `scripts/make-icon.swift` + `iconutil` でビルド時生成、という形が実証済み。
- `scripts/make-icon.swift` を構成図に追加。
- リソースバンドルの配置ルールを明記: **`.app/Contents/Resources/<Target>_<Target>.bundle`** に置き、**`Bundle.module` を直接使わず `Bundle.main.resourceURL` 起点の自前アクセサを通す**。理由 (`.app` 直下だと `codesign` が `unsealed contents present in the bundle root` で落ちる / `Bundle.module` のフォールバックがビルド機の絶対パスで開発機だけ動いてしまう) も残す。ローカライズ以外のリソース (契約フィクスチャ JSON など) も同じアクセサを経由させること。

### §3.3 (対応表)

- トレイ行: `menu bar 1` (accessory アプリでは status item は menu bar 1 に入る) と、`statusItem.menu` を **表示時だけ張って直後に外す** 実装パターンを注記。
- 設定ウィンドウ行: `setFrameAutosaveName` に加えて **`isReleasedWhenClosed = false`** と **`applicationShouldTerminateAfterLastWindowClosed → false`** が必要である旨を追記 (これが無いと「閉じる → 再クリックで再表示」が壊れる)。
- 自動起動行: 「.app バンドル必須」に加え **ad-hoc 署名でも `register()` は成功する** (Developer ID 不要) ことを確認済みとして追記。`register()` 失敗時に UI トグルを実状態へ戻す必要があることも。
- ローカライズ行: テスト手段として `-AppleLanguages "(ja)"` の引数指定が使えること。

### §10 (Xcode の要否)

- 表に **XCBuild (`--arch` 複数指定)** の行を追加し、回避策 = `--triple` + `lipo` を書く。現状「Xcode でしか使えないもの」が actool / String Catalog / xcodebuild / IB の 4 行しかなく、Universal ビルドの落とし穴が抜けている。
- 結論 (「入れなくても計画は完遂できる」) は **維持でよい**。実測で全項目クリアした。

### Phase 5 (配布) への追加

- `package-release.sh` は `ditto -c -k --sequesterRsrc --keepParent` を使う (署名が保たれることを確認済み)。
- README の quarantine 手順は **`xattr -d -r com.apple.quarantine /Applications/AmbientContextMcp.app`** (`-r` 必須) と「右クリック → 開く」の 2 通り、加えて **「zip を展開したら必ず `/Applications` に移動してから開く」** を書く。移動せずに quarantine 付きのまま開くと **App Translocation** で読み取り専用の一時パスから起動し、discovery ファイル・ログイン項目・環境変数が期待どおりに動かない。
- ヘルパー実行ファイル (`ambient-mcp-stdio`) を .app に同梱する段になったら `--deep` をやめ、内側の実行ファイルから順に個別署名する。
- 公証しないので **Hardened Runtime (`--options runtime`) は付けない**方針を明記 (付けても動作はしたが利点が無い)。
- `spctl -a -t exec -vv` が `rejected` を返すのは正常であり、CI の検証ステップで失敗扱いにしないこと。

## 10. 後片付け

- 起動したプロセスはすべて終了済み (`pgrep -fl AmbientPocApp` → 該当なし)。
- ログイン項目は登録されていない (`SMAppService.mainApp.status` = `notRegistered`)。
- `dist/` と `.build/` は `.gitignore` 済み。ログは `/private/tmp/claude-501/.../scratchpad/poc4*.log`。
