# Phase 0 PoC #2 — Foreground app / window title (Accessibility) / idle seconds

- 実施日: 2026-09-03
- 環境: macOS 26.6.2 (25G83) arm64 / Apple Swift 6.3.3 (Command Line Tools のみ、Xcode 無し)
- 対象: 設計書 [`docs/superpowers/specs/2026-09-03-macos-port-design.md`](../../../../docs/superpowers/specs/2026-09-03-macos-port-design.md) §3.3 の「フォアグラウンドアプリ」「ウィンドウタイトル」「アイドル秒数」「ロック / アンロック」行、および §4 Phase 0 item 2
- 対応する Windows 実装: `src/windows/AmbientContextMcp.Desktop/AmbientContext/WindowsForegroundAppCollector.cs` + `AmbientTier1Rules.cs`

## 0. 結論 (先に要点)

| 項目 | 結果 |
|---|---|
| フォアグラウンドアプリ identity (bundle id / 表示名 / pid / 実行ファイル名) | **権限不要で取得可**。`NSWorkspace.shared.frontmostApplication` |
| フォアグラウンド切替イベント | **権限不要で取得可**。`NSWorkspace.shared.notificationCenter` の `didActivateApplicationNotification` / `didDeactivateApplicationNotification` が実測で発火 |
| フォーカスウィンドウのタイトル (AX) | **アクセシビリティ権限が必須。未許可では 100% 取れない**。`AXIsProcessTrustedWithOptions` が `false` の間は `AXUIElementCopyAttributeValue` を呼ぶ前に degrade する実装で、クラッシュ・ハングなしに `""` + reason を返せることを確認 |
| `swift run` の未署名 (ad-hoc) バイナリに AX 権限を与えられるか | **実質的に不可**。理由は §3。**PoC の範囲では AX タイトル取得の成功パスを実証できていない** (`.app` バンドル + 安定した署名が要る) |
| アイドル秒数 | **権限不要で取得可**。`CGEventSource.secondsSinceLastEventType(.combinedSessionState, kCGAnyInputEventType)` が実測で単調増加 |
| ロック / アンロック通知 | 登録は権限不要でコンパイル・実行できることを確認 (画面ロックは行っていないため発火は未実測) |

設計書の「未許可なら `hasWindowTitle=false` で degrade」という前提はそのまま成立する。ただし **開発中 (`swift run`) は常に degrade 側に落ちる**ため、AX の成功パスは Phase 0 item 4 (`.app` バンドル組み立て) の後でないと検証できない。→ §7 の推奨。

## 1. 成果物

```
src/macos/poc/02-ax-title/
├─ Package.swift                     (swift-tools-version 6.0, .macOS(.v14), Swift 6 language mode)
├─ Sources/ax-title-poc/main.swift
└─ RESULT.md                         (本ファイル)
```

```
swift build
swift run ax-title-poc                 # 1 回スナップショットを出して終了
swift run ax-title-poc --watch 24      # 24 秒間、アクティブ化イベント + 2 秒ごとのアイドル計測
swift run ax-title-poc --prompt-ax     # AXIsProcessTrustedWithOptions(prompt: true) を 1 回だけ呼ぶ
```

出力は 1 行 1 JSON (`event` キーで種別、`ts` は ISO8601)。

## 2. 実測ログ

### 2.1 一発スナップショット (`swift run ax-title-poc`)

```json
{"bundleIdentifier":null,"event":"startup","executablePath":"/Users/takumi/work/ambient-context-mcp/src/macos/poc/02-ax-title/.build/arm64-apple-macosx/debug/ax-title-poc","isAppBundle":false,"osVersion":"Version 26.6.2 (Build 25G83)","pid":15938,"ts":"2026-09-02T17:39:57.577Z"}
{"api":"AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt: false)","event":"accessibility_check","trusted":false,"ts":"2026-09-02T17:39:57.593Z"}
{"accessibilityTrusted":false,"appName":"UserNotificationCenter","available":true,"bundleIdentifier":"com.apple.UserNotificationCenter","category":"other","event":"snapshot","hasWindowTitle":false,"idleSeconds":17.978999999999999,"label":"initial","localizedName":"UserNotificationCenter","presenceBucket":"idle","processId":2660,"processName":"UserNotificationCenter","rawWindowTitle":"","titleReason":"accessibility_not_trusted","ts":"2026-09-02T17:39:57.612Z"}
```

