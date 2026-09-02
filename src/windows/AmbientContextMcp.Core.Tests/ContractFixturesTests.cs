using System.Globalization;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Mcp;
using AmbientContextMcp.Core.Models;
using AmbientContextMcp.Core.Policy;
using AmbientContextMcp.Core.Settings;
using Microsoft.Extensions.DependencyInjection;
using ModelContextProtocol;
using ModelContextProtocol.Server;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

/// <summary>
/// macOS 移植 (src/macos) 向けの契約フィクスチャ生成器。
/// 詳細は docs/superpowers/specs/2026-09-03-macos-port-design.md §5 "drift 対策"。
///
/// この 1 つの [Fact] が src/macos/Fixtures/contract/*.json を上書き生成し、
/// 生成結果を読み直して parse できることを検証する。出力は決定的 (順序固定・時刻なし)
/// なので、CI では再生成後の `git diff --exit-code` で C#/Swift の drift を検出できる。
/// </summary>
public class ContractFixturesTests
{
    [Fact]
    public void GeneratesContractFixtures()
    {
        var outputDirectory = ResolveFixtureDirectory();
        Directory.CreateDirectory(outputDirectory);

        var written = new List<string>();

        void Write(string fileName, string json)
        {
            WriteFixture(Path.Combine(outputDirectory, fileName), json);
            written.Add(fileName);
        }

        Write("privacy-classifications.en.json",
            WithCulture("en-US", () => Serialize(AmbientContextCatalog.GetPrivacyClassifications())));
        Write("privacy-classifications.ja.json",
            WithCulture("ja-JP", () => Serialize(AmbientContextCatalog.GetPrivacyClassifications())));

        Write("event-schemas.en.json",
            WithCulture("en-US", () => Serialize(AmbientContextCatalog.GetEventSchemas())));
        Write("event-schemas.ja.json",
            WithCulture("ja-JP", () => Serialize(AmbientContextCatalog.GetEventSchemas())));

        Write("transmission-ui-groups.json", Serialize(AmbientContextCatalog.GetTransmissionUiGroups()));

        Write("tools-list.json", BuildToolsListJson());
        Write("policy-version.json", BuildPolicyVersionJson());
        Write("cursor-encoding.json", BuildCursorEncodingJson());
        Write("transmission-policy-cases.json", BuildTransmissionPolicyCasesJson());

        // 生成物を読み直して parse できることを確認する (Swift 側は同じ JSON を読む)。
        foreach (var fileName in written)
        {
            var path = Path.Combine(outputDirectory, fileName);
            Assert.True(File.Exists(path), $"fixture not written: {path}");

            var text = File.ReadAllText(path, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            Assert.False(text.Contains('\r'), $"fixture must use LF line endings: {fileName}");
            Assert.EndsWith("\n", text);

            using var document = JsonDocument.Parse(text);
            Assert.True(
                document.RootElement.ValueKind is JsonValueKind.Array or JsonValueKind.Object,
                $"fixture root must be an array or object: {fileName}");
        }

        Assert.Equal(9, written.Count);
    }

    // ------------------------------------------------------------------
    // 1-3. catalog fixtures
    // ------------------------------------------------------------------

    private static string Serialize<T>(T value) =>
        JsonSerializer.Serialize(value, AmbientContextJson.Options);

    private static T WithCulture<T>(string cultureName, Func<T> action)
    {
        var previousUi = CultureInfo.CurrentUICulture;
        var previous = CultureInfo.CurrentCulture;
        try
        {
            var culture = CultureInfo.GetCultureInfo(cultureName);
            CultureInfo.CurrentUICulture = culture;
            CultureInfo.CurrentCulture = culture;
            return action();
        }
        finally
        {
            CultureInfo.CurrentUICulture = previousUi;
            CultureInfo.CurrentCulture = previous;
        }
    }

    // ------------------------------------------------------------------
    // 4. tools/list
    // ------------------------------------------------------------------

    /// <summary>
    /// Desktop ホストは Windows 専用なので実サーバは起動できない。代わりに
    /// <c>WithTools&lt;ContextTools&gt;()</c> と同じ反射 API (<see cref="McpServerTool.Create(MethodInfo, object?, McpServerToolCreateOptions?)"/>)
    /// で ProtocolTool を組み立てて tools/list 相当の JSON にする。
    /// LocalContextHub は DI 注入パラメータなので inputSchema に漏れてはいけない。
    /// SDK は <see cref="McpServerToolCreateOptions.Services"/> の
    /// <see cref="IServiceProviderIsService"/> で判定するため、実ホストと同じく
    /// ServiceCollection 由来のプロバイダを渡す。
    /// </summary>
    private static string BuildToolsListJson()
    {
        var options = new McpServerToolCreateOptions
        {
            Services = new HubServiceProvider()
        };

        var tools = typeof(ContextTools)
            .GetMethods(BindingFlags.Public | BindingFlags.Static)
            .Where(method => method.GetCustomAttribute<McpServerToolAttribute>() is not null)
            .Select(method => McpServerTool.Create(method, target: null, options).ProtocolTool)
            .OrderBy(tool => tool.Name, StringComparer.Ordinal)
            .ToList();

        Assert.Equal(4, tools.Count);

        var serializerOptions = new JsonSerializerOptions(McpJsonUtilities.DefaultOptions)
        {
            WriteIndented = true
        };

        var payload = new JsonObject
        {
            ["tools"] = JsonSerializer.SerializeToNode(tools, serializerOptions)
        };

        var json = payload.ToJsonString(serializerOptions);

        // hub は DI 注入されるので inputSchema に現れてはいけない。
        Assert.DoesNotContain("\"hub\"", json);
        foreach (var expected in new[]
        {
            "clientId", "cursor", "names", "scopes", "limit", "since", "until", "includePayload",
            "includeMetadata"
        })
        {
            Assert.Contains($"\"{expected}\"", json);
        }

        return json;
    }

    /// <summary>
    /// SDK は「DI から解決できるパラメータ」を inputSchema から除外する。判定には
    /// <see cref="IServiceProviderIsService"/> を使うので、実ホストの
    /// <c>ServiceCollection.BuildServiceProvider()</c> と同じ振る舞いだけを最小実装する
    /// (テストプロジェクトに DI 実装パッケージを足さずに済ませるため)。
    /// </summary>
    private sealed class HubServiceProvider : IServiceProvider, IServiceProviderIsService
    {
        private readonly Lazy<LocalContextHub> _hub = new(LocalContextHubTestFactory.CreateInMemory);

        public bool IsService(Type serviceType) => serviceType == typeof(LocalContextHub);

        public object? GetService(Type serviceType)
        {
            // SDK は provider.GetService<IServiceProviderIsService>() を「サービスとして」引く。
            if (serviceType == typeof(IServiceProviderIsService))
            {
                return this;
            }

            return serviceType == typeof(LocalContextHub) ? _hub.Value : null;
        }
    }

    // ------------------------------------------------------------------
    // 5. policy version
    // ------------------------------------------------------------------

    private sealed record PolicyVersionCase(
        string Name,
        IReadOnlyList<PolicyVersionClassification> Classifications,
        IReadOnlyDictionary<string, bool> Overrides,
        string Expected);

    private sealed record PolicyVersionClassification(string Path, string Sensitivity, bool DefaultTransmit);

    private static string BuildPolicyVersionJson()
    {
        var catalog = AmbientContextCatalog.GetPrivacyClassifications();

        PolicyVersionCase Case(
            string name,
            IReadOnlyList<PrivacyClassification> classifications,
            Dictionary<string, bool> overrides) =>
            new(
                name,
                classifications
                    .Select(c => new PolicyVersionClassification(c.Path, c.Sensitivity, c.DefaultTransmit))
                    .ToList(),
                overrides,
                PolicyVersionService.ComputePolicyVersion(classifications, overrides));

        var cases = new List<PolicyVersionCase>
        {
            Case("full-catalog-no-overrides", catalog, []),
            Case("full-catalog-two-overrides", catalog, new Dictionary<string, bool>(StringComparer.Ordinal)
            {
                ["foregroundApp.category"] = true,
                ["media.title"] = false
            }),
            Case("empty-catalog-no-overrides", [], [])
        };

        return Serialize(cases);
    }

    // ------------------------------------------------------------------
    // 6. cursor / event id encoding
    // ------------------------------------------------------------------

    private sealed record CursorCase(long Sequence, string Cursor);

    private sealed record EventIdCase(string ObservedAtUtc, long Sequence, string Id);

    private sealed record CursorEncodingFixture(
        IReadOnlyList<CursorCase> Cursors,
        string EventIdFormat,
        IReadOnlyList<EventIdCase> EventIds);

    private static string BuildCursorEncodingJson()
    {
        var cursors = new long[] { 0, 1, 42, 1000000 }
            .Select(seq => new CursorCase(seq, LocalContextCursorTracker.Encode(seq)))
            .ToList();

        // CreateEventId は private static。固定 ObservedAt を Ingest する経路は保持期間
        // (maxEventAgeHours) で trim されて非決定的になるため、ここは反射で直接呼ぶ。
        var createEventId = typeof(LocalContextHub).GetMethod(
            "CreateEventId",
            BindingFlags.NonPublic | BindingFlags.Static);
        Assert.NotNull(createEventId);

        var observedAtValues = new[]
        {
            DateTimeOffset.Parse("2026-05-23T12:00:00.000+09:00", CultureInfo.InvariantCulture),
            DateTimeOffset.Parse("2026-05-23T12:00:01.250+09:00", CultureInfo.InvariantCulture),
            DateTimeOffset.Parse("2026-01-02T03:04:05.006+00:00", CultureInfo.InvariantCulture)
        };

        var eventIds = observedAtValues
            .Select((observedAt, index) => new EventIdCase(
                observedAt.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture),
                index + 1,
                (string)createEventId!.Invoke(null, [observedAt, (long)(index + 1)])!))
            .ToList();

        // 反射で得た id が Hub の実経路 (Ingest -> PollEvents) と一致することを確認する。
        AssertEventIdMatchesLivePath(createEventId);

        return Serialize(new CursorEncodingFixture(
            cursors,
            "evt_{observedAt.UtcDateTime:yyyyMMddHHmmssfff}_{sequence:D6}",
            eventIds));
    }

