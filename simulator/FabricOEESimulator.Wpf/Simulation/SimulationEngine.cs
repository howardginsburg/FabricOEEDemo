using FabricOEESimulator.Wpf.Configuration;
using FabricOEESimulator.Wpf.Telemetry;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace FabricOEESimulator.Wpf.Simulation;

public sealed class SimulationEngine : IHostedService
{
    private readonly SimulatorConfig _config;
    private readonly ITelemetrySink _sink;
    private readonly TelemetryLog _telemetryLog;
    private readonly ILoggerFactory _loggerFactory;
    private readonly ILogger<SimulationEngine> _logger;

    private readonly List<ProductionLine> _lines = [];
    private MaintenanceManager? _maintenanceManager;
    private CancellationTokenSource? _cts;
    private Task? _runTask;

    /// <summary>Exposes production lines for UI binding.</summary>
    public IReadOnlyList<ProductionLine> Lines => _lines;

    /// <summary>Exposes maintenance manager for UI binding.</summary>
    public MaintenanceManager? MaintenanceManager => _maintenanceManager;

    /// <summary>Exposes telemetry log for UI binding.</summary>
    public TelemetryLog TelemetryLog => _telemetryLog;

    public SimulationEngine(
        IOptions<SimulatorConfig> config,
        ITelemetrySink sink,
        TelemetryLog telemetryLog,
        ILoggerFactory loggerFactory)
    {
        _config = config.Value;
        _sink = sink;
        _telemetryLog = telemetryLog;
        _loggerFactory = loggerFactory;
        _logger = loggerFactory.CreateLogger<SimulationEngine>();
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        _logger.LogInformation("Initializing OEE Simulator with {LineCount} production lines...", _config.Lines.Count);

        await _sink.InitializeAsync(cancellationToken);

        _maintenanceManager = new MaintenanceManager(
            _config.Maintenance, _sink, _loggerFactory.CreateLogger<MaintenanceManager>());

        foreach (var lineConfig in _config.Lines)
        {
            var line = new ProductionLine(
                lineConfig,
                _maintenanceManager,
                _sink,
                _telemetryLog,
                _config.TelemetryIntervalSeconds,
                _loggerFactory);
            _lines.Add(line);
        }

        _logger.LogInformation("Starting {LineCount} production lines ({StationCount} total stations)...",
            _lines.Count, _lines.Sum(l => l.Stations.Count));

        _cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _runTask = RunAllAsync(_cts.Token);
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        _logger.LogInformation("Shutting down simulator...");

        if (_cts is not null)
        {
            await _cts.CancelAsync();
            if (_runTask is not null)
            {
                try { await _runTask; } catch (OperationCanceledException) { }
            }
            _cts.Dispose();
        }

        await _sink.DisposeAsync();
        _logger.LogInformation("Simulator stopped.");
    }

    private async Task RunAllAsync(CancellationToken ct)
    {
        var lineTasks = _lines.Select(l => l.RunAsync(ct)).ToList();
        await Task.WhenAll(lineTasks);
    }
}
