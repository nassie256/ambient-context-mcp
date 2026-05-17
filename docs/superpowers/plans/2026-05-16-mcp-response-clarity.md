# MCP Response Clarity — per-field sensitivity, policyVersion, context.all:read

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** クライアントが「外側 medium / 内側 high」の混在を識別できないこと、ポリシーを毎回叩かないと変化に気付けないこと、`context.high:read` を明示しないと「許可された全部」が取れないこと、の 3 つを解消する。

**Architecture:** `LocalContextEvent` に payload キー単位の機微度マップと `maxFieldSensitivity` を持たせ、Ingest 時に `PrivacyClassifications` から導出する。scope フィルタを「event 全体落とし」から「payload を field 単位で間引く」方式に変更し、event レベルの Sensitivity ガードと組み合わせて運用する。レスポンスに `policyVersion` (SHA256 truncated base64url) を毎回付与し、変更があったときだけクライアントが `get_policy` を再取得すれば済むようにする。`context.all:read` を新しい alias として追加し、後方互換を壊さずに「ポリシーが許可した最大」を 1 語で宣言できるようにする。

**Tech Stack:** .NET 8 / C# 12, xUnit (新規)

---

## File Structure

**Modified files:**
- `src/windows/AmbientContextMcp.Core/Hub/LocalContextHubModels.cs` — `LocalContextEvent` に 2 フィールド、`LocalContextPollResponse` / `LocalContextStateResponse` に `PolicyVersion` を追加。
- `src/windows/AmbientContextMcp.Core/Hub/LocalContextHub.cs` — Ingest 時の per-field sensitivity 算出、scope フィルタの per-field 化、policyVersion 計算、`context.all:read` の受理を実装。
- `src/windows/AmbientContextMcp.Core/Mcp/ContextTools.cs` — tool description を新仕様に合わせて更新。
- `src/windows/AmbientContextMcp.sln` — 新規テストプロジェクトを追加。
- `docs/tool-spec.md` — レスポンス例と Scope セクションを更新。

**New files:**
- `src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj` — xUnit テストプロジェクト。Core への ProjectReference のみ。
- `src/windows/AmbientContextMcp.Core.Tests/SensitivityFilterTests.cs` — per-field 機微度算出と scope フィルタのテスト。
- `src/windows/AmbientContextMcp.Core.Tests/PolicyVersionTests.cs` — policyVersion の安定性と変更検知のテスト。
- `src/windows/AmbientContextMcp.Core.Tests/ScopeAliasTests.cs` — `context.all:read` alias のテスト。

**設計上の不変条件:**
- `LocalContextEvent.PayloadSensitivity` が空 dict のとき (古い events.jsonl から復元など) は、フィルタが event-level `Sensitivity` にフォールバックして従来挙動を再現する。
- `MaxFieldSensitivity` が空文字列のとき (古い events) も同様。
- scope フィルタは「event を完全に落とす」と「event は通すが payload キーを間引く」の 2 段判定で、後者の場合でも event-level `Sensitivity` ガードは独立に動く。

---

## Task 0: Set up test project

**Files:**
- Create: `src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj`
- Modify: `src/windows/AmbientContextMcp.sln`

- [ ] **Step 1: Create test project file**

Create `src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <RootNamespace>AmbientContextMcp.Core.Tests</RootNamespace>
    <IsPackable>false</IsPackable>
    <IsTestProject>true</IsTestProject>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.11.1" />
    <PackageReference Include="xunit" Version="2.9.2" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.8.2" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\AmbientContextMcp.Core\AmbientContextMcp.Core.csproj" />
  </ItemGroup>
</Project>
```

- [ ] **Step 2: Add test project to solution**

Run from `src/windows/`:

```bash
dotnet sln AmbientContextMcp.sln add AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj
```

- [ ] **Step 3: Restore + build to confirm scaffold**

Run from `src/windows/`:

```bash
dotnet build AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj -c Debug
```

Expected: Build succeeded (0 warnings, 0 errors). No tests yet, so `dotnet test` would say "No test is available".

- [ ] **Step 4: Commit**

```bash
rtk git add src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj src/windows/AmbientContextMcp.sln
rtk git commit -m "chore(tests): add AmbientContextMcp.Core.Tests project scaffold"
```

---

## Task 1: Add per-field sensitivity fields to LocalContextEvent (model only)

**Files:**
- Modify: `src/windows/AmbientContextMcp.Core/Hub/LocalContextHubModels.cs:107-123`

- [ ] **Step 1: Add `PayloadSensitivity` and `MaxFieldSensitivity` to `LocalContextEvent`**

Edit `src/windows/AmbientContextMcp.Core/Hub/LocalContextHubModels.cs`. Replace the existing `LocalContextEvent` class (lines 107–123) with:

```csharp
public sealed class LocalContextEvent
{
    public string Id { get; init; } = "";

    public long Sequence { get; init; }

    public DateTimeOffset ObservedAt { get; init; }

    public string Name { get; init; } = "";

    public string Value { get; init; } = "";

    public IReadOnlyDictionary<string, string> Payload { get; init; } =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    public string Sensitivity { get; init; } = "low";

    /// <summary>
    /// payload キーごとの機微度。Ingest 時に PrivacyClassifications から導出される。
    /// 該当 classification が無いキーは event-level <see cref="Sensitivity"/> を継承する。
    /// 古い events.jsonl から復元した場合は空 dict になり、フィルタは event-level Sensitivity にフォールバックする。
    /// </summary>
    public IReadOnlyDictionary<string, string> PayloadSensitivity { get; init; } =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// event-level Sensitivity と payload キー機微度のうち最も高いもの。
    /// クライアントが scope を判断するための一次サマリ。空文字列の場合は Sensitivity を参照する。
    /// </summary>
    public string MaxFieldSensitivity { get; init; } = "";
}
```

- [ ] **Step 2: Build to confirm the model compiles**

