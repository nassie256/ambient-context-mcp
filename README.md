# Ambient Context MCP

[![MCP](https://img.shields.io/badge/MCP-server-1f6feb?logo=anthropic&logoColor=white)](https://modelcontextprotocol.io)
[![Platform](https://img.shields.io/badge/platform-Windows-0078d6?logo=windows&logoColor=white)](#必要環境)
[![.NET](https://img.shields.io/badge/.NET-8.0-512bd4?logo=dotnet&logoColor=white)](https://dotnet.microsoft.com)
[![Release](https://img.shields.io/github/v/release/nassie256/ambient-context-mcp?logo=github&logoColor=white)](https://github.com/nassie256/ambient-context-mcp/releases)
[![License: MIT](https://img.shields.io/github/license/nassie256/ambient-context-mcp)](LICENSE)

[en](README.en.md) | **ja**

Windows のローカル ambient context (在席状態、フォアグラウンドアプリ種別、バッテリ、電源イベント、システム負荷、長時間作業の検知など) を、プライバシー分類された MCP ツールとして任意の AI クライアント (Claude Code、Claude Desktop 等) に公開するトレイ常駐プロセスです。

## 特徴

- **ローカル完結**: 127.0.0.1 のみで待ち受け、外部送信は一切なし
- **既定 OFF**: 機微度 medium / high の情報は明示的に opt-in しない限り送信されない
- **小さいフットプリント**: タスクトレイ常駐の単一プロセス
- **MCP Streamable HTTP**: `http://127.0.0.1:37690/mcp` で公開、Bearer トークン必須
- **プライバシー診断ツール**: `ambient.context.get_policy` で「なぜこの値が出力されないか」をクライアントから自己診断可能

## 公開する 3 ツール

| ツール | 説明 |
|---|---|
| `ambient.context.get_states` | 現在のコンテキスト状態 (presence, battery, foreground app category 等) |
| `ambient.context.poll_events` | クライアント別カーソル以降の未読イベント (user_returned, ac_power_connected 等) |
| `ambient.context.get_policy` | 機微度分類と有効送信可否の診断情報 (実データは含まない) |

## クイックスタート

アーカイブの内容を展開し、ambient-mcp.exe を実行してください。

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

6. Claude Code から `ambient.context.get_states` などが呼べます

## ドキュメント

- [docs/tool-spec.md](docs/tool-spec.md) - MCP ツール契約 (Input/Output、scope、認証)
- [docs/privacy-classifications.md](docs/privacy-classifications.md) - 既定送信ポリシー一覧
- [docs/client-config.md](docs/client-config.md) - Claude Code/Desktop 設定例
- [docs/windows-implementation.md](docs/windows-implementation.md) - Windows 固有の実装メモ

## 必要環境

- Windows 10 1903 (10.0.18362) 以降
- .NET 8 Desktop Runtime x64 (framework-dependent 配布版の場合)

## ビルド

```powershell
# 開発ビルド
dotnet build src\windows\AmbientContextMcp.sln

# 配布用 (framework-dependent)
dotnet publish src\windows\AmbientContextMcp\AmbientContextMcp.csproj `
  -c Release -r win-x64 --self-contained false `
  -o dist\ambient-context-mcp-win-x64-fwd
```

## ファイル配置

```
%LOCALAPPDATA%\AmbientContextMcp\
├── settings.json          # ユーザー設定 (送信オプトイン、ポート、トークン)
├── ambient-context.json   # 直近 snapshot のローカルキャッシュ (デバッグ用)
└── mcp-api.json           # 起動中 MCP の discovery 情報 (終了時に削除)
```

## ライセンス

[MIT](LICENSE)
