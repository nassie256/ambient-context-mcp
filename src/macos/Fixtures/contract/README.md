# Contract fixtures (generated — do not hand-edit)

Windows 版 (`src/windows/AmbientContextMcp.Core`) の外部契約を JSON に固定したものです。
macOS 版 (Swift) はこのディレクトリの JSON を読み込んで、同じ入力に同じ出力を返すことを検証します。
背景と方針は [`docs/superpowers/specs/2026-09-03-macos-port-design.md`](../../../../docs/superpowers/specs/2026-09-03-macos-port-design.md)
の §1「外部契約」と §5「drift 対策」を参照してください。

## 生成方法

すべて `src/windows/AmbientContextMcp.Core.Tests/ContractFixturesTests.cs` の
`GeneratesContractFixtures` テストが生成します。再生成コマンド:

```sh
dotnet test src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj \
  --filter "FullyQualifiedName~ContractFixturesTests"
```

出力は決定的です (カタログ順を保持し、時刻・ランダム値を含まず、LF 改行 / BOM なし UTF-8 / 末尾改行)。
そのため CI はフィクスチャ再生成後に

```sh
git diff --exit-code src/macos/Fixtures/contract
```

を実行し、C# 側の契約が変わったのに生成物 (と Swift 側) を更新していない PR を落とします。
**このディレクトリのファイルを手で編集しないでください。** 差分を変えたい場合は C# 側を直してから再生成します。

## ファイル

| ファイル | 生成元 |
|---|---|
| `privacy-classifications.en.json` / `.ja.json` | `AmbientContextCatalog.GetPrivacyClassifications()` (`CultureInfo.CurrentUICulture` = `en-US` / `ja-JP`) |
| `event-schemas.en.json` / `.ja.json` | `AmbientContextCatalog.GetEventSchemas()` (同上) |
| `transmission-ui-groups.json` | `AmbientContextCatalog.GetTransmissionUiGroups()` |
| `tools-list.json` | MCP `tools/list` 相当。`McpServerTool.Create(MethodInfo, null, options).ProtocolTool` を 4 ツール分。SDK 既定の JSON オプション (`McpJsonUtilities.DefaultOptions`) を pretty-print |
| `policy-version.json` | `PolicyVersionService.ComputePolicyVersion` の入出力ケース |
| `cursor-encoding.json` | `LocalContextCursorTracker.Encode` と event id 形式 |
| `transmission-policy-cases.json` | `AmbientTransmissionPolicy.FilterStates` / `FilterEvents` と `TransmissionUiSettingsMerge.MergeOverrides` の振る舞いケース |

## Swift 側で注意する点

- `tools-list.json` 以外は `AmbientContextJson.Options` (camelCase / indented / enum は文字列) でシリアライズしています。
  カタログの並び順は **ソートせず定義順のまま** です。
- `tools-list.json` は SDK 自身の JSON オプションで出力しているため、`'` が `'`、
  em dash が `—` にエスケープされます。比較はパース後の値で行ってください。
- `tools-list.json` の `inputSchema` は nullable なパラメータを `"type": ["array", "null"]`
  のような **型配列** で表し、既定値を `"default": null` として明示します。`required` は出ません。
  `LocalContextHub` は DI 注入なのでスキーマに現れません。
- `policy-version.json` のハッシュは SHA-256 の先頭 9 バイトを base64url (パディング除去) したものです。
  入力文字列は path を **大文字小文字を無視して昇順ソート** した `c|path|sensitivity|0or1\n` と
  `o|path|0or1\n` の連結です。
- `transmission-policy-cases.json` の `events-title-changed-raw-title-opt-in` は、
  分類の無い payload キー (`titleSummary.file_ext`) が親 path の override を継承する挙動を含みます。