```bash
dotnet build src/windows/AmbientContextMcp.Core/AmbientContextMcp.Core.csproj -c Debug
```

Expected: Build succeeded.

- [ ] **Step 3: Commit**

```bash
rtk git add src/windows/AmbientContextMcp.Core/Hub/LocalContextHubModels.cs
rtk git commit -m "feat(hub): add per-field sensitivity fields to LocalContextEvent"
```

---

## Task 2: Implement per-field sensitivity lookup helper (TDD)

**Files:**
- Modify: `src/windows/AmbientContextMcp.Core/Hub/LocalContextHub.cs` (add private static helpers near `IsSensitivityAllowed`, around line 590)
- Create: `src/windows/AmbientContextMcp.Core.Tests/SensitivityFilterTests.cs`

- [ ] **Step 1: Write failing tests for `LookupPayloadFieldSensitivity` and `ComputePayloadSensitivity`**

Create `src/windows/AmbientContextMcp.Core.Tests/SensitivityFilterTests.cs`:

```csharp
using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Models;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class SensitivityFilterTests
{
    private static readonly IReadOnlyList<PrivacyClassification> Classifications =
    [
        new() { Path = "events.media_session_changed", Sensitivity = "medium", DefaultTransmit = false },
        new() { Path = "events.media_session_changed.title", Sensitivity = "high", DefaultTransmit = false },
        new() { Path = "events.media_session_changed.artist", Sensitivity = "high", DefaultTransmit = false },
    ];

    [Fact]
    public void LookupPayloadFieldSensitivity_returns_exact_match()
    {
        var result = LocalContextHub.LookupPayloadFieldSensitivityForTest(
            eventName: "media_session_changed",
            payloadKey: "title",
            classifications: Classifications,
            fallbackSensitivity: "medium");

        Assert.Equal("high", result);
    }

    [Fact]
    public void LookupPayloadFieldSensitivity_falls_back_to_event_level()
    {
        var result = LocalContextHub.LookupPayloadFieldSensitivityForTest(
            eventName: "media_session_changed",
            payloadKey: "source_app",
            classifications: Classifications,
            fallbackSensitivity: "medium");

        Assert.Equal("medium", result);
    }

    [Fact]
    public void ComputePayloadSensitivity_returns_max_high_when_any_field_is_high()
    {
        var payload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "title", "Imagine" },
            { "artist", "John Lennon" },
            { "source_app", "Chrome" }
        };

        var (perKey, max) = LocalContextHub.ComputePayloadSensitivityForTest(
            eventName: "media_session_changed",
            payload: payload,
            classifications: Classifications,
            eventSensitivity: "medium");

        Assert.Equal("high", perKey["title"]);
        Assert.Equal("high", perKey["artist"]);
        Assert.Equal("medium", perKey["source_app"]);
        Assert.Equal("high", max);
    }

    [Fact]
    public void ComputePayloadSensitivity_returns_event_level_when_all_fields_inherit()
    {
        var payload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "from", "battery" },
            { "to", "ac" }
        };

        var (perKey, max) = LocalContextHub.ComputePayloadSensitivityForTest(
            eventName: "ac_power_connected",
            payload: payload,
            classifications: Classifications,
            eventSensitivity: "low");

        Assert.Equal("low", perKey["from"]);
        Assert.Equal("low", perKey["to"]);
        Assert.Equal("low", max);
    }

    [Fact]
    public void FilterEventForScope_keeps_event_drops_high_keys_when_scope_is_medium()
    {
        var ev = new LocalContextEvent
        {
            Id = "evt_x",
            Sequence = 1,
            ObservedAt = DateTimeOffset.UtcNow,
            Name = "media_session_changed",
            Value = "Imagine",
            Payload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "title", "Imagine" },
                { "source_app", "Chrome" }
            },
            PayloadSensitivity = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "title", "high" },
                { "source_app", "medium" }
            },
            Sensitivity = "medium",
            MaxFieldSensitivity = "high"
        };

        var filtered = LocalContextHub.FilterEventForScopeForTest(ev, ["context.medium:read"]);

        Assert.NotNull(filtered);
        Assert.False(filtered!.Payload.ContainsKey("title"));
        Assert.True(filtered.Payload.ContainsKey("source_app"));
        Assert.Equal("medium", filtered.MaxFieldSensitivity);
        Assert.Equal("medium", filtered.PayloadSensitivity["source_app"]);
    }

    [Fact]
    public void FilterEventForScope_drops_event_when_event_level_exceeds_scope()
    {
        var ev = new LocalContextEvent
        {
            Id = "evt_x",
            Sequence = 1,
            ObservedAt = DateTimeOffset.UtcNow,
            Name = "media_session_changed",
            Sensitivity = "medium",
            MaxFieldSensitivity = "medium",
            Payload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "source_app", "Chrome" }
            },
            PayloadSensitivity = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "source_app", "medium" }
            }
        };

        var filtered = LocalContextHub.FilterEventForScopeForTest(ev, ["context.low:read"]);

        Assert.Null(filtered);
    }

    [Fact]
    public void FilterEventForScope_passes_through_when_payload_sensitivity_is_empty()
    {
        // 古い events.jsonl から復元したケース。PayloadSensitivity が空でも event-level でフィルタが効く。
        var ev = new LocalContextEvent
        {
            Id = "evt_x",
            Sequence = 1,
            ObservedAt = DateTimeOffset.UtcNow,
            Name = "ac_power_connected",
            Sensitivity = "low",
            MaxFieldSensitivity = "",
            Payload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "to", "ac" }
            }
        };

        var filtered = LocalContextHub.FilterEventForScopeForTest(ev, ["context.low:read"]);

        Assert.NotNull(filtered);
        Assert.True(filtered!.Payload.ContainsKey("to"));
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail with compile errors**

Run from `src/windows/`:

```bash
dotnet test AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj
```

Expected: Compile errors referencing `LookupPayloadFieldSensitivityForTest`, `ComputePayloadSensitivityForTest`, `FilterEventForScopeForTest`.

- [ ] **Step 3: Implement the helpers in `LocalContextHub`**

In `src/windows/AmbientContextMcp.Core/Hub/LocalContextHub.cs`, locate the block of `private static` helpers near `IsSensitivityAllowed` (around line 578). Add the following helpers immediately after `NormalizeSensitivity` (around line 610). Keep `internal static` (not private) and add a thin `*ForTest` wrapper for each so tests in the sister project can reach them. xUnit test project has no InternalsVisibleTo, so the wrappers must be `public`:

```csharp
private static string LookupPayloadFieldSensitivity(
    string eventName,
    string payloadKey,
    IReadOnlyList<PrivacyClassification> classifications,
    string fallbackSensitivity)
{
    var keyPath = $"events.{eventName}.{payloadKey}";

    // 1. 完全一致を最優先 (例: events.media_session_changed.title)
    foreach (var item in classifications)
    {
        if (item.Path.Equals(keyPath, StringComparison.OrdinalIgnoreCase))
        {
            return NormalizeSensitivity(item.Sensitivity);
        }
    }

    // 2. 親パスを最長一致で探す (例: events.media_session_changed)
    PrivacyClassification? bestParent = null;
    foreach (var item in classifications)
    {
        if (keyPath.StartsWith(item.Path + ".", StringComparison.OrdinalIgnoreCase) &&
            (bestParent is null || item.Path.Length > bestParent.Path.Length))
        {
            bestParent = item;
        }
    }

    if (bestParent is not null)
    {
        return NormalizeSensitivity(bestParent.Sensitivity);
    }

    // 3. event-level Sensitivity にフォールバック
    return NormalizeSensitivity(fallbackSensitivity);
}