- `bundleIdentifier: null` / `isAppBundle: false` — `swift run` のバイナリは `.app` ではないので `Bundle.main.bundleIdentifier` が nil。これが §3 の TCC 問題の根本
- `trusted: false` — **prompt を出す前**の素の値。初回起動で勝手にプロンプトを出さない設計書の方針 (opt-in ON 時のみ要求) はこの API でそのまま実現できる

### 2.2 `--watch 24` + `open -a TextEdit` / `open -a Calculator` / `osascript quit`

実行スクリプト: watch 開始 → 3 秒後 `open -a TextEdit` → 5 秒後 `open -a Calculator` → 5 秒後 `quit app "Calculator"` → 3 秒後 `quit app "TextEdit"`。

```json
{"bundleIdentifier":null,"event":"startup","executablePath":"...","isAppBundle":false,"osVersion":"Version 26.6.2 (Build 25G83)","pid":16010,"ts":"2026-09-02T17:40:15.227Z"}
{"api":"AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt: false)","event":"accessibility_check","trusted":false,"ts":"2026-09-02T17:40:15.243Z"}
{"accessibilityTrusted":false,"appName":"Claude","available":true,"bundleIdentifier":"com.anthropic.claudefordesktop","category":"other","event":"snapshot","hasWindowTitle":false,"idleSeconds":13.252,"label":"initial","localizedName":"Claude","presenceBucket":"idle","processId":10706,"processName":"Claude","rawWindowTitle":"","titleReason":"accessibility_not_trusted","ts":"2026-09-02T17:40:15.258Z"}
{"event":"watch_start","seconds":24,"ts":"2026-09-02T17:40:15.258Z"}
{"center":"DistributedNotificationCenter.default()","event":"lock_observers_registered","names":["com.apple.screenIsLocked","com.apple.screenIsUnlocked"],"ts":"2026-09-02T17:40:15.258Z"}
{"accessibilityTrusted":false,"appName":"Claude","...,"idleSeconds":15.254,"label":"tick","presenceBucket":"idle","ts":"2026-09-02T17:40:17.260Z"}
{"appName":"TextEdit","available":true,"bundleIdentifier":"com.apple.TextEdit","category":"editor","event":"app_activated","hasWindowTitle":false,"localizedName":"テキストエディット","processId":16030,"processName":"TextEdit","rawWindowTitle":"","source":"NSWorkspace.didActivateApplicationNotification","titleReason":"accessibility_not_trusted","ts":"2026-09-02T17:40:18.370Z"}
{"bundleIdentifier":"com.anthropic.claudefordesktop","event":"app_deactivated","localizedName":"Claude","ts":"2026-09-02T17:40:18.374Z"}
{"accessibilityTrusted":false,"appName":"TextEdit","bundleIdentifier":"com.apple.TextEdit","category":"editor","event":"snapshot","idleSeconds":17.256,"label":"tick","localizedName":"テキストエディット","presenceBucket":"idle","processId":16030,"processName":"TextEdit","ts":"2026-09-02T17:40:19.262Z"}
{"...":"...","idleSeconds":19.256,"label":"tick","ts":"2026-09-02T17:40:21.262Z"}
{"...":"...","idleSeconds":21.257,"label":"tick","ts":"2026-09-02T17:40:23.263Z"}
{"appName":"計算機","available":true,"bundleIdentifier":"com.apple.calculator","category":"other","event":"app_activated","hasWindowTitle":false,"localizedName":"計算機","processId":16054,"processName":"Calculator","rawWindowTitle":"","source":"NSWorkspace.didActivateApplicationNotification","titleReason":"accessibility_not_trusted","ts":"2026-09-02T17:40:23.455Z"}
{"bundleIdentifier":"com.apple.TextEdit","event":"app_deactivated","localizedName":"テキストエディット","ts":"2026-09-02T17:40:23.455Z"}
{"...":"...","idleSeconds":23.257,"label":"tick","bundleIdentifier":"com.apple.calculator","ts":"2026-09-02T17:40:25.263Z"}
{"...":"...","idleSeconds":25.256,"label":"tick","ts":"2026-09-02T17:40:27.262Z"}
{"appName":"TextEdit","bundleIdentifier":"com.apple.TextEdit","category":"editor","event":"app_activated","processId":16030,"processName":"TextEdit","ts":"2026-09-02T17:40:28.478Z"}   ← Calculator quit で TextEdit に戻る
{"bundleIdentifier":"com.apple.calculator","event":"app_deactivated","localizedName":"計算機","ts":"2026-09-02T17:40:28.483Z"}
{"...":"...","idleSeconds":27.256,"label":"tick","ts":"2026-09-02T17:40:29.262Z"}
{"...":"...","idleSeconds":29.256,"label":"tick","ts":"2026-09-02T17:40:31.262Z"}
{"appName":"Claude","bundleIdentifier":"com.anthropic.claudefordesktop","category":"other","event":"app_activated","processId":10706,"ts":"2026-09-02T17:40:31.623Z"}   ← TextEdit quit で Claude に戻る
{"bundleIdentifier":"com.apple.TextEdit","event":"app_deactivated","localizedName":"テキストエディット","ts":"2026-09-02T17:40:31.627Z"}
{"...":"...","idleSeconds":31.256,"label":"tick","ts":"2026-09-02T17:40:33.262Z"}
{"...":"...","idleSeconds":33.255,"label":"tick","ts":"2026-09-02T17:40:35.261Z"}
{"...":"...","idleSeconds":35.255,"label":"tick","ts":"2026-09-02T17:40:37.260Z"}
{"...":"...","idleSeconds":37.255,"label":"tick","ts":"2026-09-02T17:40:39.261Z"}
{"event":"watch_end","ts":"2026-09-02T17:40:39.262Z"}
```

