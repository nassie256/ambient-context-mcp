# MCP ツール契約

Ambient Context MCP は Streamable HTTP MCP transport で 3 つのツールを公開します。エンドポイントは既定で `http://127.0.0.1:37690/mcp`、Bearer トークン必須、Origin ヘッダーがある場合は `localhost` / `127.0.0.1` / `::1` のみ許可。

## ツール一覧

### `ambient_context_get_policy`

機微度分類と有効送信可否の診断情報を返します。**実データの値や payload は返しません**。MCP クライアントは medium/high scope を指定しても値が増えない理由を「ユーザー送信ポリシーで許可されていない」と説明できます。

**Input** (オブジェクトなし、引数 0):

```json
{}
```

**Output**:

```json
{
  "observedAt": "2026-05-04T10:15:00+09:00",
  "source": "privacyClassifications",
  "transmissionPolicy": {
    "settingsPath": "%LOCALAPPDATA%\\AmbientContextMcp\\settings.json",
    "explicitOverrideCount": 1,
    "defaultBehavior": "privacyClassifications.defaultTransmit",
    "pathTransmitOverrides": {
      "foregroundApp.category": true
    }
  },
  "privacyClassifications": [ /* 全 path の機微度・既定送信可否 */ ],
  "effectivePolicies": [
    {
      "path": "foregroundApp.category",
      "sensitivity": "medium",
      "requiredScope": "context.medium:read",
      "defaultTransmit": false,
      "effectiveTransmit": true,
      "hasOverride": true,
      "overridePath": "foregroundApp.category",
      "overrideTransmit": true,
      "reason": "作業種別の推定に有用だが、行動履歴になりうる。"
    }
  ],
  "observedStateCount": 21,
  "outboundStateCount": 14,
  "internalEventHistoryCount": 2,
  "outboundEventCandidateCount": 2,
  "retainedOutboundEventCount": 2,
  "retention": { "maxAgeHours": 24, "maxEvents": 500 }
}
```

### `ambient_context_get_states`

設定済み送信ポリシーを通った最新状態のみを返します。クライアント側 scope はクライアントが「自分はこの機微度まで扱える」と申告する値で、応答に含まれるのは「ユーザー送信ポリシーで許可された項目」と「指定 scope 範囲に収まる機微度の項目」**両方を満たすもの**だけです。scope を上げても、ユーザーが許可していない項目は決して出力されません。実際に何が許可されているかは `ambient_context_get_policy` で確認できます。

**Input**:

```json
{
  "names": ["presence.bucket", "battery.percent"],
  "scopes": ["context.low:read"],
  "includeMetadata": true
}
```

- `names` 任意。省略時は許可済みの全 `outboundStates`
- `scopes` 任意。省略時は `context.low:read` 相当 (= 低機微項目のみ)

**Output**:

```json
{
  "observedAt": "2026-05-04T10:15:00+09:00",
  "source": "outboundStates",
  "states": [
    { "observedAt": "...", "name": "presence.bucket", "value": "active", "sensitivity": "low" },
    { "observedAt": "...", "name": "battery.percent", "value": "87", "sensitivity": "low" }
  ]
}
```

### `ambient_context_poll_events`

イベントを返します。2 つの呼び出しモードがあり、**`since` / `until` のいずれかを指定すると stateless な history query 扱い**となります。重複抑制と送信フィルタは `get_states` と同じく「ユーザー送信ポリシーで許可された項目」と「指定 scope 範囲に収まる機微度の項目」の AND。scope を高くしてもユーザーが許可していないイベントは出力されません。

**Input**:

```json
{
  "clientId": "ambient-context-mcp",
  "cursor": "client-opaque-cursor",
  "names": ["user_returned", "ac_power_connected"],
  "scopes": ["context.low:read"],
  "limit": 50,
  "since": "2026-05-10T00:00:00+09:00",
  "until": "2026-05-10T23:59:59+09:00"
}
```