private static (IReadOnlyDictionary<string, string> PerKey, string Max) ComputePayloadSensitivity(
    string eventName,
    IReadOnlyDictionary<string, string> payload,
    IReadOnlyList<PrivacyClassification> classifications,
    string eventSensitivity)
{
    var perKey = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    var maxLevel = GetSensitivityLevel(eventSensitivity);

    foreach (var key in payload.Keys)
    {
        var fieldSensitivity = LookupPayloadFieldSensitivity(eventName, key, classifications, eventSensitivity);
        perKey[key] = fieldSensitivity;

        var level = GetSensitivityLevel(fieldSensitivity);
        if (level > maxLevel)
        {
            maxLevel = level;
        }
    }

    return (perKey, LevelToSensitivity(maxLevel));
}

private static string LevelToSensitivity(int level)
{
    return level switch
    {
        3 => "high",
        2 => "medium",
        _ => "low"
    };
}

/// <summary>
/// scope フィルタを per-field 化したもの。
/// event-level Sensitivity が scope を超えたら null を返す (event ごと落とす)。
/// それ以外は payload を機微度別に間引いた新しい LocalContextEvent を返す。
/// PayloadSensitivity が空のとき (旧データ復元) は event-level Sensitivity にフォールバック。
/// </summary>
private static LocalContextEvent? FilterEventForScope(
    LocalContextEvent ev,
    IReadOnlyList<string> scopes)
{
    var allowedLevel = GetAllowedLevel(scopes);

    if (GetSensitivityLevel(ev.Sensitivity) > allowedLevel)
    {
        return null;
    }

    // payload キー単位フィルタが不要なら同一参照を返す (アロケーション抑制)
    if (string.IsNullOrEmpty(ev.MaxFieldSensitivity) ||
        GetSensitivityLevel(ev.MaxFieldSensitivity) <= allowedLevel)
    {
        return ev;
    }

    var filteredPayload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    var filteredSensitivity = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    var maxLevel = GetSensitivityLevel(ev.Sensitivity);

    foreach (var pair in ev.Payload)
    {
        var fieldSensitivity = ev.PayloadSensitivity.TryGetValue(pair.Key, out var s)
            ? s
            : ev.Sensitivity;
        if (GetSensitivityLevel(fieldSensitivity) > allowedLevel)
        {
            continue;
        }

        filteredPayload[pair.Key] = pair.Value;
        filteredSensitivity[pair.Key] = fieldSensitivity;
        var level = GetSensitivityLevel(fieldSensitivity);
        if (level > maxLevel)
        {
            maxLevel = level;
        }
    }

    return new LocalContextEvent
    {
        Id = ev.Id,
        Sequence = ev.Sequence,
        ObservedAt = ev.ObservedAt,
        Name = ev.Name,
        Value = ev.Value,
        Payload = filteredPayload,
        Sensitivity = ev.Sensitivity,
        PayloadSensitivity = filteredSensitivity,
        MaxFieldSensitivity = LevelToSensitivity(maxLevel)
    };
}

private static int GetAllowedLevel(IReadOnlyList<string> scopes)
{
    if (scopes.Contains("context.high:read", StringComparer.OrdinalIgnoreCase) ||
        scopes.Contains("context.all:read", StringComparer.OrdinalIgnoreCase))
    {
        return 3;
    }

    if (scopes.Contains("context.medium:read", StringComparer.OrdinalIgnoreCase))
    {
        return 2;
    }

    return 1;
}

// --- Test-only wrappers (tests live in a sister assembly without InternalsVisibleTo) ---

public static string LookupPayloadFieldSensitivityForTest(
    string eventName,
    string payloadKey,
    IReadOnlyList<PrivacyClassification> classifications,
    string fallbackSensitivity) =>
    LookupPayloadFieldSensitivity(eventName, payloadKey, classifications, fallbackSensitivity);

public static (IReadOnlyDictionary<string, string> PerKey, string Max) ComputePayloadSensitivityForTest(
    string eventName,
    IReadOnlyDictionary<string, string> payload,
    IReadOnlyList<PrivacyClassification> classifications,
    string eventSensitivity) =>
    ComputePayloadSensitivity(eventName, payload, classifications, eventSensitivity);

