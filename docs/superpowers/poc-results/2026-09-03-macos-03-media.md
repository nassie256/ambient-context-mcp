# Phase 0 PoC #3: メディアコンテキスト (Apple Events / AppleScript)

対象: 設計書 `docs/superpowers/specs/2026-09-03-macos-port-design.md` §3.4 / §4 Phase 0-3

検証環境: macOS 26.6 (arm64), Swift 6.3.3 (Command Line Tools only, Xcode なし), SwiftPM `.macOS(.v14)`

実行方法:

```
cd src/macos/poc/03-media
swift run media-poc                      # プレイヤーごとに JSON を 1 行出力
swift run media-poc -- --bench           # 同一プロセス内の連続呼び出しコスト
swift run media-poc -- --selftest-timeout  # タイムアウトガードの自己検証
MEDIA_POC_TIMEOUT_MS=30000 swift run media-poc  # デバッグ用にガードを延長
```

## 1. 結論 (先に要約)

- **Apple Events 方式は成立する。** Music.app / Spotify の両方から `player state` / `name` / `artist` / `album` / `player position` / `duration` を実測で取得できた。Windows の `MediaContext` / `MediaSessionContext` の必要フィールドは `albumArtist` / `trackNumber` / `genres` / `startTimeMilliseconds` / `timelineLastUpdatedAt` を除いてすべて埋まる。
- **`NSRunningApplication` による事前チェックは必須。** これが無いと `tell application "Music"` が Music.app を**起動してしまう**。PoC では `runningApplications(withBundleIdentifier:)` が空なら Apple Event を一切送らない。
- **1500 ms のタイムアウトガードは実際に必要だった。** Spotify 起動直後、Apple Event が 20 秒以上応答しない状態を実測した (後述 §4)。Windows 版と同じ 1500 ms でガードし、超えたら「メディア不明」として続行するのが正しい。
- **`MPNowPlayingInfoCenter` / MediaPlayer.framework は使えない** (§6)。
- **オートメーション権限は `.app` バンドルでの再検証が必須。** bare binary では TCC の帰責プロセス (responsible process) が親ターミナルになるため、本番の挙動を再現できない (§5)。

## 2. 出力サンプル (実測、raw)

曲名・アーティストはユーザの実際の再生履歴なのでリポジトリには残さず `<TITLE>` / `<ARTIST>` / `<ALBUM>` に置換している。それ以外の値・桁数は実測そのまま。

### 2.1 両プレイヤーとも未起動

```json
{"albumTitle":"","artist":"","elapsedMilliseconds":0,"error":"player not running","isAvailable":false,"isRunning":false,"playbackStatus":"unknown","sourceAppUserModelId":"com.apple.Music","sourceKind":"music","title":""}
{"albumTitle":"","artist":"","elapsedMilliseconds":0,"error":"player not running","isAvailable":false,"isRunning":false,"playbackStatus":"unknown","sourceAppUserModelId":"com.spotify.client","sourceKind":"music","title":""}
```

Apple Event は 1 回も送っていない (`elapsedMilliseconds: 0`)。プレイヤーが起動していない環境では権限プロンプトも一切出ない。

### 2.2 Music.app 起動済み・トラック未ロード

```json
{"albumTitle":"","artist":"","elapsedMilliseconds":146,"error":"","isAvailable":true,"isPlaying":false,"isRunning":true,"playbackStatus":"Stopped","sourceAppUserModelId":"com.apple.Music","sourceKind":"music","title":""}
```

`player state` は `stopped` が取れるが `current track` は存在しない。スクリプト内の `try` ブロックで握りつぶし、`playbackStatus="Stopped"` + 空メタデータを返している。

### 2.3 Spotify 再生中

```json
{"albumTitle":"<ALBUM>","artist":"<ARTIST>","elapsedMilliseconds":128,"endTimeMilliseconds":435253,"error":"","isAvailable":true,"isPlaying":true,"isRunning":true,"playbackStatus":"Playing","positionMilliseconds":260675,"sourceAppUserModelId":"com.spotify.client","sourceKind":"music","title":"<TITLE>"}
```

### 2.4 Spotify 一時停止

```json
{"albumTitle":"<ALBUM>","artist":"<ARTIST>","elapsedMilliseconds":112,"endTimeMilliseconds":435253,"error":"","isAvailable":true,"isPlaying":false,"isRunning":true,"playbackStatus":"Paused","positionMilliseconds":280310,"sourceAppUserModelId":"com.spotify.client","sourceKind":"music","title":"<TITLE>"}
```

### 2.5 タイムアウトガード自己検証

