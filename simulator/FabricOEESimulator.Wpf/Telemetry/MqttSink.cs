using System.Text;
using System.Text.Json;
using FabricOEESimulator.Wpf.Configuration;
using Microsoft.Extensions.Logging;
using MQTTnet;

namespace FabricOEESimulator.Wpf.Telemetry;

public sealed class MqttSink : ITelemetrySink
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    private readonly BrokerConfig _config;
    private readonly ILogger<MqttSink> _logger;
    private IMqttClient? _client;

    public MqttSink(BrokerConfig config, ILogger<MqttSink> logger)
    {
        _config = config;
        _logger = logger;
    }

    public async Task InitializeAsync(CancellationToken ct)
    {
        if (string.IsNullOrEmpty(_config.Host))
            throw new InvalidOperationException("MQTT host is required.");

        var factory = new MqttClientFactory();
        _client = factory.CreateMqttClient();

        var optionsBuilder = new MqttClientOptionsBuilder()
            .WithTcpServer(_config.Host, _config.Port)
            .WithCleanSession();

        if (!string.IsNullOrEmpty(_config.Username))
            optionsBuilder.WithCredentials(_config.Username, _config.Password);

        var options = optionsBuilder.Build();
        await _client.ConnectAsync(options, ct);
        _logger.LogInformation("MQTT sink connected to {Host}:{Port}", _config.Host, _config.Port);
    }

    public async Task SendAsync(TelemetryEvent evt, CancellationToken ct)
    {
        if (_client is null || !_client.IsConnected)
            throw new InvalidOperationException("MQTT sink not connected.");

        var json = JsonSerializer.Serialize(evt, evt.GetType(), JsonOptions);
        var topic = ResolveTopic(evt);

        var message = new MqttApplicationMessageBuilder()
            .WithTopic(topic)
            .WithPayload(Encoding.UTF8.GetBytes(json))
            .WithQualityOfServiceLevel(MQTTnet.Protocol.MqttQualityOfServiceLevel.AtLeastOnce)
            .Build();

        await _client.PublishAsync(message, ct);
    }

    private string ResolveTopic(TelemetryEvent evt)
    {
        var template = _config.Topic ?? "telemetry/{deviceId}";

        if (template.Contains("{lineId}", StringComparison.OrdinalIgnoreCase))
        {
            return evt switch
            {
                MachineTelemetryEvent m => template
                    .Replace("{lineId}", m.LineId.ToLowerInvariant(), StringComparison.OrdinalIgnoreCase)
                    .Replace("{deviceId}", m.DeviceId, StringComparison.OrdinalIgnoreCase),
                PartTelemetryEvent p => template
                    .Replace("{lineId}", p.LineId.ToLowerInvariant(), StringComparison.OrdinalIgnoreCase)
                    .Replace("{deviceId}", "parts", StringComparison.OrdinalIgnoreCase),
                MaintenanceTelemetryEvent m => template
                    .Replace("{lineId}", m.LineId.ToLowerInvariant(), StringComparison.OrdinalIgnoreCase)
                    .Replace("{deviceId}", "maintenance", StringComparison.OrdinalIgnoreCase),
                _ => template
                    .Replace("{lineId}", "unknown", StringComparison.OrdinalIgnoreCase)
                    .Replace("{deviceId}", "unknown", StringComparison.OrdinalIgnoreCase)
            };
        }

        var deviceId = evt switch
        {
            MachineTelemetryEvent m => m.DeviceId,
            MaintenanceTelemetryEvent m => m.DeviceId,
            PartTelemetryEvent p => p.PartId,
            _ => "unknown"
        };

        return template.Replace("{deviceId}", deviceId, StringComparison.OrdinalIgnoreCase);
    }

    public async ValueTask DisposeAsync()
    {
        if (_client is not null)
        {
            if (_client.IsConnected)
                await _client.DisconnectAsync(new MqttClientDisconnectOptions());
            _client.Dispose();
            _client = null;
        }
    }
}