public static LocalContextEvent? FilterEventForScopeForTest(
    LocalContextEvent ev,
    IReadOnlyList<string> scopes) =>
    FilterEventForScope(ev, scopes);
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
dotnet test src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj
```

Expected: All 7 tests in `SensitivityFilterTests` pass.

- [ ] **Step 5: Commit**

```bash
rtk git add src/windows/AmbientContextMcp.Core/Hub/LocalContextHub.cs src/windows/AmbientContextMcp.Core.Tests/SensitivityFilterTests.cs
rtk git commit -m "feat(hub): add per-field sensitivity computation and scope filter"
```

---

## Task 3: Wire per-field sensitivity into Ingest + PollEvents

**Files:**
- Modify: `src/windows/AmbientContextMcp.Core/Hub/LocalContextHub.cs:62-121` (Ingest) and `:140-186` (PollEvents)

- [ ] **Step 1: Add test verifying Ingest populates PayloadSensitivity + MaxFieldSensitivity**

Append to `src/windows/AmbientContextMcp.Core.Tests/SensitivityFilterTests.cs`:

```csharp
public class HubIngestTests
{
    [Fact]
    public void Ingest_populates_payload_sensitivity_from_classifications()
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();
        var observedAt = DateTimeOffset.UtcNow;

        var snapshot = new AmbientContextSnapshot
        {
            ObservedAt = observedAt,
            PrivacyClassifications =
            [
                new() { Path = "events.media_session_changed", Sensitivity = "medium", DefaultTransmit = false },
                new() { Path = "events.media_session_changed.title", Sensitivity = "high", DefaultTransmit = false }
            ],
            OutboundEvents =
            [
                new()
                {
                    ObservedAt = observedAt,
                    Name = "media_session_changed",
                    Value = "Imagine",
                    Payload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                    {
                        { "title", "Imagine" },
                        { "source_app", "Chrome" }
                    },
                    Sensitivity = "medium"
                }
            ]
        };

        hub.Ingest(snapshot);

        var poll = hub.PollEvents(new LocalContextPollRequest
        {
            ClientId = "test",
            Scopes = ["context.high:read"]
        });

        var ev = Assert.Single(poll.Events);
        Assert.Equal("high", ev.PayloadSensitivity["title"]);
        Assert.Equal("medium", ev.PayloadSensitivity["source_app"]);
        Assert.Equal("high", ev.MaxFieldSensitivity);
    }

    [Fact]
    public void PollEvents_with_medium_scope_strips_high_payload_keys_but_keeps_event()
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();
        var observedAt = DateTimeOffset.UtcNow;

        hub.Ingest(new AmbientContextSnapshot
        {
            ObservedAt = observedAt,
            PrivacyClassifications =
            [
                new() { Path = "events.media_session_changed", Sensitivity = "medium", DefaultTransmit = false },
                new() { Path = "events.media_session_changed.title", Sensitivity = "high", DefaultTransmit = false }
            ],
            OutboundEvents =
            [
                new()
                {
                    ObservedAt = observedAt,
                    Name = "media_session_changed",
                    Value = "Imagine",
                    Payload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                    {
                        { "title", "Imagine" },
                        { "source_app", "Chrome" }
                    },
                    Sensitivity = "medium"
                }
            ]
        });

        var poll = hub.PollEvents(new LocalContextPollRequest
        {
            ClientId = "test",
            Scopes = ["context.medium:read"]
        });

        var ev = Assert.Single(poll.Events);
        Assert.False(ev.Payload.ContainsKey("title"));
        Assert.Equal("Chrome", ev.Payload["source_app"]);
        Assert.Equal("medium", ev.MaxFieldSensitivity);
    }
}
```

Add the test-helper factory file `src/windows/AmbientContextMcp.Core.Tests/LocalContextHubTestFactory.cs`:

```csharp
using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Models;
using AmbientContextMcp.Core.Settings;

namespace AmbientContextMcp.Core.Tests;

internal static class LocalContextHubTestFactory
{
    public static LocalContextHub CreateInMemory() =>
        new(new InMemorySettingsStore());

    private sealed class InMemorySettingsStore : ISettingsStore
    {
        public string SettingsPath => Path.Combine(Path.GetTempPath(), "ambient-context-mcp-test", Guid.NewGuid() + ".json");

        public LocalContextSettings LoadLocalContextSettings() => new();

        public AmbientTransmissionSettings LoadAmbientTransmissionSettings() => new();

        public void SaveAmbientTransmissionSettings(AmbientTransmissionSettings settings)
        {
        }
    }
}
```

If `ISettingsStore` shape differs from the inline factory above, open `src/windows/AmbientContextMcp.Core/Settings/ISettingsStore.cs` and align the dummy methods exactly to that interface. The intent is "stateless in-memory stub returning defaults"; do not add behavior.

- [ ] **Step 2: Run tests to confirm they fail (Ingest currently does not compute PayloadSensitivity)**

```bash
dotnet test src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj --filter "FullyQualifiedName~HubIngestTests"
```

Expected: 2 failures — `PayloadSensitivity` empty / `MaxFieldSensitivity` empty.

- [ ] **Step 3: Modify `Ingest` to compute payload sensitivity**

Edit `src/windows/AmbientContextMcp.Core/Hub/LocalContextHub.cs` lines 85–95. Replace the `LocalContextEvent` construction with:

```csharp
var sequence = ++_nextSequence;
var (payloadSensitivity, maxFieldSensitivity) = ComputePayloadSensitivity(
    outboundEvent.Name,
    outboundEvent.Payload,
    _privacyClassifications,
    outboundEvent.Sensitivity);
