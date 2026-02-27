using System.Text.Json.Serialization;

namespace FabricOEESimulator.Telemetry;

public interface ITelemetrySink : IAsyncDisposable
{
    Task InitializeAsync(CancellationToken ct);
    Task SendAsync(TelemetryEvent evt, CancellationToken ct);
}

[JsonDerivedType(typeof(MachineTelemetryEvent))]
[JsonDerivedType(typeof(PartTelemetryEvent))]
[JsonDerivedType(typeof(MaintenanceTelemetryEvent))]
public abstract class TelemetryEvent
{
    [JsonPropertyName("event_type")]
    public abstract string EventType { get; }

    [JsonPropertyName("timestamp")]
    public DateTime Timestamp { get; set; } = DateTime.UtcNow;
}

public sealed class MachineTelemetryEvent : TelemetryEvent
{
    [JsonPropertyName("event_type")]
    public override string EventType => "machine_telemetry";

    [JsonPropertyName("device_id")]
    public string DeviceId { get; set; } = string.Empty;

    [JsonPropertyName("machine_type")]
    public string MachineType { get; set; } = string.Empty;

    [JsonPropertyName("machine_status")]
    public string MachineStatus { get; set; } = string.Empty;

    [JsonPropertyName("idle_reason")]
    public string? IdleReason { get; set; }

    [JsonPropertyName("line_id")]
    public string LineId { get; set; } = string.Empty;

    [JsonPropertyName("station_position")]
    public int StationPosition { get; set; }

    [JsonPropertyName("actual_cycle_time")]
    public double ActualCycleTime { get; set; }

    [JsonPropertyName("input_buffer_count")]
    public int InputBufferCount { get; set; }

    [JsonPropertyName("output_buffer_count")]
    public int OutputBufferCount { get; set; }

    [JsonPropertyName("buffer_capacity")]
    public int BufferCapacity { get; set; }

    [JsonPropertyName("total_parts_processed")]
    public long TotalPartsProcessed { get; set; }

    [JsonPropertyName("rejected_parts")]
    public long RejectedParts { get; set; }

    [JsonPropertyName("current_part_id")]
    public string? CurrentPartId { get; set; }
}

public sealed class PartTelemetryEvent : TelemetryEvent
{
    [JsonPropertyName("event_type")]
    public override string EventType => "part_event";

    [JsonPropertyName("part_id")]
    public string PartId { get; set; } = string.Empty;

    [JsonPropertyName("line_id")]
    public string LineId { get; set; } = string.Empty;

    [JsonPropertyName("station_position")]
    public int StationPosition { get; set; }

    [JsonPropertyName("machine_type")]
    public string MachineType { get; set; } = string.Empty;

    [JsonPropertyName("action")]
    public string Action { get; set; } = string.Empty;

    [JsonPropertyName("cycle_time")]
    public double CycleTime { get; set; }

    [JsonPropertyName("quality_pass")]
    public bool QualityPass { get; set; } = true;
}

public sealed class MaintenanceTelemetryEvent : TelemetryEvent
{
    [JsonPropertyName("event_type")]
    public override string EventType => "maintenance_event";

    [JsonPropertyName("work_order_id")]
    public string WorkOrderId { get; set; } = string.Empty;

    [JsonPropertyName("device_id")]
    public string DeviceId { get; set; } = string.Empty;

    [JsonPropertyName("machine_type")]
    public string MachineType { get; set; } = string.Empty;

    [JsonPropertyName("line_id")]
    public string LineId { get; set; } = string.Empty;

    [JsonPropertyName("station_position")]
    public int StationPosition { get; set; }

    [JsonPropertyName("issue_type")]
    public string IssueType { get; set; } = string.Empty;

    [JsonPropertyName("action")]
    public string Action { get; set; } = string.Empty;

    [JsonPropertyName("technician_id")]
    public string TechnicianId { get; set; } = string.Empty;
}
