namespace FabricOEESimulator.Configuration;

public sealed class SimulatorConfig
{
    public int TelemetryIntervalSeconds { get; set; } = 10;
    public BrokerConfig Broker { get; set; } = new();
    public MaintenanceConfig Maintenance { get; set; } = new();
    public List<LineConfig> Lines { get; set; } = [];
}
