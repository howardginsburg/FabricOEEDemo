namespace FabricOEESimulator.Wpf.Models;

/// <summary>Fixed work-order lifecycle durations, used instead of the random config delays.</summary>
public sealed record MaintenanceTiming(TimeSpan Acknowledge, TimeSpan InProgress, TimeSpan Resolve);

/// <summary>
/// A fault for a station to run. Random faults carry no label or timing; demo-scenario
/// faults carry the scenario name and, optionally, a fixed maintenance timing.
/// </summary>
public sealed record FaultRequest(string? ScenarioLabel, MaintenanceTiming? Timing)
{
    public static readonly FaultRequest Random = new(null, null);
}