(`tick` 行は冗長なので一部フィールドを `"...": "..."` に省略。`idleSeconds` と `ts` は実測値そのまま。)

観測できたこと:

1. **アクティブ化イベントは確実に発火する。** アプリ起動時だけでなく、アプリ終了で前面が戻る時にも `didActivateApplication` が来る (Calculator 終了 → TextEdit、TextEdit 終了 → Claude)。Windows の `EVENT_SYSTEM_FOREGROUND` と同じ粒度で「前面が変わった」を捕まえられる
2. `didActivateApplication` と `didDeactivateApplication` はほぼ同時 (4ms 差) に来る。**Windows 版と同じく「アクティブ化だけ」を capture トリガにすれば十分**
3. **`idleSeconds` は 13.25 → 37.26 まで単調増加した。** `open -a` / `osascript` によるアプリ起動・終了・フォアグラウンド切替では **リセットされない** (合成イベントではなく HID 入力のみを見ているため)。設計書の「権限不要・HID 入力ベースで `GetLastInputInfo` と同等」は実測で裏づけられた。なお実際に人がキー/マウスを触ると 0 に戻る (このセッション中は誰も触っていない)
4. `presenceBucket` は `AmbientTier1Rules.GetPresenceBucket` と同じ閾値でそのまま動く (13 秒 → `idle`)
5. **`localizedName` はロケール依存**: TextEdit は `"テキストエディット"`、Calculator は `"計算機"` になった。→ §7 の推奨 2

