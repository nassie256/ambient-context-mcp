# PoC #1 — MCP Streamable HTTP (stateless) on Swift, without Hummingbird

- 日付: 2026-09-03
- 環境: macOS 26.6 arm64 / Swift 6.3.3 (Command Line Tools のみ、Xcode 無し)
- 対象: 設計書 [§2.3 依存パッケージ](../../../../docs/superpowers/specs/2026-09-03-macos-port-design.md) / §3.5 MCP サーバ / §4 Phase 0-1
- 場所: `src/macos/poc/01-mcp-http/` (executable target `AmbientMcpHttpPoc`)

## 結論

**成立。しかも Hummingbird は不要。**

`modelcontextprotocol/swift-sdk` 0.12.1 は Streamable HTTP の **サーバ側 transport を既に同梱している**
(`StatelessHTTPServerTransport`)。HTTP 層は SwiftNIO の `NIOHTTP1` +
`configureHTTPServerPipeline()` を 130 行ほどのアダプタで包むだけで足り、keep-alive /
chunked body / `Expect: 100-continue` は NIO 側が面倒を見る。Hummingbird を足す理由が無い。

→ **設計書 §2.3 の「サーバ側 Streamable HTTP transport は未提供のため自前 `Transport` で橋渡し」は
既に古い。§2.3 の依存表から Hummingbird を落とし、swift-nio (NIOCore/NIOPosix/NIOHTTP1) に置き換えるべき。**
(swift-nio は swift-sdk が既に推移的依存として持っているので、実質的な依存増加はゼロ。)

## 使った SDK 型

| 型 | 由来 | 役割 |
|---|---|---|
| `StatelessHTTPServerTransport` | `MCP` (Base/Transports/HTTPServer) | `actor`。`handleRequest(HTTPRequest) async -> HTTPResponse` を持ち、内部で `Transport` として `Server` に接続される |
| `HTTPRequest` / `HTTPResponse` | 同上 (`HTTPServerTypes.swift`) | フレームワーク非依存の req/res 表現。NIO からの変換のみ自前 |
| `StandardValidationPipeline` / `AcceptHeaderValidator(.jsonOnly)` / `ContentTypeValidator` / `ProtocolVersionValidator` | 同上 (`HTTPRequestValidation.swift`) | 明示指定。既定の `OriginValidator.localhost()` は**外した** (後述) |
| `Server` / `Server.Info` / `Server.Capabilities` | `MCP` | `withMethodHandler(Initialize/ListTools/CallTool)` |
| `Tool` / `Value` / `Tool.Content.text` / `Initialize.Result` / `Version.supported` / `Version.latest` | `MCP` | ツール定義と結果 |
| `ServerBootstrap` / `configureHTTPServerPipeline()` / `ChannelInboundHandler` | swift-nio | HTTP/1.1 |

構成ファイルは 4 つだけ:
`Sources/AmbientMcpHttpPoc/{main.swift, HTTPServer.swift, Auth.swift, Tools.swift}`。

## 認証の実装場所: SDK の validator ではなく NIO アダプタの事前チェック

`McpAuth` (`Auth.swift`) を `PocHTTPServer.handle(_:)` 内、`transport.handleRequest` を呼ぶ**前**に
走らせている。`HTTPRequestValidator` に載せなかった理由は 3 つ:

1. **カバー範囲**。stateless transport の validation pipeline は `handlePost` の中、しかも
   *ボディを JSON-RPC としてパースできた後*にしか走らない。GET / DELETE は pipeline に到達する前に
   405、空ボディ・壊れた JSON は 400 になり、いずれも**無認証で応答してしまう**。
   C# の `McpAuthenticationMiddleware` は `/mcp` 配下の全リクエストに掛かるので、これでは等価にならない。
   実測でも事前チェック版は `GET /mcp` (トークン無し) が 401 を返す — 検証 (k)。
2. **レスポンス本文**。`HTTPResponse.error` は必ず JSON-RPC エラーオブジェクト
   (`{"jsonrpc":"2.0","error":{...},"id":null}`) を組み立てる。Windows 契約の
   `{"error":"forbidden_origin"}` / `{"error":"unauthorized"}` は表現できない。
3. `BearerTokenValidator` は OAuth 2.1 リソースサーバ向けで、`resourceMetadataURL` / `aud` 検証 /
   RFC 9728 challenge が前提。共有シークレット 1 個と `X-AmbientContextMcp-Token` の
   代替ヘッダには重すぎる (カスタムヘッダ自体は `request.header(_:)` で読めるので表現は可能)。

`HTTPRequestValidator` プロトコル自体は素直なので、将来 OAuth に寄せるならそこに載せ替えられる。

## 既定 validation pipeline を差し替えた理由

