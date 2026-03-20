using System.Text.Json;
using FabricOEESimulator.Wpf.Configuration;
using FabricOEESimulator.Wpf.Models;
using FabricOEESimulator.Wpf.Telemetry;
using Microsoft.Extensions.Logging;

namespace FabricOEESimulator.Wpf.Simulation;

public sealed class Station
{
    private readonly StationConfig _config;
    private readonly string _lineId;
    private readonly string _deviceId;
    private readonly MaintenanceManager _maintenanceManager;
    private readonly ITelemetrySink _sink;
    private readonly TelemetryLog _telemetryLog;
    private readonly ILogger _logger;
    private readonly Random _random = new();
    private readonly int _telemetryIntervalMs;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };

    public PartBuffer? InputBuffer { get; set; }
    public PartBuffer? OutputBuffer { get; set; }

    // Observable state
    public MachineStatus Status { get; private set; } = MachineStatus.IdleStarved;
    public string? CurrentPartId { get; private set; }
    public double LastCycleTime { get; private set; }
    public long TotalPartsProcessed { get; private set; }
    public long RejectedParts { get; private set; }

    // Config accessors
    public string DeviceId => _deviceId;
    public string MachineType => _config.MachineType;
    public string LineId => _lineId;
    public int Position => _config.Position;
    public int BufferCapacity => _config.BufferCapacity;

    public Station(
        StationConfig config,
        string lineId,
        MaintenanceManager maintenanceManager,
        ITelemetrySink sink,
        TelemetryLog telemetryLog,
        int telemetryIntervalSeconds,
        ILogger logger)
    {
        _config = config;
        _lineId = lineId;
        _deviceId = $"{lineId.ToLowerInvariant()}-station-{config.Position}";
        _maintenanceManager = maintenanceManager;
        _sink = sink;
        _telemetryLog = telemetryLog;
        _logger = logger;
        _telemetryIntervalMs = telemetryIntervalSeconds * 1000;
    }

    public async Task RunAsync(CancellationToken ct)
    {
        var telemetryTask = RunTelemetryLoopAsync(ct);

        try
        {
            await RunProcessingLoopAsync(ct);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }

        await telemetryTask;
    }

    private async Task RunProcessingLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            Part part;
            if (InputBuffer is not null)
            {
                Status = MachineStatus.IdleStarved;
                try
                {
                    part = await InputBuffer.ReadAsync(ct);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
            else
            {
                break;
            }

            Status = MachineStatus.Running;
            CurrentPartId = part.Id;

            await EmitPartEventAsync(part, "entered", 0, true, ct);

            var cycleTime = _config.IdealCycleTimeSeconds +
                            _random.NextDouble() * (_config.MaxCycleTimeSeconds - _config.IdealCycleTimeSeconds);
            LastCycleTime = cycleTime;

            await Task.Delay(TimeSpan.FromSeconds(cycleTime), ct);

            bool shouldFault = _random.NextDouble() < _config.FaultProbability;

            if (shouldFault)
            {
                var faultType = _config.FaultTypes[_random.Next(_config.FaultTypes.Count)];
                Status = MachineStatus.Fault;
                _logger.LogWarning("{DeviceId} faulted: {FaultType}", _deviceId, faultType);

                await Task.Delay(_telemetryIntervalMs * 3, ct);

                Status = MachineStatus.Maintenance;
                var wo = _maintenanceManager.CreateWorkOrder(_deviceId, _config.MachineType, _lineId, _config.Position, faultType);

                try
                {
                    await wo.WaitForResolutionAsync(ct);
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested)
                {
                    break;
                }

                _logger.LogInformation("{DeviceId} maintenance complete, resuming", _deviceId);
                Status = MachineStatus.Running;
            }

            if (_random.NextDouble() < _config.RejectProbability)
            {
                RejectedParts++;
                TotalPartsProcessed++;
                part.RecordStation(_config.Position, _config.MachineType, cycleTime, false);
                await EmitPartEventAsync(part, "rejected", cycleTime, false, ct);
                CurrentPartId = null;
                continue;
            }

            TotalPartsProcessed++;
            part.RecordStation(_config.Position, _config.MachineType, cycleTime, true);
            await EmitPartEventAsync(part, "completed", cycleTime, true, ct);

            if (OutputBuffer is not null)
            {
                Status = MachineStatus.IdleBlocked;
                try
                {
                    await OutputBuffer.WriteAsync(part, ct);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }

            CurrentPartId = null;
        }
    }

    private async Task RunTelemetryLoopAsync(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                await Task.Delay(_telemetryIntervalMs, ct);
                await EmitMachineTelemetryAsync(ct);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
    }

    private Task EmitMachineTelemetryAsync(CancellationToken ct)
    {
        var evt = new MachineTelemetryEvent
        {
            DeviceId = _deviceId,
            MachineType = _config.MachineType,
            MachineStatus = Status.ToTelemetryString(),
            IdleReason = Status.ToIdleReason(),
            LineId = _lineId,
            StationPosition = _config.Position,
            ActualCycleTime = LastCycleTime,
            InputBufferCount = InputBuffer?.Count ?? 0,
            OutputBufferCount = OutputBuffer?.Count ?? 0,
            BufferCapacity = _config.BufferCapacity,
            TotalPartsProcessed = TotalPartsProcessed,
            RejectedParts = RejectedParts,
            CurrentPartId = CurrentPartId,
            Timestamp = DateTime.UtcNow
        };
        var json = JsonSerializer.Serialize(evt, evt.GetType(), JsonOptions);
        _telemetryLog.Record(evt.EventType, _deviceId, _lineId, json);
        return _sink.SendAsync(evt, ct);
    }

    private Task EmitPartEventAsync(Part part, string action, double cycleTime, bool qualityPass, CancellationToken ct)
    {
        var evt = new PartTelemetryEvent
        {
            PartId = part.Id,
            LineId = _lineId,
            StationPosition = _config.Position,
            MachineType = _config.MachineType,
            Action = action,
            CycleTime = cycleTime,
            QualityPass = qualityPass,
            Timestamp = DateTime.UtcNow
        };
        var json = JsonSerializer.Serialize(evt, evt.GetType(), JsonOptions);
        _telemetryLog.Record(evt.EventType, _deviceId, _lineId, json);
        return _sink.SendAsync(evt, ct);
    }
}