```json
{"selftest":"timeout","timedOut":true,"elapsedMilliseconds":1505}
```

`delay 5` の AppleScript を投げても呼び出し側は 1505 ms で復帰する。

## 3. 観測したエラーコード

| コード | 状況 | 本実装での扱い |
| --- | --- | --- |
| `-1728` (`errAENoSuchObject`) | 起動済みだが `current track` が無い。素の 1 行スクリプト `tell application "Music" to get {..., name of current track, ...}` で実測: `Musicでエラーが起きました: name of current trackを取り出すことはできません。 (-1728)` | スクリプト内 `try` で回避し、`player state` だけ返す。`try` を使わない経路のフォールバックとして `-1728` → `isAvailable=true` / `playbackStatus="Stopped"` にマップ |
| `-2741` (構文エラー) | **PoC 中に踏んだ罠。** `tell application "Music"` ブロック内で `set st to ...` / `set td to ...` のような 2 文字変数名を使うと、対象アプリの用語辞書と衝突して `Expected expression but found "st"` でコンパイル失敗する | 変数名を `playerStateText` / `trackDuration` のように長くする。**設計書に記録すべき実装上の注意点** |
| `-1743` (`errAEEventNotPermitted`) | オートメーション権限拒否 | コードでハンドリング済み (明示的な reason 文字列 + System Settings 誘導文言)。**本 PoC では実際には発生させられなかった** — 検証機ではターミナル (帰責プロセス) が既に Music / Spotify へのオートメーション権限を保持しており、拒否状態を作るにはユーザが System Settings で手動 OFF にする必要がある。エージェントはプロンプトをクリックできないため未検証 |
| `-600` / `-609` / `-1712` | プロセス非接続 / Apple Event タイムアウト | 個別の reason 文字列にマップ済み |
| (タイムアウト) | Spotify 起動直後、20 秒以上 Apple Event に応答しない状態を実測 | 1500 ms ガードで `error: "AppleScript timed out after 1500 ms"` として続行 |

## 4. タイミング実測 (ms)

`--bench` (同一プロセス内で 5 連続実行、両アプリ起動済み・Spotify 再生中):

```json
{"bench":"com.apple.Music","elapsedMillisecondsSamples":[115, 27, 33, 33, 33]}
{"bench":"com.spotify.client","elapsedMillisecondsSamples":[116, 120, 112, 116, 135]}
```

- 初回は用語辞書取得 (`ascr/gdte`) を含むため 110〜150 ms。
- Music.app は 2 回目以降 **約 30 ms**。Spotify は毎回 **110〜135 ms** (Spotify 側の Apple Event ハンドラが遅い)。
- プロセス起動込みの `swift run` 相当 (cold) は 5 回計測で 131 / 117 / 117 / 120 / 116 ms。
- **60 秒周期の capture ループなら 2 プレイヤー合計で最悪 ~270 ms、タイムアウト時は最悪 3000 ms (1500 ms × 2)。** 許容範囲だが、Windows と同様「メディアだけ別タスクで先行取得」もしくは逐次実行で十分。

### 起動直後のハングを実測

`open -a Spotify` 直後、以下が **30 秒以上にわたり再現**した:

```json
{"albumTitle":"","artist":"","elapsedMilliseconds":1505,"error":"AppleScript timed out after 1500 ms","isAvailable":false,"isRunning":true,"playbackStatus":"unknown","sourceAppUserModelId":"com.spotify.client","sourceKind":"music","title":""}
```

同時刻に `osascript -e 'tell application "Spotify" to get player state as text'` は即座に `stopped` を返した。つまり**単純な TCC プロンプト待ちではなく、Spotify 側が特定の Apple Event (6 プロパティ取得スクリプトのコンパイル/実行) を長時間ブロックしていた**可能性が高い。原因は特定できていないが、**「起動済み ≠ 応答する」ことの実証**であり、タイムアウトガードの必要性の直接的な根拠になる。その後 Spotify が完全に起動しきると 110〜135 ms で安定した。

## 5. オートメーション権限 (TCC) の実際

### bare binary (`swift run`) の場合