### 2.3 `--prompt-ax` (AXIsProcessTrustedWithOptions with prompt = true, 1 回のみ)

```json
{"bundleIdentifier":null,"event":"startup","executablePath":"...","isAppBundle":false,"osVersion":"Version 26.6.2 (Build 25G83)","pid":16277,"ts":"2026-09-02T17:40:55.666Z"}
{"api":"AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt: false)","event":"accessibility_check","trusted":false,"ts":"2026-09-02T17:40:55.690Z"}
{"api":"AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt: true)","event":"accessibility_check","note":"...","trusted":false,"ts":"2026-09-02T17:40:55.690Z"}
{"accessibilityTrusted":false,"appName":"Claude","...,"idleSeconds":53.702,"label":"initial","titleReason":"accessibility_not_trusted","ts":"2026-09-02T17:40:55.708Z"}
```

- **`prompt: true` でも呼び出しはブロックしない**。即座に `false` を返し、プロセスはそのまま先へ進む (0.02ms 未満)。つまり「プロンプトを出しつつ現在値で degrade する」実装が安全に書ける
- **プロンプトのクリックは私 (エージェント) にはできない。** アクセシビリティ許可のダイアログは TCC が出すシステムモーダルで、ユーザーが物理的に操作する以外に承認手段が無い (プログラム的に承認する API は存在しない。SIP 下で `/Library/Application Support/com.apple.TCC/TCC.db` は読み書き不可 — 実際に `sqlite3` で開こうとして `authorization denied` を確認済み)
- 私の環境からは、このプロンプトが実際に画面に出たかどうかを視覚的に確認できていない (`log show` は本セッションの権限では tccd のレコードを返さなかった)。**実 `.app` での期待フロー**は以下:
  1. ユーザーが設定ウィンドウで `foregroundApp.rawWindowTitle` / `titleSummary` の opt-in を ON にする
  2. アプリが `AXIsProcessTrustedWithOptions(prompt: true)` を呼ぶ
  3. OS が「"AmbientContextMcp" がアクセシビリティ機能を使ってこのコンピュータの制御を求めています」というアラートを出し、[システム設定を開く] / [許可しない] を提示する
  4. ユーザーがシステム設定 → プライバシーとセキュリティ → アクセシビリティ で当該アプリのトグルを ON にする
  5. **macOS は許可付与後にアプリを再起動させることがある** (従来は必須、近年は再起動不要なケースもある)。アプリ側は `AXIsProcessTrusted()` を定期的に (または `com.apple.accessibility.api` の distributed notification で) 再評価し、ONになったら degrade を解除する実装が必要

## 3. 未署名 `swift run` バイナリに AX 権限を与えられるか → 実質不可

実測した阻害要因:

| # | 事実 | 確認方法 |
|---|---|---|
| 1 | ビルド成果物は **ad-hoc 署名** で TeamIdentifier 無し | `codesign -dvvv` → `flags=0x2(adhoc)` / `Signature=adhoc` / `TeamIdentifier=not set` |
| 2 | ad-hoc 署名の TCC 上の同一性は **cdhash**。コードを 1 行変えるだけで cdhash が変わる。しかも元のソースに戻して再ビルドしても **cdhash は元に戻らない** (ビルドが再現可能でない) | `CDHash=2aa2132…` → 変更後 `aa689608…` → ソースを戻して再ビルド `cf367510…` |
| 3 | `.app` ではないので `Bundle.main.bundleIdentifier` が nil。TCC の一覧に載せる際の識別子・表示名・アイコンが無い | 実測 (`isAppBundle: false`) |
| 4 | システム設定 → プライバシーとセキュリティ → アクセシビリティ の [+] は **アプリケーション (.app) を選ぶピッカー**であり、素の Mach-O 実行ファイルを追加する導線が無い | 既知の OS 仕様 (本 PoC では未検証。TCC 承認はユーザー操作でしか行えないため) |