var localEvent = new LocalContextEvent
{
    Id = CreateEventId(outboundEvent.ObservedAt, sequence),
    Sequence = sequence,
    ObservedAt = outboundEvent.ObservedAt,
    Name = outboundEvent.Name,
    Value = outboundEvent.Value,
    Payload = outboundEvent.Payload,
    Sensitivity = outboundEvent.Sensitivity,
    PayloadSensitivity = payloadSensitivity,
    MaxFieldSensitivity = maxFieldSensitivity
};
```

- [ ] **Step 4: Modify `PollEvents` to use `FilterEventForScope` instead of event-level filter**

Edit `src/windows/AmbientContextMcp.Core/Hub/LocalContextHub.cs` lines 151–158. Replace the existing query chain:

```csharp
var matchingEvents = _events
    .Where(item => item.Sequence > cursorResult.Sequence)
    .Where(item => !request.Since.HasValue || item.ObservedAt >= request.Since.Value)
    .Where(item => !request.Until.HasValue || item.ObservedAt <= request.Until.Value)
    .Where(item => IsNameIncluded(item.Name, request.Names))
    .Where(item => IsSensitivityAllowed(item.Sensitivity, request.Scopes))
    .Take(limit + 1)
    .ToList();
```

with:

```csharp
var matchingEvents = _events
    .Where(item => item.Sequence > cursorResult.Sequence)
    .Where(item => !request.Since.HasValue || item.ObservedAt >= request.Since.Value)
    .Where(item => !request.Until.HasValue || item.ObservedAt <= request.Until.Value)
    .Where(item => IsNameIncluded(item.Name, request.Names))
    .Select(item => FilterEventForScope(item, request.Scopes))
    .Where(item => item is not null)
    .Select(item => item!)
    .Take(limit + 1)
    .ToList();
```

- [ ] **Step 5: Run all tests to confirm they pass**

```bash
dotnet test src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj
```

Expected: All `SensitivityFilterTests` + `HubIngestTests` pass.

- [ ] **Step 6: Build the full solution to confirm no regressions**

```bash
dotnet build src/windows/AmbientContextMcp.sln -c Debug
```

Expected: Build succeeded.

- [ ] **Step 7: Commit**

```bash
rtk git add src/windows/AmbientContextMcp.Core/Hub/LocalContextHub.cs src/windows/AmbientContextMcp.Core.Tests/SensitivityFilterTests.cs src/windows/AmbientContextMcp.Core.Tests/LocalContextHubTestFactory.cs
rtk git commit -m "feat(hub): apply per-field scope filter at PollEvents and populate sensitivity at Ingest"
```

---

## Task 4: Add `policyVersion` to responses

**Files:**
- Modify: `src/windows/AmbientContextMcp.Core/Hub/LocalContextHubModels.cs:14-21` and `:48-59`
- Modify: `src/windows/AmbientContextMcp.Core/Hub/LocalContextHub.cs:36-47, 62-121, 123-138, 140-186`
- Create: `src/windows/AmbientContextMcp.Core.Tests/PolicyVersionTests.cs`

- [ ] **Step 1: Add `PolicyVersion` field to response DTOs**

Edit `src/windows/AmbientContextMcp.Core/Hub/LocalContextHubModels.cs`. Replace `LocalContextStateResponse` (lines 14–21):

```csharp
public sealed class LocalContextStateResponse
{
    public DateTimeOffset ObservedAt { get; init; }

    public IReadOnlyList<AmbientState> States { get; init; } = [];

    public string Source { get; init; } = "outboundStates";

    /// <summary>
    /// クライアントが get_policy を再取得すべきかを判定するための短いハッシュ。
    /// privacyClassifications と pathTransmitOverrides の合成から導出され、
    /// ポリシーに変化があった場合にのみ値が変わる。
    /// </summary>
    public string PolicyVersion { get; init; } = "";
}
```

And `LocalContextPollResponse` (lines 48–59):

```csharp
public sealed class LocalContextPollResponse
{
    public IReadOnlyList<LocalContextEvent> Events { get; init; } = [];

    public string NextCursor { get; init; } = "";

    public bool HasMore { get; init; }

    public bool CursorExpired { get; init; }

    public LocalContextRetentionInfo Retention { get; init; } = new();

    /// <summary>
    /// LocalContextStateResponse.PolicyVersion と同一値。クライアントは前回の値と比較して
    /// 変化があるときだけ get_policy を再取得すればよい。
    /// </summary>
    public string PolicyVersion { get; init; } = "";
}
```

- [ ] **Step 2: Write tests for policyVersion stability and change detection**

Create `src/windows/AmbientContextMcp.Core.Tests/PolicyVersionTests.cs`:

```csharp
using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Models;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class PolicyVersionTests
{
    [Fact]
    public void Same_policy_produces_same_version()
    {
        var classifications = new List<PrivacyClassification>
        {
            new() { Path = "media.title", Sensitivity = "high", DefaultTransmit = false }
        };
        var overrides = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase)
        {
            { "media.title", true }
        };

        var a = LocalContextHub.ComputePolicyVersionForTest(classifications, overrides);
        var b = LocalContextHub.ComputePolicyVersionForTest(classifications, overrides);

        Assert.False(string.IsNullOrEmpty(a));
        Assert.Equal(a, b);
    }

    [Fact]
    public void Changing_override_changes_version()
    {
        var classifications = new List<PrivacyClassification>
        {
            new() { Path = "media.title", Sensitivity = "high", DefaultTransmit = false }
        };

        var beforeOverrides = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        var afterOverrides = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase)
        {
            { "media.title", true }
        };

        var before = LocalContextHub.ComputePolicyVersionForTest(classifications, beforeOverrides);
        var after = LocalContextHub.ComputePolicyVersionForTest(classifications, afterOverrides);

        Assert.NotEqual(before, after);
    }

    [Fact]
    public void Override_order_does_not_affect_version()
    {
        var classifications = new List<PrivacyClassification>
        {
            new() { Path = "media.title", Sensitivity = "high", DefaultTransmit = false }
        };
        var ordered1 = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase)
        {
            { "media.title", true },
            { "media.artist", true }
        };
        var ordered2 = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase)
        {
            { "media.artist", true },
            { "media.title", true }
        };

        Assert.Equal(
            LocalContextHub.ComputePolicyVersionForTest(classifications, ordered1),
            LocalContextHub.ComputePolicyVersionForTest(classifications, ordered2));
    }

    [Fact]
    public void Hub_exposes_policy_version_via_state_and_poll_responses()
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();
        hub.Ingest(new AmbientContextSnapshot
        {
            ObservedAt = DateTimeOffset.UtcNow,
            PrivacyClassifications =
            [
                new() { Path = "media.title", Sensitivity = "high", DefaultTransmit = false }
            ]
        });

        var state = hub.GetContextStates(new LocalContextStateRequest());
        var poll = hub.PollEvents(new LocalContextPollRequest { ClientId = "test" });

        Assert.False(string.IsNullOrEmpty(state.PolicyVersion));
        Assert.Equal(state.PolicyVersion, poll.PolicyVersion);
    }
}
```

- [ ] **Step 3: Run tests to confirm they fail with missing method**

```bash
dotnet test src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj --filter "FullyQualifiedName~PolicyVersionTests"
```

Expected: Compile errors on `ComputePolicyVersionForTest`.

- [ ] **Step 4: Implement `ComputePolicyVersion` + cache field + thread the value through responses**

Edit `src/windows/AmbientContextMcp.Core/Hub/LocalContextHub.cs`.

(a) Add `using System.Security.Cryptography;` at the top if not already present. (Other usings remain unchanged.)

(b) Add a new private field after line 47 (after `private long _nextSequence;`):

```csharp
    private string _policyVersion = "";
