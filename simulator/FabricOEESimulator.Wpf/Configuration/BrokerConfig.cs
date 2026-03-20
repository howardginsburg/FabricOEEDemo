namespace FabricOEESimulator.Wpf.Configuration;

public sealed class BrokerConfig
{
    public string Type { get; set; } = "Console";
    public string? Connection { get; set; }
    public string? Hub { get; set; }
    public string? Host { get; set; }
    public int Port { get; set; } = 1883;
    public string? Topic { get; set; }
    public string? Username { get; set; }
    public string? Password { get; set; }
    public string? CaCert { get; set; }
    public string? ClientCert { get; set; }
    public string? ClientKey { get; set; }
}