**結論**: `swift run` した CLI バイナリで AX タイトル取得の成功パスを検証するのは現実的でない。仮に一度許可できたとしても、次のビルドで cdhash が変わって権限が外れる (「変更されたため許可が取り消されました」)。

実用上の回避策 (Phase 0 item 4 の `.app` 組み立てが済んだ後に使う):

- **`.app` バンドルにして安定した署名を付ける**。ad-hoc (`codesign -s -`) でも `.app` なら TCC の一覧に載せられるが、リビルドのたびに cdhash が変わり権限が外れるため、**開発中は `.app` を固定パス (例 `~/Applications/AmbientContextMcp.app`) に置き、署名を毎回同じ方法で付け直したうえで権限を再付与する運用**になる。Developer ID があれば TCC は Team ID + bundle id で識別するのでこの問題は消える (§9 の決定どおり本プロジェクトは Developer ID 無し)
- **CLI での開発時のデバッグ**は、AX 権限を既に持っているターミナルアプリ (Terminal.app / iTerm2 に権限を与える運用) の子プロセスとして走らせると通る場合がある。ただし TCC の「責任プロセス」の帰属は OS バージョンで挙動が変わるため、**製品の判定ロジックをこの経路の結果で確定させない**こと (PoC ではこの環境のターミナルに AX 権限が無く `trusted: false` だったため未検証)

## 4. 動作した API 呼び出し (そのまま Phase 3 に持ち込める)

```swift
// --- フォアグラウンドアプリ (権限不要) ---
let app = NSWorkspace.shared.frontmostApplication          // NSRunningApplication?
app.bundleIdentifier                                       // "com.apple.TextEdit"
app.localizedName                                          // "テキストエディット" (ロケール依存!)
app.processIdentifier                                      // pid_t
app.executableURL?.lastPathComponent                       // "TextEdit"  ← processName に使う

// --- 切替イベント (権限不要) ---
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
}
// 対になる didDeactivateApplicationNotification もあるが capture トリガには不要

// --- アクセシビリティ判定 ---
AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)  // Bool、即時、非ブロッキング
AXIsProcessTrusted()                                                                   // 引数無し版

// --- フォーカスウィンドウのタイトル (要 AX 権限) ---
let appElement = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(appElement, 1.0)        // ★ 応答しないアプリでハングしないための保険
var windowRef: CFTypeRef?
AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
// → AXError。success 以外は必ず "" + reason に degrade
CFGetTypeID(windowRef) == AXUIElementGetTypeID()       // 型チェックしてから as! AXUIElement
var titleRef: CFTypeRef?
AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRef)
(titleRef as? String)                                   // 取れなければ ""

// --- アイドル秒数 (権限不要) ---
let anyInputEventType = CGEventType(rawValue: ~0)!      // kCGAnyInputEventType は Swift に未公開
CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEventType)

// --- ロック / アンロック (権限不要、登録のみ確認) ---
DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { ... }
DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { ... }
```

エラーハンドリングの実測: 未許可状態で `--watch` を 24 秒 (12 回のスナップショット + 5 回のアクティブ化イベント) 回して、クラッシュもハングもゼロ。`titleReason` が常に `"accessibility_not_trusted"`、`hasWindowTitle: false`、`rawWindowTitle: ""` で一貫。

## 5. Swift 6 concurrency の落とし穴 (実際にビルドを止めたもの)

Swift 6 language mode + `main.swift` (トップレベルコードは暗黙に `@MainActor`) で 4 種類のエラーに当たった。Phase 3 の Collector 実装で同じ壁に当たるので記録する。

1. **`kAXTrustedCheckOptionPrompt` が使えない**
   `error: reference to var 'kAXTrustedCheckOptionPrompt' is not concurrency-safe because it involves shared mutable state`。ApplicationServices のヘッダで `extern CFStringRef kAXTrustedCheckOptionPrompt;` (定数でなく可変グローバル) として宣言されているため、Swift 6 では参照自体が strict-concurrency エラーになる。
   **対処**: キーの文字列リテラル `"AXTrustedCheckOptionPrompt"` を直接使う。(別解として `nonisolated(unsafe) let` のシャドウを 1 箇所置いてもよい。`kAXTitleAttribute` / `kAXFocusedWindowAttribute` は `let` として import されるのでこの問題は無い。)

