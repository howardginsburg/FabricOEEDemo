using System.Text;
using System.Text.Json;
using Azure.Messaging.EventHubs;
using Azure.Messaging.EventHubs.Producer;
using FabricOEESimulator.Wpf.Configuration;
using Microsoft.Extensions.Logging;

namespace FabricOEESimulator.Wpf.Telemetry;

public sealed class EventHubSink : ITelemetrySink
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    private readonly BrokerConfig _config;
    private readonly ILogger<EventHubSink> _logger;
    private EventHubProducerClient? _producer;

    public EventHubSink(BrokerConfig config, ILogger<EventHubSink> logger)
    {
        _config = config;
        _logger = logger;
    }

    public Task InitializeAsync(CancellationToken ct)
    {
        if (string.IsNullOrEmpty(_config.Connection))
            throw new InvalidOperationException("EventHub connection string is required.");

        _producer = string.IsNullOrEmpty(_config.Hub)
            ? new EventHubProducerClient(_config.Connection)
            : new EventHubProducerClient(_config.Connection, _config.Hub);

        _logger.LogInformation("EventHub sink initialized");
        return Task.CompletedTask;
    }

    public async Task SendAsync(TelemetryEvent evt, CancellationToken ct)
    {
        if (_producer is null)
            throw new InvalidOperationException("EventHub sink not initialized.");

        var json = JsonSerializer.Serialize(evt, evt.GetType(), JsonOptions);
        var eventData = new EventData(Encoding.UTF8.GetBytes(json));

        var partitionKey = evt switch
        {
            MachineTelemetryEvent m => m.DeviceId,
            MaintenanceTelemetryEvent m => m.DeviceId,
            PartTelemetryEvent p => p.PartId,
            _ => null
        };

        var options = partitionKey is not null
            ? new SendEventOptions { PartitionKey = partitionKey }
            : new SendEventOptions();

        await _producer.SendAsync([eventData], options, ct);
    }

    public async ValueTask DisposeAsync()
    {
        if (_producer is not null)
        {
            await _producer.DisposeAsync();
            _producer = null;
        }
    }
}