```

(c) Inside `Ingest`, right after line 71 (`_transmissionPolicy = snapshot.TransmissionPolicy;`), recompute the hash:

```csharp
            _policyVersion = ComputePolicyVersion(
                _privacyClassifications,
                _transmissionPolicy.PathTransmitOverrides);
```

(d) In `GetContextStates`, update the return (lines 132–136) to include `PolicyVersion`:

```csharp
            return new LocalContextStateResponse
            {
                ObservedAt = _latestObservedAt,
                States = states,
                PolicyVersion = _policyVersion
            };
```

(e) In `PollEvents`, update the return (lines 173–184):

```csharp
            return new LocalContextPollResponse
            {
                Events = returnedEvents,
                NextCursor = EncodeCursor(lastSequence),
                HasMore = matchingEvents.Count > limit,
                CursorExpired = cursorResult.Expired,
                Retention = new LocalContextRetentionInfo
                {
                    MaxAgeHours = _maxEventAgeHours,
                    MaxEvents = _maxEventCount
                },
                PolicyVersion = _policyVersion
            };
```

(f) Add the static helpers next to the sensitivity ones (after `LevelToSensitivity`):

```csharp
private static string ComputePolicyVersion(
    IReadOnlyList<PrivacyClassification> classifications,
    IReadOnlyDictionary<string, bool> overrides)
{
    var sb = new StringBuilder();

    foreach (var item in classifications.OrderBy(c => c.Path, StringComparer.OrdinalIgnoreCase))
    {
        sb.Append("c|").Append(item.Path).Append('|')
          .Append(NormalizeSensitivity(item.Sensitivity)).Append('|')
          .Append(item.DefaultTransmit ? '1' : '0').Append('\n');
    }

    foreach (var pair in overrides.OrderBy(p => p.Key, StringComparer.OrdinalIgnoreCase))
    {
        sb.Append("o|").Append(pair.Key).Append('|')
          .Append(pair.Value ? '1' : '0').Append('\n');
    }

    var hash = SHA256.HashData(Encoding.UTF8.GetBytes(sb.ToString()));
    // 9 バイト = base64url で 12 文字。衝突確率は実用上ゼロで、人間が見ても読みやすい長さ。
    return Convert.ToBase64String(hash, 0, 9)
        .TrimEnd('=')
        .Replace('+', '-')
        .Replace('/', '_');
}

public static string ComputePolicyVersionForTest(
    IReadOnlyList<PrivacyClassification> classifications,
    IReadOnlyDictionary<string, bool> overrides) =>
    ComputePolicyVersion(classifications, overrides);
