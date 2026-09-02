# MCP クライアント設定例

Ambient Context MCP は Streamable HTTP transport で動作します。`http://127.0.0.1:37690/mcp` に Bearer トークン付きで接続してください。

## トークンの取得

トレイメニュー (Windows) / メニューバーの右クリックメニュー (macOS)、または設定ウィンドウから `Claude Code 用設定をコピー` 押下でクライアント設定コマンドが丸ごとクリップボードに入ります。

手動で取得する場合は設定ファイルの `mcpServer.token` を参照してください。

| OS | 設定ファイル |
|---|---|
| Windows | `%LOCALAPPDATA%\AmbientContextMcp\settings.json` |
| macOS | `~/Library/Application Support/AmbientContextMcp/settings.json` |

同じディレクトリに、起動中の MCP の discovery 情報 `mcp-api.json` (エンドポイントとトークン。終了時に削除) も置かれます。

```bash
# macOS: トークンだけを取り出す
python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/Library/Application Support/AmbientContextMcp/settings.json")))["mcpServer"]["token"])'
```

## Claude Code

```bash
claude mcp add ambient-context \
  --transport http http://127.0.0.1:37690/mcp \
  --header "Authorization: Bearer <TOKEN>"
```

接続確認:

```bash
claude mcp list
# ambient-context: http://127.0.0.1:37690/mcp (HTTP) - ✓ Connected
```

## Claude Desktop

設定ファイルの場所:

| OS | パス |
|---|---|
| Windows | `%APPDATA%\Claude\claude_desktop_config.json` |
| macOS | `~/Library/Application Support/Claude/claude_desktop_config.json` |

次を追加します:

```json
{
  "mcpServers": {
    "ambient-context": {
      "type": "http",
      "url": "http://127.0.0.1:37690/mcp",
      "headers": {
        "Authorization": "Bearer <TOKEN>"
      }
    }
  }
}
```

## その他 stdio クライアント

配布物には stdio→HTTP のブリッジ (`ambient-mcp-stdio.exe` / macOS は `ambient-mcp-stdio`) が同梱されています。`.mcpb` を Claude Desktop に入れる場合は自動的にこれが使われますが、任意の stdio クライアントから直接起動することもできます。ブリッジは discovery ファイルを読み、本体が未起動なら同じディレクトリの本体 (macOS では `Ambient Context MCP.app`) を spawn してから JSON-RPC を中継します。

## 利用例

ツール一覧の確認:

```bash
curl -X POST http://127.0.0.1:37690/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <TOKEN>" \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

現在の状態取得:

```bash
curl -X POST http://127.0.0.1:37690/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <TOKEN>" \
  --data '{
    "jsonrpc":"2.0","id":2,"method":"tools/call",
    "params":{"name":"ambient_context_get_states","arguments":{}}
  }'
```

ポリシー診断 (どの項目がなぜ送信されないかの説明):

```bash
curl -X POST http://127.0.0.1:37690/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Authorization: Bearer <TOKEN>" \
  --data '{
    "jsonrpc":"2.0","id":3,"method":"tools/call",
    "params":{"name":"ambient_context_get_policy","arguments":{}}
  }'
```