- 生成されるのは `.build/debug/media-poc` の**単体 Mach-O (ad-hoc 署名, `Identifier=media-poc-<hash>`)** で `.app` バンドルではない。したがって **`NSAppleEventsUsageDescription` を Info.plist に宣言できない**。
- 実測では **オートメーションのプロンプトは一切表示されず、Apple Event はそのまま通った**。これは TCC がバンドルを持たない子プロセスについて**帰責プロセス (responsible process) = 起動元のターミナルアプリ**に権限を帰属させるため。検証機のターミナルは既に Music / Spotify へのオートメーション権限を持っていたので、その権限が bare binary に「継承」された形になる。
- したがって **bare binary での検証は本番の権限挙動を再現しない**。「プロンプトが出るか / 無言で拒否されるか」は `.app` バンドルでしか判定できない。
- なお、帰責プロセスに権限が無い場合の一般的な挙動は「そのターミナルアプリ名でプロンプトが出る」か、`NSAppleEventsUsageDescription` を持たないクライアントでは**プロンプトなしで即 `-1743`**。今回の環境では権限が既にあったため、この分岐は**未検証**。エージェントは TCC ダイアログをクリックできないため、ここは人手での確認が必要。

### 本番 `.app` バンドルで期待されるフロー

1. `Info.plist` に `NSAppleEventsUsageDescription` (日本語/英語のローカライズ文字列) を宣言する。**未宣言だとプロンプトすら出ずに `-1743` で即失敗する。**
2. アプリ署名は Developer ID + notarize。TCC の許可はコード署名 ID に紐づくため、**署名 ID を変えると許可がリセットされる** (Phase 5 の配布で要注意)。
3. `media.*` の opt-in を ON にした最初の Apple Event 送信時に、`(App 名) が Music を制御する許可を求めています` プロンプトが 1 回だけ出る。ここでユーザが「許可しない」を選ぶと以後は**プロンプトなしで `-1743`**。
4. 復旧導線は **システム設定 → プライバシーとセキュリティ → オートメーション → (App 名) → Music / Spotify のトグル**。設計書 §4 Phase 4 の「権限誘導シート」から `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation` で直接開ける。
5. アプリ側は `-1743` を検出したら `media.isAvailable=false` + reason を返し、UI で上記導線を提示する。**プロンプトを能動的に出す API は無い** (Accessibility の `AXIsProcessTrustedWithOptions` に相当するものが Apple Events には無い) ので、「1 回 Apple Event を投げてみる」以外の権限確認手段は無い。

## 6. `MPNowPlayingInfoCenter` / MediaPlayer.framework の評価

SDK ヘッダ (`$(xcrun --show-sdk-path)/System/Library/Frameworks/MediaPlayer.framework/Headers`) を直接確認した結論として、**MediaPlayer.framework では他アプリの now-playing 情報を読めない**。`MPNowPlayingInfoCenter` のヘッダには "The default center holds now playing info about the **current application**" と明記されており、`nowPlayingInfo` / `playbackState` はいずれも**自プロセスが発行する側**のプロパティである (read/write だが読めるのは自分が直前に書いた値だけ)。システム全体のセッションを列挙する API は存在しない。`MPMusicPlayerController` (iOS の Music アプリを制御する唯一の候補) はヘッダで `API_UNAVAILABLE(watchos, macos)` とされ macOS では使えず、`MPNowPlayingSession` も `MP_UNAVAILABLE_BEGIN(watchos, macos)` で macOS 非対応。`MPRemoteCommandCenter` も自アプリ宛のコマンド受信用。よって macOS 14+ において SMTC 相当の読み取りは MediaPlayer.framework 経由では**不可能**であり、設計書 §3.4 の前提 (公開 API 無し / MediaRemote は private) は正しい。

## 7. 設計書 §3.4 への反映提案

### 7.1 §3.4 本文への追記

Phase 3 の既定 (Apple Events) は**成立**。以下を明記すること。

1. **取得できるフィールド**: `isAvailable` / `sourceAppUserModelId` (= bundle id) / `playbackStatus` / `isPlaying` / `title` / `artist` / `albumTitle` / `positionMilliseconds` / `endTimeMilliseconds`。
   **取得できないフィールド**: `albumArtist` / `trackNumber` / `genres` / `startTimeMilliseconds` / `timelineLastUpdatedAt`。
   - `albumArtist` は Music.app のみ `album artist of current track` で取得可 (Spotify の辞書には無い)。`trackNumber` / `genres` も Music のみ。**プレイヤー間で差が出るフィールドは既定で空にし、Windows と同じ JSON 形状を保つ**のが安全。
   - `startTimeMilliseconds` は常に `0` 相当、`timelineLastUpdatedAt` は取得時刻 (`Date()`) で代替する。
