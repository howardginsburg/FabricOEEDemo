using FabricOEESimulator.Wpf.Configuration;
using FabricOEESimulator.Wpf.Models;
using FabricOEESimulator.Wpf.Telemetry;
using Microsoft.Extensions.Logging;

namespace FabricOEESimulator.Wpf.Simulation;

public sealed class ProductionLine
{
    private readonly LineConfig _config;
    private readonly MaintenanceManager _maintenanceManager;
    private readonly ITelemetrySink _sink;
    private readonly TelemetryLog _telemetryLog;
    private readonly ILogger<ProductionLine> _logger;
    private readonly int _telemetryIntervalSeconds;

    private readonly List<Station> _stations = [];
    private readonly List<PartBuffer> _buffers = [];

    private PartBuffer? _rawMaterialBuffer;
    private long _partCounter;

    public string LineId => _config.Id;
    public string LineName => _config.Name;
    public string Purpose => _config.Purpose;
    public IReadOnlyList<Station> Stations => _stations;
    public long PartsProduced { get; private set; }

    public ProductionLine(
        LineConfig config,
        MaintenanceManager maintenanceManager,
        ITelemetrySink sink,
        TelemetryLog telemetryLog,
        int telemetryIntervalSeconds,
        ILoggerFactory loggerFactory)
    {
        _config = config;
        _maintenanceManager = maintenanceManager;
        _sink = sink;
        _telemetryLog = telemetryLog;
        _logger = loggerFactory.CreateLogger<ProductionLine>();
        _telemetryIntervalSeconds = telemetryIntervalSeconds;

        BuildStationChain(loggerFactory);
    }

    private void BuildStationChain(ILoggerFactory loggerFactory)
    {
        var sortedStations = _config.Stations.OrderBy(s => s.Position).ToList();

        foreach (var stationConfig in sortedStations)
        {
            var station = new Station(
                stationConfig,
                _config.Id,
                _maintenanceManager,
                _sink,
                _telemetryLog,
                _telemetryIntervalSeconds,
                loggerFactory.CreateLogger<Station>());
            _stations.Add(station);
        }

        _rawMaterialBuffer = new PartBuffer(sortedStations[0].BufferCapacity);
        _stations[0].InputBuffer = _rawMaterialBuffer;

        for (int i = 0; i < _stations.Count - 1; i++)
        {
            var buffer = new PartBuffer(sortedStations[i + 1].BufferCapacity);
            _buffers.Add(buffer);
            _stations[i].OutputBuffer = buffer;
            _stations[i + 1].InputBuffer = buffer;
        }

        var finishedBuffer = new PartBuffer(sortedStations[^1].BufferCapacity);
        _buffers.Add(finishedBuffer);
        _stations[^1].OutputBuffer = finishedBuffer;

        _logger.LogInformation("Line {LineId}: {Count} stations wired, {BufferCount} buffers",
            _config.Id, _stations.Count, _buffers.Count + 1);
    }

    public async Task RunAsync(CancellationToken ct)
    {
        _logger.LogInformation("Line {LineId} ({Name}) starting...", _config.Id, _config.Name);

        var stationTasks = _stations.Select(s => s.RunAsync(ct)).ToList();
        var feederTask = RunRawMaterialFeederAsync(ct);
        var drainerTask = RunFinishedGoodsDrainerAsync(ct);

        await Task.WhenAll(stationTasks.Append(feederTask).Append(drainerTask));

        _logger.LogInformation("Line {LineId} stopped. Total parts produced: {Count}", _config.Id, PartsProduced);
    }

    private async Task RunRawMaterialFeederAsync(CancellationToken ct)
    {
        var prefix = _config.Id.Replace("Line-", "L", StringComparison.OrdinalIgnoreCase);

        try
        {
            while (!ct.IsCancellationRequested)
            {
                var partNum = Interlocked.Increment(ref _partCounter);
                var part = new Part($"{prefix}-P{partNum:D5}", _config.Id);
                await _rawMaterialBuffer!.WriteAsync(part, ct);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
    }

    private async Task RunFinishedGoodsDrainerAsync(CancellationToken ct)
    {
        var finishedBuffer = _stations[^1].OutputBuffer!;
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var part = await finishedBuffer.ReadAsync(ct);
                PartsProduced++;
                _logger.LogInformation("Line {LineId}: Part {PartId} completed line ({Total} total)",
                    _config.Id, part.Id, PartsProduced);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
    }
}
