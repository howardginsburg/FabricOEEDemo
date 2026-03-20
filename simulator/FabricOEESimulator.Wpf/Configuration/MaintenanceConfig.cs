namespace FabricOEESimulator.Wpf.Configuration;

public sealed class MaintenanceConfig
{
    public int AcknowledgeDelayMinSeconds { get; set; } = 30;
    public int AcknowledgeDelayMaxSeconds { get; set; } = 120;
    public int InProgressDelayMinSeconds { get; set; } = 60;
    public int InProgressDelayMaxSeconds { get; set; } = 300;
    public int ResolveDelayMinSeconds { get; set; } = 120;
    public int ResolveDelayMaxSeconds { get; set; } = 600;
    public List<string> Technicians { get; set; } = ["T001", "T002", "T003", "T004", "T005", "T006", "T007", "T008"];
}