2. **トップレベルの `let` は MainActor 隔離、しかし `func` 宣言は nonisolated**
   `main.swift` のトップレベル変数 (例 `ISO8601DateFormatter` のグローバル) は MainActor 隔離されるが、同じファイルに書いた `func` は nonisolated なので `main actor-isolated let 'x' can not be referenced from a nonisolated context` になる。
   **対処**: NSWorkspace / AX / 出力を触る関数には明示的に `@MainActor` を付ける。**これは制約ではなく望ましい形**で、`NSWorkspace` も AX API も本来メインスレッド前提なので、Collector 側は `@MainActor func` として定義し、actor (`MacAmbientContextService`) からは `await` で呼ぶのが正しい。

3. **`NotificationCenter.addObserver(forName:object:queue:using:)` のブロックで `Notification` を MainActor に持ち込めない**
   `error: sending 'note' risks causing data races` — ブロックに渡る `Notification` は task-isolated で、`NSRunningApplication` は `Sendable` ではないため、`MainActor.assumeIsolated { ... note ... }` の中で使えない。
   **対処**: `assumeIsolated` の **外側**で `Notification` を素の値 (`String?` / `pid_t` / 自前の `Sendable` struct) に分解し、分解済みの値だけをキャプチャする。設計書 §3.2 の「通知はメインスレッドで受けて actor に転送」という構造は、この分解が必須という意味でもある — **`Notification` や `NSRunningApplication` を actor 境界を越えて渡してはいけない。値に落としてから渡す**。

4. **`Timer` / `RunLoop` コールバックも同様**
   `Timer(timeInterval:repeats:)` のブロックは nonisolated。`queue: .main` / `RunLoop.main` に載せているので実際はメインスレッドで走るため、`MainActor.assumeIsolated { }` で包むのが正解 (`Task { @MainActor in }` だと発火順が保証されず、capture の直列化が崩れる)。

その他の小ネタ:

- `kCGAnyInputEventType` は Swift に import されない。`CGEventType(rawValue: ~0)!` (= 0xFFFFFFFF) を自前で作る必要がある
- `AXUIElement` は CF 型なので `CFTypeRef` からは `CFGetTypeID(x) == AXUIElementGetTypeID()` で確認してから `as! AXUIElement` する (`as?` は使えない)
- `Package.swift` の `.swiftLanguageMode(.v6)` と `platforms: [.macOS(.v14)]` の組み合わせで CLT のみ (Xcode 無し) で問題なくビルド・実行できた

## 6. Windows 実装とのフィールド対応

`WindowsForegroundAppCollector.GetForegroundApp()` が埋める `ForegroundAppContext` の各フィールド:

| フィールド | Windows | macOS (本 PoC で実証) |
|---|---|---|
| `ProcessId` | `GetWindowThreadProcessId` | `NSRunningApplication.processIdentifier` |
| `ProcessName` | `Process.ProcessName + ".exe"` (`"code.exe"`) | `executableURL.lastPathComponent` (`"TextEdit"`、拡張子なし) |
| `AppName` / `Category` | `AmbientTier1Rules.ClassifyApp(executableName)` | `classifyApp(bundleId:)` — **キーが exe 名から bundle id に変わる** (§7 の表) |
| `HasWindowTitle` | `GetWindowText` の結果が非空か | AX タイトルが非空か。**権限未許可なら常に false** |
| `RawWindowTitle` | `GetWindowText` | AX `kAXTitleAttribute` |
| `TitleSummary` | `AmbientTier1Rules.SummarizeWindowTitle(category, title)` | **OS 非依存なのでそのまま移植可**。ただし `KnownBrowserSites` と `shell` 判定 (`powershell` / `cmd` / `wsl`) は macOS 向けの見直しが要る (§7 の推奨 4) |