SDK 既定の `OriginValidator.localhost()` は Windows 版より**厳しく**、そのままだと契約が変わる:

- `allowedOrigins` は `http://` のみ。`Origin: https://localhost` を 403 にする
  (C# 側は http/https 両方を許可) — 差し替え前の実測で 403 を確認済み。
- `Host` ヘッダも検査し、ループバック以外なら **421 Misdirected Request**。C# 版に Host 検査は無い。

そこで transport には `AcceptHeaderValidator(.jsonOnly)` / `ContentTypeValidator` /
`ProtocolVersionValidator` だけを渡し、Origin は `McpAuth` 側で C# と同一ロジックにした。
なお **Host 検査を捨てるのは DNS rebinding に対する多層防御を 1 枚剥がすことになる**ので、
Phase 2 で「Windows 側にも Host 検査を足して両者を揃える」ことを別途検討したい (本 PoC ではスコープ外)。

## 落とし穴 (Phase 2 に必ず持ち越すこと)

1. **`Server.start(transport:)` が既定ハンドラを (再) 登録する。**
   `registerDefaultHandlers` は `init` ではなく `start()` の中で呼ばれるため、
   `withMethodHandler` の上書きは **`start()` の後**でなければ効かない。
   `main.swift` はこの順序に依存している。
2. **既定の `initialize` ハンドラは stateless と相性が悪い。**
   SDK の既定実装は `isInitialized` を立て、2 回目の `initialize` を
   `"Server is already initialized"` (-32600) で拒否する。stateless では 1 個の長命な `Server` が
   クライアントごとに `initialize` を受けるので、**2 番目以降のクライアントが全て壊れる**
   (`Server.Configuration.strict` とは無関係で、常にこの挙動)。
   本 PoC は `Initialize` を冪等なハンドラで上書きして解決した (`Tools.swift`)。
   バージョンネゴシエーションの `Version.negotiate` は internal なので、
   `Version.supported.contains(_:) ? requested : Version.latest` を自前で書いている。
   代替案として「POST ごとに `Server` を作る」も可能だが、Hub を握る actor と寿命が合わないので非推奨。
3. **`strict: false` (既定) だと `initialize` 抜きでも `tools/call` が通る** — 検証 (m)。
   stateless では望ましい挙動 (StdioBridge の再接続に強い) なので既定のままにした。
4. **Swift 6 concurrency**: NIO 側は `@preconcurrency import` と
   `final class ... @unchecked Sendable` が必要 (SDK 自身の conformance サンプルも同じ形)。
   `channelRead` から `Task { }` に出る際は `nonisolated(unsafe) let ctx = context` で
   `ChannelHandlerContext` を渡し、書き戻しは必ず `ctx.eventLoop.execute { }` の中で行う。
   これを守らないと EventLoop 外からの書き込みでクラッシュする。
5. **`Content-Length` は自分で付ける。** SDK の `HTTPResponse.headers` には入っていないので、
   アダプタ側で `replaceOrAdd` しないと keep-alive 接続がハングする。
6. **ビルド時間**: クリーンビルドで約 160 秒 (swift-sdk + swift-nio + swift-log + eventsource +
   swift-system をソースからビルドするため)。CI のキャッシュ設計に効く。
7. `Tool.Content.text(_:)` は deprecated。`.text(text:annotations:_meta:)` を使う。

## StdioBridge (SSE) への影響 — 重要

**レスポンスは常に `Content-Type: application/json` の素の JSON で、SSE ではない。**
`StatelessHTTPServerTransport.handleJSONRPCRequest` は `.data(responseData, headers: [contentType: json])`
を返すだけで、`.stream` は stateful 側の経路にしか存在しない。

したがって `src/windows/AmbientContextMcp.StdioBridge/Program.cs`
(198 行目で最初の `data:` ブロックだけを読む実装) は **SSE 経路に入らない**。
Bridge が `text/event-stream` と `application/json` の両方を扱えるなら、macOS 側は無改造で通る。
`data:` 前提で決め打ちしている箇所があれば、そこだけ Phase 5 で確認が要る。

## 検証結果 (生ログ)

`swift build` は警告ゼロで成功 (`Build complete!`)。以下はサーバを
`.build/debug/AmbientMcpHttpPoc` で起動し (`AMBIENT_PORT` 未設定 = 37690、
`AMBIENT_TOKEN` 未設定 = `poc-token`)、curl を流したもの。

```
$ swift build
Build complete! (1.21s)

### (a) initialize
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 179

{"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{"listChanged":false}},"protocolVersion":"2025-06-18","serverInfo":{"name":"ambient-context-mcp-poc","version":"0.0.1"}}}
### (a2) initialize again (a second client session must also succeed)
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 179

{"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{"listChanged":false}},"protocolVersion":"2025-06-18","serverInfo":{"name":"ambient-context-mcp-poc","version":"0.0.1"}}}
### (b) notifications/initialized
HTTP/1.1 202 Accepted
Content-Length: 0


### (c) tools/list
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 1239

{"id":2,"jsonrpc":"2.0","result":{"tools":[{"description":"Returns the latest ambient context states. The response only includes items that satisfy BOTH (a) the user's transmission policy and (b) the client-supplied scope filter. The response includes a 'policyVersion' hash — clients can skip calling ambient_context_get_policy until that value changes.","inputSchema":{"properties":{"includeMetadata":{"default":true,"description":"Whether to include state metadata such as sensitivity and observed_at.","type":"boolean"},"names":{"description":"Optional list of state names to return. Omit or pass an empty list to return all allowed states.","items":{"type":"string"},"type":"array"},"scopes":{"description":"Optional MCP context scopes declaring the maximum sensitivity this client handles: context.low:read, context.medium:read, context.high:read, or context.all:read.","items":{"type":"string"},"type":"array"}},"type":"object"},"name":"ambient_context_get_states"},{"description":"Returns diagnostic metadata about Ambient Context MCP privacy classifications and effective transmission policy. This does not return sensitive context values.","inputSchema":{"properties":{},"type":"object"},"name":"ambient_context_get_policy"}]}}
### (d) tools/call ambient_context_get_states
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 607

{"id":3,"jsonrpc":"2.0","result":{"content":[{"text":"{\n  \"policyVersion\" : \"poc-0000000000000000\",\n  \"requestedNames\" : [\n\n  ],\n  \"requestedScopes\" : [\n    \"context.all:read\"\n  ],\n  \"states\" : [\n    {\n      \"name\" : \"presence\",\n      \"observedAt\" : \"2026-09-03T12:00:00+09:00\",\n      \"sensitivity\" : \"low\",\n      \"value\" : \"active\"\n    },\n    {\n      \"name\" : \"foreground_app_category\",\n      \"observedAt\" : \"2026-09-03T12:00:00+09:00\",\n      \"sensitivity\" : \"medium\",\n      \"value\" : \"editor\"\n    }\n  ]\n}","type":"text"}],"isError":false}}
### (e) GET /mcp (authenticated)
HTTP/1.1 405 Method Not Allowed
Allow: POST
Content-Type: application/json
Content-Length: 99

{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request: Method Not Allowed"}}
### (f) missing token -> 401
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer
Content-Type: application/json
Content-Length: 24

{"error":"unauthorized"}
### (g) X-AmbientContextMcp-Token -> 200
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 455

{"id":5,"jsonrpc":"2.0","result":{"content":[{"text":"{\n  \"defaultScope\" : \"context.low:read\",\n  \"paths\" : [\n    {\n      \"path\" : \"presence\",\n      \"sensitivity\" : \"low\",\n      \"transmitByDefault\" : true\n    },\n    {\n      \"path\" : \"foreground_app.title\",\n      \"sensitivity\" : \"high\",\n      \"transmitByDefault\" : false\n    }\n  ],\n  \"policyVersion\" : \"poc-0000000000000000\"\n}","type":"text"}],"isError":false}}
### (h) Origin: http://evil.example -> 403
HTTP/1.1 403 Forbidden
Content-Type: application/json
Content-Length: 28

{"error":"forbidden_origin"}
### (i) Origin: http://localhost:1234 -> passes auth (status line only)
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 1239
### (i2) Origin: https://localhost -> allowed, matching the C# middleware
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 1239

### (j) wrong bearer token -> 401
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer
Content-Type: application/json
Content-Length: 24

{"error":"unauthorized"}
### (k) GET without token -> 401 (auth runs before the transport 405)
HTTP/1.1 401 Unauthorized
Content-Type: application/json
WWW-Authenticate: Bearer
Content-Length: 24

{"error":"unauthorized"}
### (l) unknown path -> 404
HTTP/1.1 404 Not Found
Content-Type: application/json
Content-Length: 21

{"error":"not_found"}
### (m) tools/call on a fresh connection with no initialize (stateless)
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 426

{"id":9,"jsonrpc":"2.0","result":{"content":[{"text":"{\n  \"policyVersion\" : \"poc-0000000000000000\",\n  \"requestedNames\" : [\n\n  ],\n  \"requestedScopes\" : [\n    \"context.low:read\"\n  ],\n  \"states\" : [\n    {\n      \"name\" : \"presence\",\n      \"value\" : \"active\"\n    },\n    {\n      \"name\" : \"foreground_app_category\",\n      \"value\" : \"editor\"\n    }\n  ]\n}","type":"text"}],"isError":false}}
### (n) listener is loopback-only
COMMAND     PID   USER   FD   TYPE            DEVICE SIZE/OFF NODE NAME
AmbientMc 19814 takumi    5u  IPv4 0xef7e84c81c41461      0t0  TCP 127.0.0.1:37690 (LISTEN)
```

### `claude` CLI からの疎通

`claude mcp add` はユーザ設定を書き換えるので使わず、一時 config
(`{"mcpServers":{"ambient-poc":{"type":"http","url":"http://127.0.0.1:37690/mcp",
"headers":{"Authorization":"Bearer poc-token"}}}}`) を
`--mcp-config ... --strict-mcp-config` で渡した。ツール呼び出しは非対話モードだと
権限プロンプトで止まるため `--allowedTools` を併用している。

```
$ claude --mcp-config <tmp>/poc1-mcp.json --strict-mcp-config \
    --allowedTools "mcp__ambient-poc__ambient_context_get_states,mcp__ambient-poc__ambient_context_get_policy" \
    -p "List the MCP tools available to you and call ambient_context_get_states. ..."

**MCP tools available** (server: `ambient-poc`):

- `mcp__ambient-poc__ambient_context_get_policy`
- `mcp__ambient-poc__ambient_context_get_states`

**Result of `mcp__ambient-poc__ambient_context_get_states`:**

```json
{
  "policyVersion" : "poc-0000000000000000",
  "requestedNames" : [

  ],
  "requestedScopes" : [
    "context.low:read"
  ],
  "states" : [
    {
      "name" : "presence",
      "observedAt" : "2026-09-03T12:00:00+09:00",
      "sensitivity" : "low",
      "value" : "active"
    },
    {
      "name" : "foreground_app_category",
      "observedAt" : "2026-09-03T12:00:00+09:00",
      "sensitivity" : "medium",
      "value" : "editor"
    }
  ]
}
```

Note: I called it with no `scopes` argument, and the server defaulted to `context.low:read` — yet it still returned a `medium`-sensitivity item (`foreground_app_category`). That may be worth checking against the policy filter if this is a PoC you're validating.
```

(末尾の指摘はスタブが固定 JSON を返しているだけなので想定内。scope フィルタは Phase 1 の
`SensitivityScopeFilter` 移植で実装する。)

検証後、バックグラウンドのサーバは停止済み (残留プロセス無し)。

## 設計書への反映提案

### §2.3 依存パッケージ

- 「HTTP サーバ (127.0.0.1 のみ) / `hummingbird-project/hummingbird` 2.x」の行を
  **`apple/swift-nio` (NIOCore / NIOPosix / NIOHTTP1)** に差し替える。
  `configureHTTPServerPipeline()` + 1 ハンドラで足り、swift-sdk が既に swift-nio を
  推移的に引いているので依存グラフは太らない。
- MCP 行の注記「サーバ側 Streamable HTTP transport は未提供のため自前 `Transport` で HTTP と橋渡し」
  を削除し、「swift-sdk 同梱の `StatelessHTTPServerTransport` をそのまま使い、
  NIO ↔ `HTTPRequest`/`HTTPResponse` の変換アダプタのみ自前」に改める。
- 末尾の「依存を増やしたくなければ `NWListener` + 最小 HTTP/1.1 でも書けるが…」の段落は不要になる。
- macOS 14 要件の根拠から Hummingbird が消えるが、Swift 6 strict concurrency の分で
  **macOS 14 の下限は維持してよい** (swift-sdk 自体の下限は macOS 13)。

### §3.5 MCP サーバ

- 「Hummingbird で listen」→「SwiftNIO で listen」。
- 認証は **ミドルウェア相当を NIO アダプタの事前チェックとして持つ** ことを明記
  (SDK の validation pipeline は POST かつ JSON-RPC パース成功後にしか走らないため、
  GET / 壊れたボディが素通りする)。
- 「`GET /mcp` は stateless のため 405」は実測どおり。ヘッダは `Allow: POST`、
  ボディは JSON-RPC エラー `-32600 "Invalid Request: Method Not Allowed"`。
  ただし**未認証の GET は 401 が先**である旨も追記したい。
- 「stateless では `initialize` を冪等にする (SDK 既定ハンドラを上書きする)」を注意書きとして追加。
  これを忘れると 2 クライアント目以降が接続できず、症状が分かりにくい。
- transport に渡す validation pipeline から `OriginValidator` を外し、Origin は自前で持つ
  (SDK 既定は https origin を弾き、Host 不一致で 421 を返すため Windows 契約と非互換) を追加。

### §4 Phase 0

- 項目 1 は **達成**。`claude` CLI から `tools/list` / `tools/call` まで確認済み。
  「Hummingbird で」の文言を「SwiftNIO で」に直す。
