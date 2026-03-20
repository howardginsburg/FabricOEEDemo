using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace FabricOEESimulator.Wpf.Telemetry;

public sealed class ConsoleSink : ITelemetrySink
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    private readonly ILogger<ConsoleSink> _logger;

    public ConsoleSink(ILogger<ConsoleSink> logger)
    {
        _logger = logger;
    }

    public Task InitializeAsync(CancellationToken ct) => Task.CompletedTask;

    public Task SendAsync(TelemetryEvent evt, CancellationToken ct)
    {
        var json = JsonSerializer.Serialize(evt, evt.GetType(), JsonOptions);
        _logger.LogInformation("{EventType}: {Json}", evt.EventType, json);
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