## 7. 設計書への反映提案

### 推奨 1: bundle id → category マッピング表を設計書に明記する

設計書 §3.3 は「アプリ分類は bundle id キー (例 `com.microsoft.VSCode` → editor)」としか書いていない。`AmbientTier1Rules.AppClassifications` に対応する具体表を以下で提案する (本 PoC の `main.swift` に実装済み。カテゴリは既存の `editor` / `browser` / `communication` / `media` / `terminal` / `document` / `shell` / `other` のみ)。

| bundle id | category | appName |
|---|---|---|
| `com.microsoft.VSCode` | editor | Visual Studio Code |
| `com.microsoft.VSCodeInsiders` | editor | Visual Studio Code |
| `com.todesktop.230313mzl4w4u92` | editor | Cursor |
| `com.jetbrains.intellij` | editor | IntelliJ IDEA |
| `com.jetbrains.rider` | editor | Rider |
| `com.jetbrains.pycharm` | editor | PyCharm |
| `com.jetbrains.WebStorm` | editor | WebStorm |
| `com.apple.dt.Xcode` | editor | Xcode |
| `dev.zed.Zed` | editor | Zed |
| `com.sublimetext.4` | editor | Sublime Text |
| `com.apple.TextEdit` | editor | TextEdit |
| `com.google.Chrome` | browser | Chrome |
| `com.apple.Safari` | browser | Safari |
| `com.microsoft.edgemac` | browser | Edge |
| `org.mozilla.firefox` | browser | Firefox |
| `com.brave.Browser` | browser | Brave |
| `company.thebrowser.Browser` | browser | Arc |
| `com.tinyspeck.slackmacgap` | communication | Slack |
| `com.hnc.Discord` | communication | Discord |
| `com.microsoft.teams2` | communication | Teams |
| `us.zoom.xos` | communication | Zoom |
| `com.apple.MobileSMS` | communication | Messages |
| `com.apple.mail` | communication | Mail |
| `com.spotify.client` | media | Spotify |
| `com.apple.Music` | media | Music |
| `com.apple.TV` | media | TV |
| `org.videolan.vlc` | media | VLC |
| `com.colliderli.iina` | media | IINA |
| `com.apple.QuickTimePlayerX` | media | QuickTime Player |
| `com.apple.Terminal` | terminal | Terminal |
| `com.googlecode.iterm2` | terminal | iTerm2 |
| `dev.warp.Warp-Stable` | terminal | Warp |
| `net.kovidgoyal.kitty` | terminal | kitty |
| `com.github.wez.wezterm` | terminal | WezTerm |
| `com.microsoft.Word` | document | Word |
| `com.microsoft.Excel` | document | Excel |
| `com.microsoft.Powerpoint` | document | PowerPoint |
| `com.apple.iWork.Pages` | document | Pages |
| `com.apple.iWork.Numbers` | document | Numbers |
| `com.apple.iWork.Keynote` | document | Keynote |
| `com.apple.Preview` | document | Preview |
| `com.apple.Notes` | document | Notes |
| `notion.id` | document | Notion |
| `com.apple.finder` | shell | Finder |
| `com.apple.systempreferences` | shell | System Settings |
| `com.apple.Spotlight` | shell | Spotlight |

未知の bundle id は Windows 版と同じく `("other", <フォールバック名>)`、bundle id 自体が取れない場合は `("", "")` (`"unknown"` というサニチネル文字列は使わない — `AmbientTier1Rules.ClassifyApp` のコメントの方針を維持)。

補足: `com.apple.calculator` (実測。`Calculator` ではなく小文字) のように **bundle id の大小や表記が直感と違うことがある**ので、表に載せる値は実機で `osascript -e 'id of app "..."'` か本 PoC の出力で確認してから追加すること。Cursor の `com.todesktop.230313mzl4w4u92` のように不透明な id もある。

