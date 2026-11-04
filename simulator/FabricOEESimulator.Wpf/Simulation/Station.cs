using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
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

    // Demo scenarios: set from the UI thread, consumed by the processing loop.
    private readonly object _scenarioLock = new();
    private readonly Queue<FaultRequest> _queuedFaults = new();
    private TaskCompletionSource _faultQueued = NewSignal();
    private string? _activeScenario;
    private DateTime _rejectSpikeUntilUtc;
    private double _rejectSpikeProbability;
    private DateTime _slowCyclesUntilUtc;
    private double _slowCycleMultiplier = 1.0;

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

    /// <summary>How long a station stays in Fault before maintenance starts.</summary>
    public TimeSpan FaultPhase => TimeSpan.FromMilliseconds(_telemetryIntervalMs * 3);

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
        if (InputBuffer is null)
            return;

        while (!ct.IsCancellationRequested)
        {
            // A demo fault queued while the station was idle runs before the next part.
            if (TryDequeueFault(out var queued))
            {
                if (!await RunFaultAsync(queued, ct))
                    break;
                continue;
            }

            Status = MachineStatus.IdleStarved;
            Part? next = null;
            if (!await RunInterruptibleAsync(async t => next = await InputBuffer.ReadAsync(t), ct))
                continue;

            var part = next!;
            Status = MachineStatus.Running;
            CurrentPartId = part.Id;

            await EmitPartEventAsync(part, "entered", 0, true, ct);

            var cycleTime = (_config.IdealCycleTimeSeconds +
                             _random.NextDouble() * (_config.MaxCycleTimeSeconds - _config.IdealCycleTimeSeconds))
                            * CycleTimeMultiplier();
            LastCycleTime = cycleTime;

            // A demo fault can interrupt the cycle; after repair the part finishes its remaining time.
            var remaining = TimeSpan.FromSeconds(cycleTime);
            var stopwatch = Stopwatch.StartNew();
            while (!await RunInterruptibleAsync(t => Task.Delay(remaining, t), ct))
            {
                remaining = TimeSpan.FromTicks(Math.Max(0, (remaining - stopwatch.Elapsed).Ticks));
                if (TryDequeueFault(out var midCycle) && !await RunFaultAsync(midCycle, ct))
                    return;
                Status = MachineStatus.Running;
                stopwatch.Restart();
            }

            if (_random.NextDouble() < _config.FaultProbability && !await RunFaultAsync(FaultRequest.Random, ct))
                break;

            if (_random.NextDouble() < RejectProbability())
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
                while (!await RunInterruptibleAsync(t => OutputBuffer.WriteAsync(part, t).AsTask(), ct))
                {
                    if (TryDequeueFault(out var whileBlocked) && !await RunFaultAsync(whileBlocked, ct))
                        return;
                    Status = MachineStatus.IdleBlocked;
                }
            }

            CurrentPartId = null;
        }
    }

    /// <summary>Runs a fault through Fault → Maintenance → resolved. Returns false if the simulation stopped.</summary>
    private async Task<bool> RunFaultAsync(FaultRequest request, CancellationToken ct)
    {
        var faultType = request.Primary
            ? _config.FaultTypes[0]
            : _config.FaultTypes[_random.Next(_config.FaultTypes.Count)];
        lock (_scenarioLock)
            _activeScenario = request.ScenarioLabel;

        try
        {
            Status = MachineStatus.Fault;
            if (request.ScenarioLabel is null)
                _logger.LogWarning("{DeviceId} faulted: {FaultType}", _deviceId, faultType);
            else
                _logger.LogWarning("{DeviceId} faulted: {FaultType} (demo scenario: {Scenario})",
                    _deviceId, faultType, request.ScenarioLabel);

            await Task.Delay(FaultPhase, ct);

            Status = MachineStatus.Maintenance;
            var wo = _maintenanceManager.CreateWorkOrder(
                _deviceId, _config.MachineType, _lineId, _config.Position, faultType, request.Timing);

            try
            {
                await wo.WaitForResolutionAsync(ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return false;
            }

            _logger.LogInformation("{DeviceId} maintenance complete, resuming", _deviceId);
            Status = MachineStatus.Running;
            return true;
        }
        finally
        {
            lock (_scenarioLock)
                _activeScenario = null;
        }
    }

    /// <summary>
    /// Runs a wait that a queued demo fault can interrupt; returns false when interrupted.
    /// Buffer reads and writes are channel operations, so cancelling them never loses a part.
    /// </summary>
    private async Task<bool> RunInterruptibleAsync(Func<CancellationToken, Task> wait, CancellationToken ct)
    {
        var faultQueued = FaultQueuedSignal();
        if (faultQueued.IsCompleted)
            return false;

        using var interrupt = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var operation = wait(interrupt.Token);
        if (await Task.WhenAny(operation, faultQueued) == operation)
        {
            await operation;
            return true;
        }

        await interrupt.CancelAsync();
        try
        {
            await operation;
            return true;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return false;
        }
    }

    // ── Demo scenarios ───────────────────────────────────────────────────────

    /// <summary>Queues demo faults. Each one interrupts whatever the station is waiting on.</summary>
    public void InjectFaults(IEnumerable<FaultRequest> faults)
    {
        lock (_scenarioLock)
        {
            foreach (var fault in faults)
                _queuedFaults.Enqueue(fault);
            if (_queuedFaults.Count > 0)
                _faultQueued.TrySetResult();
        }
    }

    public void StartRejectSpike(TimeSpan duration, double probability)
    {
        lock (_scenarioLock)
        {
            _rejectSpikeProbability = probability;
            _rejectSpikeUntilUtc = DateTime.UtcNow + duration;
        }
    }

    public void StartSlowCycles(TimeSpan duration, double multiplier)
    {
        lock (_scenarioLock)
        {
            _slowCycleMultiplier = multiplier;
            _slowCyclesUntilUtc = DateTime.UtcNow + duration;
        }
    }

    /// <summary>Drops queued faults and ends timed scenarios. A fault already in progress runs to resolution.</summary>
    public void ClearScenarios()
    {
        lock (_scenarioLock)
        {
            _queuedFaults.Clear();
            if (_faultQueued.Task.IsCompleted)
                _faultQueued = NewSignal();
            _rejectSpikeUntilUtc = DateTime.MinValue;
            _slowCyclesUntilUtc = DateTime.MinValue;
        }
    }

    /// <summary>Summary of active demo scenarios (one per line), or empty.</summary>
    public string ScenarioStatus
    {
        get
        {
            lock (_scenarioLock)
            {
                var now = DateTime.UtcNow;
                var lines = new List<string>();
                if (_activeScenario is not null)
                    lines.Add($"{_activeScenario} in progress");
                if (_queuedFaults.Count > 0)
                    lines.Add($"{_queuedFaults.Count} fault(s) queued");
                if (now < _rejectSpikeUntilUtc)
                    lines.Add($"Reject spike · {Remaining(_rejectSpikeUntilUtc - now)} left");
                if (now < _slowCyclesUntilUtc)
                    lines.Add($"Slow cycles · {Remaining(_slowCyclesUntilUtc - now)} left");
                return string.Join(Environment.NewLine, lines);
            }
        }
    }

    private bool TryDequeueFault([NotNullWhen(true)] out FaultRequest? fault)
    {
        lock (_scenarioLock)
        {
            if (!_queuedFaults.TryDequeue(out fault))
                return false;
            if (_queuedFaults.Count == 0)
                _faultQueued = NewSignal();
            return true;
        }
    }

    private Task FaultQueuedSignal()
    {
        lock (_scenarioLock)
            return _faultQueued.Task;
    }

    private double RejectProbability()
    {
        lock (_scenarioLock)
            return DateTime.UtcNow < _rejectSpikeUntilUtc
                ? Math.Max(_config.RejectProbability, _rejectSpikeProbability)
                : _config.RejectProbability;
    }

    private double CycleTimeMultiplier()
    {
        lock (_scenarioLock)
            return DateTime.UtcNow < _slowCyclesUntilUtc ? _slowCycleMultiplier : 1.0;
    }

    private static TaskCompletionSource NewSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    private static string Remaining(TimeSpan span) => $"{(int)span.TotalMinutes}:{span.Seconds:00}";

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
