using FabricOEESimulator.Configuration;
using FabricOEESimulator.Models;
using FabricOEESimulator.Telemetry;
using Microsoft.Extensions.Logging;

namespace FabricOEESimulator.Simulation;

public sealed class Station
{
    private readonly StationConfig _config;
    private readonly string _lineId;
    private readonly string _deviceId;
    private readonly MaintenanceManager _maintenanceManager;
    private readonly ITelemetrySink _sink;
    private readonly ILogger _logger;
    private readonly Random _random = new();
    private readonly int _telemetryIntervalMs;

    // Buffers — set by ProductionLine when wiring the chain
    public PartBuffer? InputBuffer { get; set; }
    public PartBuffer? OutputBuffer { get; set; }

    // Observable state
    public MachineStatus Status { get; private set; } = MachineStatus.IdleStarved;
    public string? CurrentPartId { get; private set; }
    public double LastCycleTime { get; private set; }
    public long TotalPartsProcessed { get; private set; }
    public long RejectedParts { get; private set; }

    // Config accessors for display
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
        int telemetryIntervalSeconds,
        ILogger logger)
    {
        _config = config;
        _lineId = lineId;
        _deviceId = $"{lineId.ToLowerInvariant()}-station-{config.Position}";
        _maintenanceManager = maintenanceManager;
        _sink = sink;
        _logger = logger;
        _telemetryIntervalMs = telemetryIntervalSeconds * 1000;
    }

    public async Task RunAsync(CancellationToken ct)
    {
        // Start periodic telemetry reporting on a separate task
        var telemetryTask = RunTelemetryLoopAsync(ct);

        try
        {
            await RunProcessingLoopAsync(ct);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            // Graceful shutdown
        }

        await telemetryTask;
    }

    private async Task RunProcessingLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            // 1. Wait for a part from input buffer (station 1 gets parts via raw material feed)
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
                // First station — infinite raw material feed, just create a part
                // The ProductionLine will provide parts via a PartBuffer it manages
                break; // Should never reach here — ProductionLine always sets InputBuffer
            }

            // 2. Start processing
            Status = MachineStatus.Running;
            CurrentPartId = part.Id;

            await EmitPartEventAsync(part, "entered", 0, true, ct);

            // 3. Simulate cycle time (random between ideal and max)
            var cycleTime = _config.IdealCycleTimeSeconds +
                            _random.NextDouble() * (_config.MaxCycleTimeSeconds - _config.IdealCycleTimeSeconds);
            LastCycleTime = cycleTime;

            await Task.Delay(TimeSpan.FromSeconds(cycleTime), ct);

            // 4. Fault check — fully randomized
            if (_random.NextDouble() < _config.FaultProbability)
            {
                var faultType = _config.FaultTypes[_random.Next(_config.FaultTypes.Count)];
                Status = MachineStatus.Fault;
                _logger.LogWarning("{DeviceId} faulted: {FaultType}", _deviceId, faultType);

                // Hold Fault state for several telemetry cycles so it appears in MachineEvents
                await Task.Delay(_telemetryIntervalMs * 3, ct);

                // Create work order and wait for resolution
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

            // 5. Quality check — randomized
            if (_random.NextDouble() < _config.RejectProbability)
            {
                RejectedParts++;
                TotalPartsProcessed++;
                part.RecordStation(_config.Position, _config.MachineType, cycleTime, false);
                await EmitPartEventAsync(part, "rejected", cycleTime, false, ct);
                CurrentPartId = null;
                continue; // Part is scrapped — does not go to output buffer
            }

            // 6. Part passed — push to output buffer
            TotalPartsProcessed++;
            part.RecordStation(_config.Position, _config.MachineType, cycleTime, true);
            await EmitPartEventAsync(part, "completed", cycleTime, true, ct);

            if (OutputBuffer is not null)
            {
                Status = MachineStatus.IdleBlocked; // Will show Blocked if buffer is full
                try
                {
                    await OutputBuffer.WriteAsync(part, ct);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }
            // else: last station — part exits the line (tracked by ProductionLine)

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
            // Graceful shutdown
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
        return _sink.SendAsync(evt, ct);
    }
}