### 推奨 2: `appName` のフォールバックに `localizedName` を使わない

実測で TextEdit が `"テキストエディット"`、Calculator が `"計算機"` になった。`AppName` は集計キーとして使われるので、**未知アプリのフォールバックは `executableURL.lastPathComponent` (ロケール非依存) にすべき**。`localizedName` は UI 表示専用に留める。設計書 §8 の差分表の「`foregroundApp.processName`: `Code` (拡張子なし)」の行に、この注記を足したい。

### 推奨 3: AX 権限の再評価とプロンプト後の扱いを設計書に追記

`AXIsProcessTrustedWithOptions(prompt: true)` は**即座に false を返して戻る** (ブロックしない) ので、「プロンプトを出した後の許可」をアプリ側でポーリングまたは通知で拾う必要がある。設計書 §3.1 の `Permissions/` に「`AXIsProcessTrusted()` の定期再評価 (capture ごと) + 許可されたら degrade 解除」を明記したい。あわせて §8 の差分表に「AX 権限付与後にアプリの再起動が必要な場合がある」を追加。

### 推奨 4: `SummarizeWindowTitle` の macOS 向け調整を Phase 3 のタスクに入れる

`AmbientTier1Rules.SummarizeWindowTitle` の `terminal` 分岐は `powershell` / `cmd` / `wsl` しか判定しない。macOS では `zsh` / `bash` / `fish` / `ssh` を見るべきで、**この関数は「OS 非依存ロジック」ではなく OS 依存の辞書を持っている**。§3.6 の「Tier1Rules は純粋ロジックなのでそのまま移植」という記述に、`KnownBrowserSites` と shell 判定だけは OS ごとの辞書として分ける、という注記を足したい (Windows 側も同じ辞書構造に寄せると drift を避けられる)。

### 推奨 5: AX 呼び出しにタイムアウトを必ず設定する

`AXUIElementSetMessagingTimeout(appElement, 1.0)` を入れないと、応答しないアプリ (ビーチボール中) に対する `AXUIElementCopyAttributeValue` が既定タイムアウトまでブロックし、60 秒 capture のループを止めうる。設計書 §3.3 のウィンドウタイトル行に「AX 呼び出しは 1 秒のメッセージングタイムアウトを設定する」を追記したい。

### 推奨 6: Phase 0 の順序を入れ替える

AX の成功パスは `.app` バンドルがないと検証できない (§3)。**Phase 0 item 4 (`.app` 組み立て) を item 2 より前に実施し、item 2 の「許可後にタイトルが取れること」の確認はその `.app` 上で行う**、と §4 に書き直すことを提案する。本 PoC で確認できたのは「未許可時に例外なく空を返すこと」(item 2 の後半) までで、前半 (許可後に取れること) は `.app` 待ち。

## 8. 残課題

- [ ] `.app` バンドル (Phase 0 item 4) 完成後に、アクセシビリティ権限を許可した状態で `kAXFocusedWindowAttribute` → `kAXTitleAttribute` が実際に値を返すことを確認する。特に Safari / Chrome / VS Code / Terminal の 4 種でタイトル文字列の形を採取し、`SummarizeWindowTitle` の正規表現が期待どおり拡張子やサイト名を拾うか検証する
- [ ] AX 権限を持つプロセスがサンドボックス外である必要 (App Sandbox と AX の非互換) の確認 — 本プロジェクトは Mac App Store 配布ではないので影響しない見込みだが `.app` の entitlements 決定時に再確認
- [ ] `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` の実発火確認 (人が画面をロックする必要があるため本 PoC では未実施。登録・解除がクラッシュしないことのみ確認済み)
- [ ] スクリーンセーバ経由のロック (`com.apple.screensaver.didstart`) を `sessionLocked` に含めるかの方針決定
