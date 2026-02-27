namespace FabricOEESimulator.Configuration;

public sealed class LineConfig
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string Purpose { get; set; } = string.Empty;
    public List<StationConfig> Stations { get; set; } = [];
}