```

- [ ] **Step 5: Run all tests to confirm pass**

```bash
dotnet test src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj
```

Expected: All tests pass (sensitivity + ingest + policy version).

- [ ] **Step 6: Commit**

```bash
rtk git add src/windows/AmbientContextMcp.Core/Hub/LocalContextHubModels.cs src/windows/AmbientContextMcp.Core/Hub/LocalContextHub.cs src/windows/AmbientContextMcp.Core.Tests/PolicyVersionTests.cs
rtk git commit -m "feat(hub): include policyVersion hash in poll and state responses"
```

---

## Task 5: Accept `context.all:read` alias

**Files:**
- Modify: `src/windows/AmbientContextMcp.Core/Hub/LocalContextHub.cs:578-590`
- Create: `src/windows/AmbientContextMcp.Core.Tests/ScopeAliasTests.cs`

Note: `GetAllowedLevel` already accepts `context.all:read` (Task 2 introduced it). However `IsSensitivityAllowed` is the legacy function still in use elsewhere (e.g. state filtering). This task aligns `IsSensitivityAllowed` and adds tests covering both surfaces.

- [ ] **Step 1: Add failing tests for `context.all:read`**

Create `src/windows/AmbientContextMcp.Core.Tests/ScopeAliasTests.cs`:

```csharp
using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Models;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class ScopeAliasTests
{
    [Fact]
    public void GetStates_with_context_all_returns_all_allowed_states()
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();
        hub.Ingest(new AmbientContextSnapshot
        {
            ObservedAt = DateTimeOffset.UtcNow,
            OutboundStates =
            [
                new() { Name = "presence.bucket", Value = "active", Sensitivity = "low" },
                new() { Name = "foregroundApp.category", Value = "code", Sensitivity = "medium" },
                new() { Name = "media.title", Value = "Imagine", Sensitivity = "high" }
            ]
        });

        var states = hub.GetContextStates(new LocalContextStateRequest
        {
            Scopes = ["context.all:read"]
        });

        Assert.Equal(3, states.States.Count);
    }

    [Fact]
    public void GetStates_with_context_all_equals_high()
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();
        hub.Ingest(new AmbientContextSnapshot
        {
            ObservedAt = DateTimeOffset.UtcNow,
            OutboundStates =
            [
                new() { Name = "presence.bucket", Value = "active", Sensitivity = "low" },
                new() { Name = "media.title", Value = "Imagine", Sensitivity = "high" }
            ]
        });

        var withAll = hub.GetContextStates(new LocalContextStateRequest { Scopes = ["context.all:read"] });
        var withHigh = hub.GetContextStates(new LocalContextStateRequest { Scopes = ["context.high:read"] });

        Assert.Equal(withHigh.States.Count, withAll.States.Count);
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
dotnet test src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj --filter "FullyQualifiedName~ScopeAliasTests"
```

Expected: `GetStates_with_context_all_returns_all_allowed_states` returns only 1 state (low) because `IsSensitivityAllowed` doesn't recognize `context.all:read`.

- [ ] **Step 3: Update `IsSensitivityAllowed` to recognize `context.all:read`**

Edit `src/windows/AmbientContextMcp.Core/Hub/LocalContextHub.cs` lines 578–590. Replace the function body:

```csharp
private static bool IsSensitivityAllowed(string sensitivity, IReadOnlyList<string> scopes)
{
    var requestedLevel = GetSensitivityLevel(sensitivity);
    var allowedLevel = GetAllowedLevel(scopes);
    return requestedLevel <= allowedLevel;
}
```

This deduplicates with `GetAllowedLevel` (introduced in Task 2), which already understands `context.all:read`.

- [ ] **Step 4: Run all tests to confirm pass**

```bash
dotnet test src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
rtk git add src/windows/AmbientContextMcp.Core/Hub/LocalContextHub.cs src/windows/AmbientContextMcp.Core.Tests/ScopeAliasTests.cs
rtk git commit -m "feat(hub): accept context.all:read as alias for context.high:read"
```

---

## Task 6: Update tool descriptions

**Files:**
- Modify: `src/windows/AmbientContextMcp.Core/Mcp/ContextTools.cs:22, 27, 43, 52`

- [ ] **Step 1: Update `GetStates` description**

Edit `src/windows/AmbientContextMcp.Core/Mcp/ContextTools.cs`. Replace the `[Description(...)]` on `GetStates` (line 22) with:

```csharp
    [Description("Returns the latest ambient context states. The response only includes items that satisfy BOTH (a) the user's transmission policy and (b) the client-supplied scope filter. The scope is the maximum sensitivity the client declares it can handle; raising it never bypasses the user's opt-in policy. The response includes a 'policyVersion' hash — clients can skip calling ambient_context_get_policy until that value changes. Use 'context.all:read' as a shorthand for 'I can handle anything the user permits'.")]
```

Replace the `scopes` parameter description (line 27):

```csharp
        [Description("Optional MCP context scopes declaring the maximum sensitivity this client handles: context.low:read, context.medium:read, context.high:read, or context.all:read (alias for high). Default is context.low:read. Raising the scope only widens the response within what the user has already opted in to; it cannot bypass the user's transmission policy.")]
```

- [ ] **Step 2: Update `PollEvents` description**

Replace the `[Description(...)]` on `PollEvents` (line 43):

```csharp
    [Description("Returns ambient context transition events such as idle/return, AC connect/disconnect, foreground app changes. By default this is a subscription-style call that returns events newer than the client's stored cursor and advances the cursor. When 'since' or 'until' is provided it becomes a stateless history query within that time range and the client cursor is NOT advanced, so the same range can be re-fetched. Each event also reports per-payload-key sensitivity ('payloadSensitivity') and the worst-case 'maxFieldSensitivity', so a client can tell at a glance whether raising its scope would reveal more fields. The response includes a 'policyVersion' hash — clients can skip calling ambient_context_get_policy until that value changes.")]
```

Replace the `scopes` parameter description (line 52):

```csharp
        [Description("Optional MCP context scopes: context.low:read, context.medium:read, context.high:read, or context.all:read (alias for high). Higher scopes reveal only medium/high data that the user's transmission policy already permits. Payload keys above the requested scope are dropped individually while the event itself can still be delivered if its event-level sensitivity is within scope.")]
```

- [ ] **Step 3: Build to confirm the descriptions still compile**

```bash
dotnet build src/windows/AmbientContextMcp.sln -c Debug
```

Expected: Build succeeded.

- [ ] **Step 4: Commit**

```bash
rtk git add src/windows/AmbientContextMcp.Core/Mcp/ContextTools.cs
rtk git commit -m "docs(mcp): describe per-field sensitivity, policyVersion, context.all:read in tool metadata"
```

---

## Task 7: Update docs/tool-spec.md

**Files:**
- Modify: `docs/tool-spec.md:69, 73-82, 95, 108-128, 158-178`

- [ ] **Step 1: Update `get_states` Output example (lines 73–82)**

Replace the existing Output block under `### ambient_context_get_states` with:

```json
{
  "observedAt": "2026-05-04T10:15:00+09:00",
  "source": "outboundStates",
  "states": [
    { "observedAt": "...", "name": "presence.bucket", "value": "active", "sensitivity": "low" },
    { "observedAt": "...", "name": "battery.percent", "value": "87", "sensitivity": "low" }
  ],
  "policyVersion": "Ab12-cD34_ef"
}
```