    private static void AssertEventIdMatchesLivePath(MethodInfo createEventId)
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();
        var observedAt = DateTimeOffset.Now;

        hub.Ingest(new AmbientContextSnapshot
        {
            ObservedAt = observedAt,
            PrivacyClassifications =
            [
                new() { Path = "events.fixture_event", Sensitivity = "low", DefaultTransmit = true }
            ],
            OutboundEvents =
            [
                new()
                {
                    ObservedAt = observedAt,
                    Name = "fixture_event",
                    Value = "0",
                    Sensitivity = "low"
                }
            ]
        });

        var poll = hub.PollEvents(new LocalContextPollRequest
        {
            ClientId = "contract-fixture",
            Scopes = ["context.all:read"],
            Since = observedAt.AddMinutes(-1),
            Limit = 10
        });

        var ev = Assert.Single(poll.Events);
        Assert.Equal(createEventId.Invoke(null, [ev.ObservedAt, ev.Sequence]), ev.Id);
        Assert.Equal(LocalContextCursorTracker.Encode(ev.Sequence), poll.NextCursor);
    }

    // ------------------------------------------------------------------
    // 7. transmission policy behavior
    // ------------------------------------------------------------------

    private sealed record StateInput(string Name, string Value, string Sensitivity);

    private sealed record EventInput(
        string Name,
        string Value,
        string Sensitivity,
        IReadOnlyDictionary<string, string> Payload);

    private sealed record FilterStatesCase(
        string Name,
        IReadOnlyDictionary<string, bool> Overrides,
        IReadOnlyList<StateInput> States,
        IReadOnlyList<string> ExpectedStateNames);

    private sealed record FilterEventsCase(
        string Name,
        IReadOnlyDictionary<string, bool> Overrides,
        EventInput Event,
        bool ExpectedDelivered,
        IReadOnlyList<string> ExpectedPayloadKeys);

    private sealed record MergeOverridesCase(
        string Name,
        IReadOnlyDictionary<string, bool> ExistingOverrides,
        IReadOnlyList<string> EnabledOptionIds,
        IReadOnlyDictionary<string, bool> ExpectedOverrides);

    private sealed record TransmissionPolicyFixture(
        IReadOnlyList<FilterStatesCase> FilterStates,
        IReadOnlyList<FilterEventsCase> FilterEvents,
        IReadOnlyList<MergeOverridesCase> MergeOverrides);

    private static string BuildTransmissionPolicyCasesJson()
    {
        var classifications = AmbientContextCatalog.GetPrivacyClassifications();

        var states = new List<StateInput>
        {
            new("presence.bucket", "active", "low"),
            new("presence.idleSeconds", "42", "medium"),
            new("foregroundApp.category", "editor", "medium"),
            new("foregroundApp.rawWindowTitle", "Program.cs - demo", "high"),
            new("media.title", "Imagine", "high"),
            new("battery.percent", "88", "low")
        };

        FilterStatesCase StatesCase(string name, Dictionary<string, bool> overrides)
        {
            var policy = LoadPolicy(overrides, classifications);
            var kept = policy.FilterStates(
                states
                    .Select(s => new AmbientState
                    {
                        ObservedAt = FixedObservedAt,
                        Name = s.Name,
                        Value = s.Value,
                        Sensitivity = s.Sensitivity
                    })
                    .ToList(),
                classifications);

            return new FilterStatesCase(name, overrides, states, kept.Select(s => s.Name).ToList());
        }

        var filterStates = new List<FilterStatesCase>
        {
            StatesCase("states-defaults-only", []),
            StatesCase("states-foreground-category-opt-in", new Dictionary<string, bool>(StringComparer.Ordinal)
            {
                ["foregroundApp.category"] = true
            }),
            StatesCase("states-explicit-deny-overrides-default", new Dictionary<string, bool>(StringComparer.Ordinal)
            {
                ["presence.bucket"] = false,
                ["media.title"] = true
            })
        };

        FilterEventsCase EventsCase(string name, Dictionary<string, bool> overrides, EventInput input)
        {
            var policy = LoadPolicy(overrides, classifications);
            var filtered = policy.FilterEvents(
            [
                new AmbientOutboundEvent
                {
                    ObservedAt = FixedObservedAt,
                    Name = input.Name,
                    Value = input.Value,
                    Sensitivity = input.Sensitivity,
                    Payload = new Dictionary<string, string>(input.Payload, StringComparer.OrdinalIgnoreCase)
                }
            ],
            classifications);

            var delivered = filtered.Count > 0;
            var payloadKeys = delivered
                ? input.Payload.Keys.Where(filtered[0].Payload.ContainsKey).ToList()
                : [];

            return new FilterEventsCase(name, overrides, input, delivered, payloadKeys);
        }

        var titleEvent = new EventInput(
            "foreground_title_changed",
            "true",
            "medium",
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["process_name"] = "Code.exe",
                ["titleSummary.file_ext"] = "cs",
                ["raw_window_title"] = "Program.cs - demo"
            });

        var mediaEvent = new EventInput(
            "media_session_changed",
            "Imagine",
            "medium",
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["source_app"] = "Chrome",
                ["title"] = "Imagine",
                ["artist"] = "John Lennon"
            });

        var presenceEvent = new EventInput(
            "presence_bucket_changed",
            "idle",
            "low",
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["from"] = "active",
                ["to"] = "idle"
            });

        var filterEvents = new List<FilterEventsCase>
        {
            // 既定送信 ON のイベントは override 無しでも payload ごと通る。
            EventsCase("events-default-transmit-low-event", [], presenceEvent),
            // 既定 OFF のイベントは override 無しでは落ちる。
            EventsCase("events-medium-event-dropped-without-opt-in", [], titleEvent),
            // 親 event を ON にしても high な payload key は個別 opt-in が要る。
            EventsCase("events-title-changed-strips-raw-title", new Dictionary<string, bool>(StringComparer.Ordinal)
            {
                ["events.foreground_title_changed"] = true,
                ["events.foreground_title_changed.titleSummary"] = true
            }, titleEvent),
            // raw_window_title の個別 opt-in で high key も通る。
            EventsCase("events-title-changed-raw-title-opt-in", new Dictionary<string, bool>(StringComparer.Ordinal)
            {
                ["events.foreground_title_changed"] = true,
                ["events.foreground_title_changed.raw_window_title"] = true
            }, titleEvent),
            // 分類のない payload key (source_app) は親 event の許可を継承する。
            EventsCase("events-media-overview-only", new Dictionary<string, bool>(StringComparer.Ordinal)
            {
                ["events.media_session_changed"] = true
            }, mediaEvent),
            EventsCase("events-media-title-opt-in", new Dictionary<string, bool>(StringComparer.Ordinal)
            {
                ["events.media_session_changed"] = true,
                ["events.media_session_changed.title"] = true
            }, mediaEvent)
        };

        var options = AmbientContextCatalog.GetTransmissionUiGroups()
            .SelectMany(group => group.Options)
            .ToList();

        MergeOverridesCase MergeCase(
            string name,
            Dictionary<string, bool> existing,
            string[] enabled)
        {
            var merged = TransmissionUiSettingsMerge.MergeOverrides(
                existing,
                options,
                new HashSet<string>(enabled, StringComparer.OrdinalIgnoreCase));

            return new MergeOverridesCase(
                name,
                existing,
                enabled,
                merged
                    .OrderBy(pair => pair.Key, StringComparer.Ordinal)
                    .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal));
        }

        var mergeOverrides = new List<MergeOverridesCase>
        {
            MergeCase("merge-media-overview-only", [], ["media.overview"]),
            MergeCase("merge-media-overview-and-title", [], ["media.overview", "media.title"]),
            MergeCase("merge-keeps-unmanaged-override", new Dictionary<string, bool>(StringComparer.Ordinal)
            {
                ["legacy.custom.path"] = true
            }, []),
            MergeCase("merge-disable-removes-managed-paths", new Dictionary<string, bool>(StringComparer.Ordinal)
            {
                ["media.title"] = true,
                ["events.media_session_changed"] = true
            }, [])
        };

        return Serialize(new TransmissionPolicyFixture(filterStates, filterEvents, mergeOverrides));
    }

    private static readonly DateTimeOffset FixedObservedAt =
        DateTimeOffset.Parse("2026-05-23T12:00:00+09:00", CultureInfo.InvariantCulture);

    private static AmbientTransmissionPolicy LoadPolicy(
        IReadOnlyDictionary<string, bool> overrides,
        IReadOnlyList<PrivacyClassification> classifications) =>
        AmbientTransmissionPolicy.Load(
            new FixtureSettingsStore(new AmbientTransmissionSettings
            {
                SchemaVersion = 1,
                PathTransmitOverrides = new Dictionary<string, bool>(overrides, StringComparer.OrdinalIgnoreCase)
            }),
            classifications);

    private sealed class FixtureSettingsStore(AmbientTransmissionSettings settings) : ISettingsStore
    {
        public string SettingsPath { get; } =
            Path.Combine(Path.GetTempPath(), "ambient-context-mcp-fixture", "settings.json");

        public AmbientTransmissionSettings LoadAmbientTransmissionSettings() => settings;
        public void SaveAmbientTransmissionSettings(AmbientTransmissionSettings value) { }
        public LocalContextSettings LoadLocalContextSettings() => new();
        public void SaveLocalContextSettings(LocalContextSettings value) { }
        public McpServerSettings LoadMcpServerSettings() => new();
        public void SaveMcpServerSettings(McpServerSettings value) { }
        public SettingsWindowStatus? LoadSettingsWindowStatus() => null;
        public void SaveSettingsWindowStatus(SettingsWindowStatus status) { }
        public UiSettings LoadUiSettings() => new();
        public void SaveUiSettings(UiSettings value) { }
        public TransientStateSettings LoadTransientStateSettings() => new();
        public void SaveTransientStateSettings(TransientStateSettings value) { }
    }

    // ------------------------------------------------------------------
    // output helpers
    // ------------------------------------------------------------------

    private static void WriteFixture(string path, string json)
    {
        var normalized = json.Replace("\r\n", "\n").Replace("\r", "\n");
        if (!normalized.EndsWith('\n'))
        {
            normalized += "\n";
        }

        // BOM なし UTF-8 / LF / 末尾改行 で決定的に書き出す。
        File.WriteAllText(path, normalized, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
    }

    private static string ResolveFixtureDirectory()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "mcpb", "manifest.json")))
            {
                return Path.Combine(directory.FullName, "src", "macos", "Fixtures", "contract");
            }

            directory = directory.Parent;
        }

        throw new InvalidOperationException(
            $"Repository root (containing mcpb/manifest.json) not found above '{AppContext.BaseDirectory}'.");
    }
}
