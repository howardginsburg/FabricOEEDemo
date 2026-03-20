namespace FabricOEESimulator.Wpf.Models;

public enum MachineStatus
{
    Running,
    IdleStarved,
    IdleBlocked,
    Fault,
    Maintenance
}

public static class MachineStatusExtensions
{
    public static string ToTelemetryString(this MachineStatus status) => status switch
    {
        MachineStatus.Running => "Running",
        MachineStatus.IdleStarved => "Idle",
        MachineStatus.IdleBlocked => "Idle",
        MachineStatus.Fault => "Fault",
        MachineStatus.Maintenance => "Maintenance",
        _ => "Unknown"
    };

    public static string? ToIdleReason(this MachineStatus status) => status switch
    {
        MachineStatus.IdleStarved => "Starved",
        MachineStatus.IdleBlocked => "Blocked",
        _ => null
    };
}
