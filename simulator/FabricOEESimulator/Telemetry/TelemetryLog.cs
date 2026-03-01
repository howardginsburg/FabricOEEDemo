using System.Collections.Concurrent;

namespace FabricOEESimulator.Telemetry;

public sealed class TelemetryLog
{
    private readonly ConcurrentQueue<TelemetryLogEntry> _entries = new();
    private readonly int _maxEntries;

    public TelemetryLog(int maxEntries = 5)
    {
        _maxEntries = maxEntries;
    }

    public void Record(string eventType, string deviceId, string lineId, string jsonPayload)
    {
        _entries.Enqueue(new TelemetryLogEntry(DateTime.UtcNow, eventType, deviceId, lineId, jsonPayload));

        while (_entries.Count > _maxEntries)
            _entries.TryDequeue(out _);
    }

    public IReadOnlyList<TelemetryLogEntry> GetRecent() => _entries.ToArray();
}

public readonly record struct TelemetryLogEntry(
    DateTime Timestamp,
    string EventType,
    string DeviceId,
    string LineId,
    string JsonPayload);
