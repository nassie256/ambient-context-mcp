# Ambient Context MCP

[![MCP](https://img.shields.io/badge/MCP-server-1f6feb?logo=anthropic&logoColor=white)](https://modelcontextprotocol.io)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-0078d6)](#必要環境)
[![.NET](https://img.shields.io/badge/.NET-8.0-512bd4?logo=dotnet&logoColor=white)](https://dotnet.microsoft.com)
[![Swift](https://img.shields.io/badge/Swift-6-fa7343?logo=swift&logoColor=white)](https://swift.org)
[![Release](https://img.shields.io/github/v/release/nassie256/ambient-context-mcp?logo=github&logoColor=white)](https://github.com/nassie256/ambient-context-mcp/releases)
[![License: MIT](https://img.shields.io/github/license/nassie256/ambient-context-mcp)](LICENSE)

[en](README.en.md) | **ja**

Windows / macOS のローカル ambient context (在席状態、フォアグラウンドアプリ種別、バッテリ、電源イベント、システム負荷、長時間作業の検知など) を、プライバシー分類された MCP ツールとして任意の AI クライアント (Claude Code、Claude Desktop 等) に公開する常駐プロセスです (Windows はタスクトレイ、macOS はメニューバー)。

> スクリーンショットは Windows 版のものです。macOS 版 (メニューバー常駐、Swift ネイティブ) は同じ MCP 契約・同じ設定スキーマで動作します。差分は [macOS の機能差](#macos-の機能差) を参照してください。

<p align="center">
  <img src="screenshot1.png" alt="MCP サーバ設定タブ" width="45%" />
  <img src="screenshot2.png" alt="送信設定タブ" width="45%" />
</p>

## 特徴

- **ローカル完結**: 127.0.0.1 のみで待ち受け、外部送信は一切なし
- **既定 OFF**: 機微度 medium / high の情報は明示的に opt-in しない限り送信されない
- **小さいフットプリント**: タスクトレイ / メニューバー常駐の単一プロセス
- **クロスプラットフォーム**: Windows (WinUI 3 / .NET 8) と macOS (Swift 6 / AppKit) のネイティブ実装。ツール契約・設定スキーマ・プライバシー分類は共通
- **MCP Streamable HTTP**: `http://127.0.0.1:37690/mcp` で公開、Bearer トークン必須
- **プライバシー診断ツール**: `ambient_context_get_policy` で「なぜこの値が出力されないか」をクライアントから自己診断可能

## 公開する 4 ツール

| ツール | 説明 |
|---|---|
| `ambient_context_get_states` | 現在のコンテキスト状態 (presence, battery, フォアグラウンドアプリ種別 等) |
| `ambient_context_poll_events` | クライアント別カーソル以降の未読イベント (user_returned, ac_power_connected 等) |
| `ambient_context_describe_events` | 全イベントの payload スキーマカタログ (sensitivity / 説明 / 例値、実データは含まない) |
| `ambient_context_get_policy` | 機微度分類と有効送信可否の診断情報 (実データは含まない) |

## クイックスタート

### A. Claude Desktop (MCPB バンドル) — Windows / macOS 共通

[Releases](https://github.com/nassie256/ambient-context-mcp/releases) から `ambient-context-mcp-vX.Y.Z.mcpb` をダウンロードし、Claude Desktop の設定 → 拡張機能 からインストールしてください。`.mcpb` は Windows / macOS の両方を同梱した 1 ファイルで、OS に応じた stdio ブリッジが自動的に選ばれます。インストール後、Claude Desktop が本体を自動 spawn してツールが使えるようになります。

> 本体は単一 LocalContextHub を保つために 1 プロセスのみ常駐します。MCPB は未起動時のみ spawn し、起動済みなら既存のプロセスにぶら下がります。

> **macOS の注意**: 同梱アプリは ad-hoc 署名 (Apple Developer Program 未加入) のため、初回のみ Gatekeeper に許可を与える必要があります。ツールが応答しない場合は、システム設定 → プライバシーとセキュリティ の「このまま開く」を押してください。

> **アップデート時の注意 (macOS)**: ad-hoc 署名では designated requirement が cdhash だけになるため、アプリを更新すると**アクセシビリティ / オートメーションの許可が無効化されます**。しかも再プロンプトは出ないので、権限が必要な context (ウィンドウタイトル / メディア) が黙って空になります。更新後は システム設定 → プライバシーとセキュリティ → アクセシビリティ / オートメーション で古いエントリを **削除してから追加し直して** ください。Developer ID 署名にすれば解消しますが、現状は使用していません。

### B. Claude Code / その他クライアント (Streamable HTTP)

#### Windows

アーカイブ版 (`ambient-context-mcp-vX.Y.Z-win-x64.zip`) を展開し、`ambient-mcp.exe` を実行してください。

1. アプリ起動 → タスクトレイに `[●] Ambient Context MCP — :37690` が表示
2. トレイクリック → 設定ダイアログが開く
3. 「送信設定」タブで公開して構わない context にチェック → 保存
4. トレイメニュー → 「Claude Code 用設定をコピー」
5. 任意のターミナルでペースト

```cmd
claude mcp add ambient-context \
  --transport http http://127.0.0.1:37690/mcp \
  --header "Authorization: Bearer <TOKEN>"
```

6. Claude Code から `ambient_context_get_states` などが呼べます

#### macOS

`ambient-context-mcp-vX.Y.Z-macos-universal.zip` (または `.dmg`) をダウンロードします (リリースは universal binary。`scripts/package-release.sh --arch arm64` などで自作した場合はファイル名の `universal` がそのアーキ名になります)。

1. 展開して **`Ambient Context MCP.app` を先に `/Applications` へ移動**します
   (移動せずに開くと App Translocation により読み取り専用の一時パスで実行され、discovery ファイルやログイン項目のパスが壊れます)
2. **初回起動**: ad-hoc 署名で公証もしていないため、そのままでは Gatekeeper にブロックされます。いずれかを実行してください
   - Finder で一度開こうとしてから、システム設定 → プライバシーとセキュリティ → 「このまま開く」を押す
   - もしくはターミナルで quarantine 属性を外す (`-r` は必須):
     ```bash
     xattr -d -r com.apple.quarantine "/Applications/Ambient Context MCP.app"
     ```
   > macOS 15 以降は「右クリック → 開く」では回避できません。上記のどちらかが必要です。
3. 起動 → メニューバーに Ambient Context MCP のアイコンが表示されます
4. アイコンを **左クリック** → 設定ウィンドウ。「送信設定」タブで公開して構わない context にチェック → 保存
5. アイコンを **右クリック** → 「Claude Code 用設定をコピー」
6. 任意のターミナルでペースト

```bash
claude mcp add ambient-context \
  --transport http http://127.0.0.1:37690/mcp \
  --header "Authorization: Bearer <TOKEN>"
```

7. ウィンドウタイトル / メディアのコンテキストを ON にすると、**アクセシビリティ** / **オートメーション** の権限を求められます。許可しなくてもクラッシュせず、該当項目が空になるだけです (詳細は [docs/macos-implementation.md](docs/macos-implementation.md))

## macOS の機能差

Windows 版と macOS 版は同じ MCP 契約を提供しますが、OS の API 差により次の点が異なります。

| 項目 | Windows | macOS |
|---|---|---|
| メディアセッション | 全 SMTC 対応アプリ (ブラウザ含む) | Music.app / Spotify のみ (Apple Events、要オートメーション権限)。ブラウザ再生は取得不可 |
| ウィンドウタイトル | 権限不要 | 要アクセシビリティ権限 |
| `system_resume_automatic` | 発火する | 発火しない (常に `system_resume_user`) |
| `system.timeZoneId` の値 | Windows 名 (`Tokyo Standard Time`) | IANA 名 (`Asia/Tokyo`) |
| `foregroundApp.processName` | `code.exe` | `Code` (拡張子なし)。アプリ分類は bundle id で行う |
| `network.interfaceKinds` | 常に空 | wifi / wired / cellular を返せる |
| メディアの `albumArtist` / `trackNumber` / `genres` | 取得可 | 取得不可 (空 / 0) |
| 設定ウィンドウ表示中 | Dock アイコンなし | Dock にアイコンが出る (ウィンドウを閉じると消える。Accessibility API から到達可能にするため) |
| 未署名配布 | SmartScreen 警告 | Gatekeeper でブロック (macOS 15 以降は右クリック → 開くも不可)。`/Applications` へ移動後に「このまま開く」または quarantine 属性の削除が必要 |
| 更新時の権限 | 維持される | ad-hoc 署名のため cdhash が変わり、アクセシビリティ / オートメーションの許可が無効化される (再プロンプト無し)。システム設定で削除 → 再追加が必要 |

## ドキュメント

- [docs/tool-spec.md](docs/tool-spec.md) - MCP ツール契約 (Input/Output、scope、認証)
- [docs/privacy-classifications.md](docs/privacy-classifications.md) - 既定送信ポリシー一覧
- [docs/client-config.md](docs/client-config.md) - Claude Code/Desktop 設定例
- [docs/windows-implementation.md](docs/windows-implementation.md) - Windows 固有の実装メモ
- [docs/macos-implementation.md](docs/macos-implementation.md) - macOS 固有の実装メモ

## 必要環境

### Windows

- Windows 10 version 2004 (10.0.19041, May 2020 Update) 以降
- .NET 8 ランタイム + ASP.NET Core 8 ランタイム x64 (framework-dependent 配布版の場合)
- Windows App Runtime 1.8 x64 — 初回起動時に未導入なら案内され、[ダウンロードページ](https://aka.ms/windowsappsdk/1.8/latest/windowsappruntimeinstall-x64.exe) へ誘導されます

### macOS

- macOS 14 Sonoma 以降
- Apple Silicon / Intel (Universal バイナリ。ランタイムの追加インストールは不要)
- 任意: ウィンドウタイトルにはアクセシビリティ権限、メディア情報にはオートメーション権限 (該当オプションを ON にしたときだけ要求されます)

## ビルド

### Windows

```powershell
# 開発ビルド
dotnet build src\windows\AmbientContextMcp.sln

# リリース成果物 (zip + .mcpb の両方を出力)
pwsh tools\build-release.ps1                  # version は mcpb/manifest.json から
pwsh tools\build-release.ps1 -Version 0.4.0   # 明示指定
pwsh tools\build-release.ps1 -SkipZip         # mcpb のみ
pwsh tools\build-release.ps1 -SkipMcpb        # zip のみ
```

`mcpb validate` を有効にするには `npm i -g @anthropic-ai/mcpb` を先に入れてください。未インストール時は `Compress-Archive` フォールバックで `.mcpb` を作ります (manifest 検証はスキップ)。

### macOS

Xcode は不要で、Command Line Tools (`xcode-select --install`) だけでビルドできます。

```bash
cd src/macos

# 開発ビルド
swift build

# テスト (CLT のみの環境では Testing.framework の探索パスを足すラッパを使う)
scripts/run-tests.sh

# リリース成果物 (.app + stdio ブリッジ → zip + dmg)
scripts/package-release.sh                      # version は mcpb/manifest.json から
scripts/package-release.sh --version 0.8.0
scripts/build-app.sh --arch arm64               # .app だけを素早く作る (ローカル確認用)
```

`.mcpb` は Windows / macOS 両方のバイナリを含む 1 ファイルなので、片方の OS だけでは作れません。CI が両ランナーの成果物を集めて `src/macos/scripts/assemble-mcpb.sh` で結合します。手元で試す場合:

```bash
src/macos/scripts/assemble-mcpb.sh \
  --win-server dist/win-server \
  --mac-server dist/macos
```

配布物は ad-hoc 署名 (`codesign -s -`) で、公証は行いません。そのため `spctl -a -t exec` は `rejected` を返しますが、これは想定どおりです。

## ファイル配置

Windows:

```
%LOCALAPPDATA%\AmbientContextMcp\
├── settings.json          # ユーザー設定 (送信オプトイン、ポート、トークン)
├── ambient-context.json   # 直近 snapshot のローカルキャッシュ (デバッグ用)
├── events.jsonl           # イベント履歴 (永続化を有効にした場合のみ)
└── mcp-api.json           # 起動中 MCP の discovery 情報 (終了時に削除)
```

macOS (ファイル名と JSON スキーマは Windows と同一):

```
~/Library/Application Support/AmbientContextMcp/
├── settings.json
├── ambient-context.json
├── events.jsonl
└── mcp-api.json
```

## ライセンス

[MIT](LICENSE)