2. **単位の差**: Music.app の `duration of current track` は**秒 (Double)**、Spotify は**ミリ秒 (Integer)**。プレイヤーごとに換算を持つこと (PoC の `durationIsMilliseconds` フラグ)。`player position` は**両方とも秒**。
3. **`playbackStatus` の正規化**: AppleScript は `playing` / `paused` / `stopped` (Music はさらに `fast forwarding` / `rewinding`) を返す。Windows の SMTC 文字列に合わせて `Playing` / `Paused` / `Stopped` へ正規化し、それ以外は `unknown` とする。
4. **必ず `NSRunningApplication.runningApplications(withBundleIdentifier:)` で事前チェックする。** 未起動時に Apple Event を送るとプレイヤーが**起動してしまう**。これは仕様上の必須事項として設計書に書くこと。
5. **1500 ms タイムアウトガード (Windows 版と同値) を必須とする。** バックグラウンドスレッド + `DispatchSemaphore.wait(timeout:)` で実装し、超過時はスレッドを放棄して `media.isAvailable=false` + reason を返す。起動直後の Spotify で 20 秒超のブロックを実測している。
6. **AppleScript 変数名は 3 文字以上の非衝突名にする** (`st` / `td` 等は対象アプリの用語辞書と衝突し `-2741` でコンパイル失敗)。
7. **エラー → reason 文字列のマッピング**を Collector に持つ: `-1743` → 権限誘導、`-1728` → トラック未ロード、`-600` / `-609` → 非接続、`-1712` / タイムアウト → 応答なし。
8. **署名 ID を変更するとオートメーション許可がリセットされる**旨を Phase 5 (配布) の注意点に追記。

### 7.2 `MediaSourceKindClassifier` への追加 (bundle id 対応)

現行の Windows 実装は AUMID / exe 名の部分一致。macOS の bundle id は `com.spotify.client` / `com.apple.Music` のように**既存の `spotify` / `music` 部分一致で偶然当たるものもあるが、`com.apple.Music` は現行ルールだと `"music"` にマッチせず `unknown` になる** (現行は `applemusic` / `zunemusic` などの連結形しか見ていない)。以下を追加する。

```csharp
// video
lower.Contains("com.apple.tv")          // Apple TV.app
lower.Contains("org.videolan.vlc")      // 既存 "vlc" でも当たるが明示
lower.Contains("com.colliderli.iina")   // IINA
lower.Contains("io.mpv")                // 既存 "mpv" で当たる

// music
lower.Contains("com.apple.music")       // ★必須: Music.app
lower.Contains("com.apple.itunes")      // 旧 iTunes (既存 "itunes" で当たる)
lower.Contains("com.spotify.client")    // 既存 "spotify" で当たる
lower.Contains("com.apple.podcasts")    // Podcasts.app
lower.Contains("com.tidal")             // 既存 "tidal" で当たる

// browser
lower.Contains("com.apple.safari")      // ★必須: Safari
lower.Contains("com.google.chrome")     // 既存 "chrome" で当たる
lower.Contains("com.microsoft.edgemac") // ★必須 (Windows は "msedge")
lower.Contains("org.mozilla.firefox")   // 既存 "firefox" で当たる
lower.Contains("com.brave.browser")     // 既存 "brave" で当たる
lower.Contains("company.thebrowser.browser") // Arc (部分一致では拾えない)
```

**最小限の必須追加は `com.apple.music` / `com.apple.tv` / `com.apple.safari` / `com.microsoft.edgemac` / `com.apple.podcasts` / `company.thebrowser.browser` の 6 件**。残りは既存の部分一致ルールで既にカバーされる。分類器は Core (OS 非依存) にあるので **C# 側にも同じルールを入れて Swift と一致させ、`MediaSourceKindClassifierTests` にケースを追加する**こと (Phase 1 の契約テスト対象)。

### 7.3 README への明記事項 (既に §3.4-2 にあるが具体化)

- ブラウザ内再生 (YouTube / Apple Music Web / Netflix 等) は **一切取得できない**。macOS には SMTC が無く、ブラウザは Apple Events でトラック情報を公開しない。`media.isAvailable=false` になる。
- 対応プレイヤーは **Music.app と Spotify デスクトップアプリのみ**。
- **オートメーション権限が必要**で、拒否された場合の復旧はシステム設定から。

## 8. 実行時の副作用と後始末

- 検証のため `open -a Music` と `open -a Spotify` で両アプリを起動した。**Spotify は起動時に前回のキューを自動再生した** (こちらから `play` は送っていない)。
- 検証終了後、`osascript -e 'tell application "Spotify" to pause'` → `quit app "Spotify"` / `quit app "Music"` で**両アプリとも終了済み**。終了後の `media-poc` 出力が `"player not running"` × 2 であることを確認した。
- インストールは一切行っていない。`src/windows` と設計書は未変更。
