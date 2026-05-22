using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace AmbientContextMcp.Settings;

public sealed class TransmissionOptionViewModel : INotifyPropertyChanged
{
    private bool _isAllowed;

    public string Id { get; init; } = "";

    public string PrimaryPath { get; init; } = "";

    public string Label { get; init; } = "";

    public string Sensitivity { get; init; } = "medium";

    public IReadOnlyList<string> LinkedPaths { get; init; } = [];

    public bool IsAllowed
    {
        get => _isAllowed;
        set
        {
            if (_isAllowed == value)
            {
                return;
            }

            _isAllowed = value;
            OnPropertyChanged();
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
