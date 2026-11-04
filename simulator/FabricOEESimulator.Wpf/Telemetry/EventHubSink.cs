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

    // Fail fast: a send that can't reach the Eventstream gives up within seconds instead of stalling its station.
    private static readonly EventHubProducerClientOptions ProducerOptions = new()
    {
        RetryOptions = new EventHubsRetryOptions
        {
            Mode = EventHubsRetryMode.Exponential,
            MaximumRetries = 2,
            Delay = TimeSpan.FromSeconds(1),
            MaximumDelay = TimeSpan.FromSeconds(5),
            TryTimeout = TimeSpan.FromSeconds(15)
        }
    };

    private readonly BrokerConfig _config;
    private readonly TelemetryLog _telemetryLog;
    private readonly ILogger<EventHubSink> _logger;
    private EventHubProducerClient? _producer;
    private int _failing;
    private long _dropped;

    public EventHubSink(BrokerConfig config, TelemetryLog telemetryLog, ILogger<EventHubSink> logger)
    {
        _config = config;
        _telemetryLog = telemetryLog;
        _logger = logger;
    }

    public Task InitializeAsync(CancellationToken ct)
    {
        if (string.IsNullOrEmpty(_config.Connection))
            throw new InvalidOperationException("EventHub connection string is required.");

        _producer = string.IsNullOrEmpty(_config.Hub)
            ? new EventHubProducerClient(_config.Connection, ProducerOptions)
            : new EventHubProducerClient(_config.Connection, _config.Hub, ProducerOptions);

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

        try
        {
            await _producer.SendAsync([eventData], options, ct);
        }
        catch (Exception ex) when (!ct.IsCancellationRequested)
        {
            // The Eventstream can be unreachable for a while, such as when its capacity is paused or throttled.
            // Drop the event and keep the floor running; report the outage once, and the recovery once.
            Interlocked.Increment(ref _dropped);
            if (Interlocked.Exchange(ref _failing, 1) == 0)
            {
                _logger.LogWarning(ex, "Sending to the Eventstream failed; dropping events until it recovers");
                _telemetryLog.Record("send_error", string.Empty, string.Empty, ex.Message);
            }
            return;
        }

        if (Interlocked.Exchange(ref _failing, 0) == 1)
        {
            var dropped = Interlocked.Exchange(ref _dropped, 0);
            _logger.LogInformation("Sending to the Eventstream recovered after {Dropped} dropped events", dropped);
            _telemetryLog.Record("send_recovered", string.Empty, string.Empty,
                $"{dropped} events were dropped while the Eventstream was unreachable");
        }
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
