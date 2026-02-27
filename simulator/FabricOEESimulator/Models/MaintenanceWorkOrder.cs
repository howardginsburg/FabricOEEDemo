namespace FabricOEESimulator.Models;

public enum WorkOrderStatus
{
    Created,
    Acknowledged,
    InProgress,
    Resolved
}

public sealed class MaintenanceWorkOrder
{
    private readonly TaskCompletionSource _resolved = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static int _counter;

    public string Id { get; }
    public string DeviceId { get; }
    public string MachineType { get; }
    public string LineId { get; }
    public int StationPosition { get; }
    public string IssueType { get; }
    public string TechnicianId { get; set; } = string.Empty;
    public WorkOrderStatus Status { get; set; } = WorkOrderStatus.Created;

    public DateTime CreatedAtUtc { get; }
    public DateTime? AcknowledgedAtUtc { get; set; }
    public DateTime? InProgressAtUtc { get; set; }
    public DateTime? ResolvedAtUtc { get; set; }

    public MaintenanceWorkOrder(string deviceId, string machineType, string lineId, int stationPosition, string issueType)
    {
        Id = $"WO-{Interlocked.Increment(ref _counter):D5}";
        DeviceId = deviceId;
        MachineType = machineType;
        LineId = lineId;
        StationPosition = stationPosition;
        IssueType = issueType;
        CreatedAtUtc = DateTime.UtcNow;
    }

    public Task WaitForResolutionAsync(CancellationToken ct)
    {
        ct.Register(() => _resolved.TrySetCanceled(ct));
        return _resolved.Task;
    }

    public void MarkResolved()
    {
        ResolvedAtUtc = DateTime.UtcNow;
        Status = WorkOrderStatus.Resolved;
        _resolved.TrySetResult();
    }
}
