namespace AmbientContextMcp.Core.Models;

/// <summary>
/// 設定ダイアログ向けの送信オプション定義。MCP path は <see cref="TransmissionUiOptionDefinition.LinkedPaths"/> に束ね、
/// UI では意味単位のチェックボックス 1 つで state + event を同時に opt-in する。
/// <see cref="TransmissionUiOptionDefinition.PrimaryPath"/> は Load 時のチェック状態判定に使う (共有 path の誤表示を防ぐ)。
/// Save 時は ON オプションの LinkedPaths の和集合を書き出す。
/// </summary>
public static partial class AmbientContextCatalog
{
    public static IReadOnlyList<TransmissionUiGroupDefinition> GetTransmissionUiGroups()
    {
        var classifications = GetPrivacyClassifications()
            .ToDictionary(item => item.Path, StringComparer.OrdinalIgnoreCase);

        return
        [
            Group(
                "foregroundApp",
                Options(
                    Option("foreground.identity", "foregroundApp.category", ["foregroundApp.category", "foregroundApp.appName", "foregroundApp.processName", "events.foreground_changed"], classifications),
                    Option("foreground.titleSummary", "foregroundApp.titleSummary", ["foregroundApp.titleSummary", "events.foreground_title_changed", "events.foreground_title_changed.titleSummary"], classifications),
                    Option("foreground.rawTitle", "foregroundApp.rawWindowTitle", ["foregroundApp.rawWindowTitle", "events.foreground_title_changed", "events.foreground_title_changed.raw_window_title"], classifications))),
            Group(
                "activity",
                Options(
                    Option("activity.switchRate", "activity.contextSwitchesPerMin", ["activity.contextSwitchesPerMin"], classifications),
                    Option("activity.switchBurst", "events.context_switch_burst", ["events.context_switch_burst"], classifications))),
            Group(
                "media",
                Options(
                    Option("media.overview", "media.isAvailable", ["media.isAvailable", "media.playbackStatus", "media.sourceAppUserModelId", "events.media_playback_started", "events.media_playback_paused", "events.media_session_changed"], classifications),
                    Option("media.title", "media.title", ["media.title", "events.media_session_changed", "events.media_session_changed.title"], classifications),
                    Option("media.artist", "media.artist", ["media.artist", "events.media_session_changed", "events.media_session_changed.artist"], classifications),
                    Option("media.album", "media.albumTitle", ["media.albumTitle", "events.media_session_changed", "events.media_session_changed.album_title"], classifications))),
            Group(
                "environment",
                Options(
                    Option("environment.timezone", "system.timeZoneId", ["system.timeZoneId", "events.timezone_changed"], classifications),
                    Option("environment.displays", "displays", ["display.count", "displays", "events.display_count_changed"], classifications)))
        ];
    }

    /// <summary>
    /// UI 定義から distinct な path 一覧をフラット化する。主にテストで
    /// LinkedPaths が privacy catalog と整合していることを検証するために使う。
    /// </summary>
    public static IReadOnlyList<TransmissionOptionDefinition> GetTransmissionOptions()
    {
        var classifications = GetPrivacyClassifications()
            .ToDictionary(item => item.Path, StringComparer.OrdinalIgnoreCase);

        return GetTransmissionUiGroups()
            .SelectMany(group => group.Options)
            .SelectMany(option => option.LinkedPaths)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Select(path => new TransmissionOptionDefinition
            {
                Path = classifications[path].Path,
                Sensitivity = classifications[path].Sensitivity
            })
            .ToList();
    }

    private static TransmissionUiGroupDefinition Group(
        string id,
        IReadOnlyList<TransmissionUiOptionDefinition> options) =>
        new()
        {
            Id = id,
            Options = options
        };

    private static IReadOnlyList<TransmissionUiOptionDefinition> Options(
        params TransmissionUiOptionDefinition[] options) =>
        options;

    private static TransmissionUiOptionDefinition Option(
        string id,
        string primaryPath,
        string[] linkedPaths,
        IReadOnlyDictionary<string, PrivacyClassification> classifications)
    {
        if (!linkedPaths.Contains(primaryPath, StringComparer.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"PrimaryPath '{primaryPath}' must be included in LinkedPaths for option '{id}'.");
        }

        return new TransmissionUiOptionDefinition
        {
            Id = id,
            PrimaryPath = primaryPath,
            Sensitivity = ResolveMaxSensitivity(linkedPaths, classifications),
            LinkedPaths = linkedPaths
        };
    }

    private static string ResolveMaxSensitivity(
        IReadOnlyList<string> linkedPaths,
        IReadOnlyDictionary<string, PrivacyClassification> classifications)
    {
        var maxLevel = 0;
        var result = "low";
        foreach (var path in linkedPaths)
        {
            var sensitivity = classifications[path].Sensitivity;
            var level = SensitivityLevel(sensitivity);
            if (level > maxLevel)
            {
                maxLevel = level;
                result = sensitivity;
            }
        }

        return result;
    }

    private static int SensitivityLevel(string sensitivity)
    {
        return sensitivity.ToLowerInvariant() switch
        {
            "high" => 3,
            "medium" => 2,
            _ => 1
        };
    }
}

public sealed class TransmissionUiGroupDefinition
{
    public string Id { get; init; } = "";

    public IReadOnlyList<TransmissionUiOptionDefinition> Options { get; init; } = [];
}

public sealed class TransmissionUiOptionDefinition
{
    public string Id { get; init; } = "";

    public string PrimaryPath { get; init; } = "";

    public string Sensitivity { get; init; } = "medium";

    public IReadOnlyList<string> LinkedPaths { get; init; } = [];
}
