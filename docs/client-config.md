# MCP クライアント設定例

Ambient Context MCP は Streamable HTTP transport で動作します。`http://127.0.0.1:37690/mcp` に Bearer トークン付きで接続してください。

## トークンの取得

トレイメニュー、または設定ダイアログから `Claude Code 用設定をコピー` 押下でクライアント設定コマンドが丸ごとクリップボードに入ります。手動で取得する場合は `%LOCALAPPDATA%\AmbientContextMcp\settings.json` の `mcpServer.token` を参照してください。

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

`%APPDATA%\Claude\claude_desktop_config.json` に追加:

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

Streamable HTTP のみ提供のため、stdio 専用クライアントには **stdio bridge を別途用意するまで対応していません** (v0.2 で予定)。

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
    "params":{"name":"ambient.context.get_states","arguments":{}}
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
    "params":{"name":"ambient.context.get_policy","arguments":{}}
  }'
```
