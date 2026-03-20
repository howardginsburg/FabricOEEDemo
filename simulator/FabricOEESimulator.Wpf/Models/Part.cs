namespace FabricOEESimulator.Wpf.Models;

public sealed class Part
{
    public string Id { get; }
    public string LineId { get; }
    public DateTime CreatedAtUtc { get; }
    public List<StationRecord> StationHistory { get; } = [];

    public Part(string id, string lineId)
    {
        Id = id;
        LineId = lineId;
        CreatedAtUtc = DateTime.UtcNow;
    }

    public void RecordStation(int position, string machineType, double cycleTime, bool qualityPass)
    {
        StationHistory.Add(new StationRecord(position, machineType, cycleTime, qualityPass, DateTime.UtcNow));
    }
}

public sealed record StationRecord(
    int Position,
    string MachineType,
    double CycleTime,
    bool QualityPass,
    DateTime TimestampUtc);