- `clientId` 任意。省略時は `ambient-context-mcp`
- `cursor` 任意。省略時はクライアントの現在位置から (history query 時は保持範囲の先頭から)
- `names` 任意。省略時は許可済み全イベント
- `limit` 既定 50、最大 1000
- `since` / `until` 任意。ISO 8601 (例: `2026-05-10T00:00:00+09:00`)。指定すると ObservedAt が範囲内のイベントだけを返す

**Output**:

```json
{
  "events": [
    {
      "id": "evt_20260504_101501_000042",
      "sequence": 42,
      "observedAt": "2026-05-04T10:15:01+09:00",
      "name": "ac_power_connected",
      "value": "ac",
      "payload": { "from": "battery", "to": "ac" },
      "sensitivity": "low"
    }
  ],
  "nextCursor": "...",
  "hasMore": false,
  "cursorExpired": false,
  "retention": { "maxAgeHours": 24, "maxEvents": 500 }
}
```

## Cursor セマンティクス

- cursor はクライアント別の opaque token
- Hub は `clientId` ごとに最後に返したイベント位置を保持
- cursor が期限切れの場合は保持範囲内の最古位置から再開し `cursorExpired: true` を返す
- 既読化は `poll_events` の成功応答時。通信エラー時は同じ cursor で再取得可

## 呼び出しモード: subscription / history query

`poll_events` は 2 通りの呼び方ができます。

### subscription モード (既定)

`since` / `until` を**両方とも指定しない**呼び出し。クライアント別の cursor が前進する従来挙動です。

- 初回呼び出し (cursor 未指定 + クライアント位置未保存) は最新位置にカーソルがセットされ 0 件返ります — 「これから発生するイベントを順に subscribe する」用途
- 同じ cursor で再呼び出しすると同じ結果 (通信エラー時の再取得用)
- 成功応答時に `_clientPositions[clientId]` が進む

### history query モード

`since` または `until` のいずれかを指定した呼び出し。**stateless** で、何度呼んでも結果が消えません。

- `_clientPositions` は更新されない (副作用なし)
- cursor 未指定なら**保持範囲の先頭**から開始 (subscription モードと逆)
- pagination は `nextCursor` を次の呼び出しに渡せば OK (時刻範囲フィルタは併用される)
- 「今日 0:00 以降のイベントをまとめて欲しい」という要求は `since` だけ渡せば一発で取得可能 (上限 1000 件 / 1 回。`hasMore: true` の間は cursor を渡して継続)

## Scope

クライアント側 scope は「クライアントが扱える最大機微度」をサーバに申告するものです。応答に含まれる項目は **ユーザー送信ポリシー × scope** の AND で決まります。

- `context.low:read` (省略時もこれ): 機微度 low の項目のみ
- `context.medium:read`: low + medium
- `context.high:read`: low + medium + high

具体例 (ユーザーが `foregroundApp.category` (medium) のみ opt-in、`media.title` (high) は opt-in していない場合):

| クライアント指定 scope | 応答に含まれる項目 |
|---|---|
| 省略 (= `context.low:read`) | `presence.bucket`, `battery.percent` などの low 項目のみ |
| `context.medium:read` | 上記 + `foregroundApp.category` |
| `context.high:read` | 同上。**`media.title` は出力されない** (ユーザーが OFF のまま) |

要点:
- **scope を上げてもユーザーポリシーは上書きできない** — opt-in されていない medium/high 項目は決して出力されない
- **scope が低いと、ユーザーが許可していても応答に含まれない** — クライアント側で扱う準備のない機微度を取りに行かないための安全装置
- scope を高くしても何も増えない場合は、ユーザー側の送信ポリシーを `ambient_context_get_policy` で確認

## 認証

`Authorization: Bearer <token>` または `X-AmbientContextMcp-Token: <token>` を必須。トークンは初回起動時に生成され、`%LOCALAPPDATA%\AmbientContextMcp\settings.json` の `mcpServer.token` に保存されます。トレイメニューまたは設定ダイアログから取得できます。

## CORS / Origin

`Origin` ヘッダーがある場合は `localhost` / `127.0.0.1` / `::1` のみ許可。DNS rebinding 攻撃を防止します。
