using FabricOEESimulator.Wpf.Models;

namespace FabricOEESimulator.Wpf.Configuration;

/// <summary>Durations and intensities for the on-demand demo scenarios.</summary>
public sealed class ScenarioConfig
{
    public int RepeatFaultCount { get; set; } = 3;
    public int QuickFixStepMinSeconds { get; set; } = 10;
    public int QuickFixStepMaxSeconds { get; set; } = 20;
    public int LongOutageMinutes { get; set; } = 6;
    public int RejectSpikeMinutes { get; set; } = 10;
    public double RejectSpikeProbability { get; set; } = 0.35;
    public int SlowCycleMinutes { get; set; } = 10;
    public double SlowCycleMultiplier { get; set; } = 1.8;

    /// <summary>Short acknowledge / in-progress / resolve steps so repeat faults fit in a few minutes.</summary>
    public MaintenanceTiming QuickFixTiming(Random random) =>
        new(QuickFixStep(random), QuickFixStep(random), QuickFixStep(random));

    /// <summary>Sizes the work order so fault-to-resolution lasts <see cref="LongOutageMinutes"/>.</summary>
    public MaintenanceTiming LongOutageTiming(TimeSpan faultPhase)
    {
        var acknowledge = TimeSpan.FromSeconds(30);
        var inProgress = TimeSpan.FromSeconds(60);
        var resolve = TimeSpan.FromMinutes(LongOutageMinutes) - faultPhase - acknowledge - inProgress;
        return new MaintenanceTiming(acknowledge, inProgress, resolve > TimeSpan.Zero ? resolve : TimeSpan.FromSeconds(30));
    }

    private TimeSpan QuickFixStep(Random random) =>
        TimeSpan.FromSeconds(random.Next(QuickFixStepMinSeconds, QuickFixStepMaxSeconds + 1));
}