- [ ] **Step 2: Update the `scopes` bullet at line 69**

Replace:

```
- `scopes` 任意。省略時は `context.low:read` 相当 (= 低機微項目のみ)
```

with:

```
- `scopes` 任意。省略時は `context.low:read` 相当 (= 低機微項目のみ)。`context.all:read` を渡すと「ユーザーが許可している範囲をすべて」になり、`context.high:read` と等価
```

- [ ] **Step 3: Update `poll_events` Output example (lines 108–128)**

Replace the existing Output block under `### ambient_context_poll_events` with:

```json
{
  "events": [
    {
      "id": "evt_20260504_101501_000042",
      "sequence": 42,
      "observedAt": "2026-05-04T10:15:01+09:00",
      "name": "media_session_changed",
      "value": "Imagine",
      "payload": { "title": "Imagine", "source_app": "Chrome" },
      "sensitivity": "medium",
      "payloadSensitivity": { "title": "high", "source_app": "medium" },
      "maxFieldSensitivity": "high"
    }
  ],
  "nextCursor": "...",
  "hasMore": false,
  "cursorExpired": false,
  "retention": { "maxAgeHours": 24, "maxEvents": 500 },
  "policyVersion": "Ab12-cD34_ef"
}
```

- [ ] **Step 4: Add a new sub-section after Scope (after line 178) explaining `policyVersion`**

Insert immediately before `## 認証`:

```markdown
## policyVersion

`get_states` と `poll_events` の応答に含まれる短いハッシュ。`privacyClassifications` と `pathTransmitOverrides` の合成から導出され、ポリシーに変化があった場合にのみ値が変わります。

- 推奨利用: クライアントは前回受け取った `policyVersion` を保持し、変化したときだけ `ambient_context_get_policy` を呼び直す
- 値は不透明文字列 (約 12 文字)。バイト単位の意味はなく、等値比較のみが意味を持つ
- 同じプロセス内で `policyVersion` が同じ間は、同じ scope 指定で得られるフィールド集合も変わらない (= キャッシュ可能)

## payload 内の機微度

`poll_events` の各イベントには次の 2 フィールドが付与されます:

- `payloadSensitivity`: payload の各キーごとの機微度 (`"title": "high"` など)。該当 classification が無いキーは event-level `sensitivity` を継承
- `maxFieldSensitivity`: event-level `sensitivity` と `payloadSensitivity` のうち最も高いもの

scope が `maxFieldSensitivity` より低いと、payload はキー単位で間引かれて返ります。event 自体は `sensitivity` がスコープ内である限り削除されません。「event は通ったのに payload の一部キーが消えている」場合は、上位 scope (例: `context.high:read`) を渡せば取れる可能性があります。
```

- [ ] **Step 5: Commit**

```bash
rtk git add docs/tool-spec.md
rtk git commit -m "docs(tool-spec): document policyVersion, payloadSensitivity, context.all:read"
```

---

## Task 8: Integration smoke verification

**Files:** (no code changes; verification only)

- [ ] **Step 1: Run the full test suite one more time**

```bash
dotnet test src/windows/AmbientContextMcp.Core.Tests/AmbientContextMcp.Core.Tests.csproj
```

Expected: All tests pass.

- [ ] **Step 2: Build the full solution in Release config**

```bash
dotnet build src/windows/AmbientContextMcp.sln -c Release
```

Expected: Build succeeded.

- [ ] **Step 3: Smoke-check that the persisted events.jsonl still round-trips**

Open `events.jsonl` in `%LOCALAPPDATA%\AmbientContextMcp\` (if present) and confirm visually that any old entries deserialize without throwing. Old entries lack `payloadSensitivity` / `maxFieldSensitivity` — they should still load and behave correctly (filter falls back to event-level `Sensitivity`).

Run the app:

```powershell
dotnet run --project src/windows/AmbientContextMcp/AmbientContextMcp.csproj -c Debug
```

Expected: App starts without throwing, events.jsonl loads cleanly. Stop with Ctrl+C.

- [ ] **Step 4: Manually exercise the MCP tools (optional but recommended)**

With the app running, send a `poll_events` call via your MCP client of choice with `scopes: ["context.medium:read"]` after generating a `media_session_changed` event (e.g., switch tracks in Spotify / a browser tab). Confirm in the response:

- `payloadSensitivity` map is present
- `maxFieldSensitivity` is `"high"`
- `payload` does not include `title` / `artist` (they were stripped at medium scope)
- `policyVersion` is a short non-empty string

Then re-call with `scopes: ["context.all:read"]` and confirm `title` / `artist` reappear (assuming user has opted in to those paths; if not, this confirms the policy gate is still enforced).

- [ ] **Step 5: Commit nothing (verification step). If integration revealed issues, fix them and amend the relevant task's commit.**

---

## Self-Review checklist (already addressed)

- **Spec coverage:** Tasks 1–3 from the spec map to Tasks 1–6 in this plan (1 → Tasks 1–3, 2 → Task 4, 3 → Task 5; docs in Tasks 6–7; verification in Task 8). Test scaffold is Task 0.
- **Placeholders:** None — every step has either complete code or an exact command with expected output.
- **Type consistency:** `LocalContextEvent.PayloadSensitivity` is `IReadOnlyDictionary<string, string>` everywhere. `MaxFieldSensitivity` / `PolicyVersion` are `string`. `GetAllowedLevel` / `ComputePolicyVersion` signatures match between definition and test-callsites. `LevelToSensitivity` returns the same set of literals (`"low"` / `"medium"` / `"high"`) that the rest of the code consumes.
- **Known soft spot:** `LocalContextHubTestFactory` references `ISettingsStore`. The exact interface is at `src/windows/AmbientContextMcp.Core/Settings/ISettingsStore.cs`. Task 3 Step 1 calls this out and instructs the engineer to align the dummy implementation to the actual contract — keep it stateless and return defaults. No new abstraction.
