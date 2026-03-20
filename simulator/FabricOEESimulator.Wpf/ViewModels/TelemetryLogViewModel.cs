using System.Collections.ObjectModel;
using FabricOEESimulator.Wpf.Telemetry;

namespace FabricOEESimulator.Wpf.ViewModels;

public sealed class TelemetryEntryViewModel
{
    public DateTime Timestamp { get; init; }
    public string EventType { get; init; } = string.Empty;
    public string DeviceId { get; init; } = string.Empty;
    public string LineId { get; init; } = string.Empty;
    public string JsonPayload { get; init; } = string.Empty;
}

public sealed class TelemetryLogViewModel : ViewModelBase
{
    private readonly TelemetryLog _log;

    public TelemetryLogViewModel(TelemetryLog log)
    {
        _log = log;
    }

    public ObservableCollection<TelemetryEntryViewModel> Entries { get; } = [];

    private string _filterEventType = "All";
    public string FilterEventType
    {
        get => _filterEventType;
        set
        {
            if (SetProperty(ref _filterEventType, value))
                Refresh();
        }
    }

    public void Refresh()
    {
        var recent = _log.GetRecent();
        Entries.Clear();

        foreach (var entry in recent.Reverse())
        {
            if (_filterEventType != "All" && entry.EventType != _filterEventType)
                continue;

            Entries.Add(new TelemetryEntryViewModel
            {
                Timestamp = entry.Timestamp,
                EventType = entry.EventType,
                DeviceId = entry.DeviceId,
                LineId = entry.LineId,
                JsonPayload = entry.JsonPayload
            });
        }
    }
}
