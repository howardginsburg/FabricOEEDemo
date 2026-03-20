namespace FabricOEESimulator.Wpf.Configuration;

public sealed class StationConfig
{
    public int Position { get; set; }
    public string MachineType { get; set; } = string.Empty;
    public double IdealCycleTimeSeconds { get; set; }
    public double MaxCycleTimeSeconds { get; set; }
    public double FaultProbability { get; set; }
    public double RejectProbability { get; set; }
    public int BufferCapacity { get; set; } = 5;
    public List<string> FaultTypes { get; set; } = [];
}
