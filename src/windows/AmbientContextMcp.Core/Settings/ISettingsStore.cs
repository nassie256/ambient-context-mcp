namespace AmbientContextMcp.Core.Settings;

public interface ISettingsStore
{
    string SettingsPath { get; }

    AmbientTransmissionSettings LoadAmbientTransmissionSettings();

    void SaveAmbientTransmissionSettings(AmbientTransmissionSettings settings);

    LocalContextSettings LoadLocalContextSettings();

    void SaveLocalContextSettings(LocalContextSettings settings);

    McpServerSettings LoadMcpServerSettings();

    void SaveMcpServerSettings(McpServerSettings settings);

    SettingsWindowStatus? LoadSettingsWindowStatus();

    void SaveSettingsWindowStatus(SettingsWindowStatus status);

    UiSettings LoadUiSettings();

    void SaveUiSettings(UiSettings settings);

    TransientStateSettings LoadTransientStateSettings();

    void SaveTransientStateSettings(TransientStateSettings settings);
}
