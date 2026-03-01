using FabricOEESimulator.Configuration;
using FabricOEESimulator.Display;
using FabricOEESimulator.Telemetry;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace FabricOEESimulator.Simulation;

public sealed class SimulationEngine : IHostedService
{
    private readonly SimulatorConfig _config;
    private readonly ITelemetrySink _sink;
    private readonly TelemetryLog _telemetryLog;
    private readonly ILoggerFactory _loggerFactory;
    private readonly ILogger<SimulationEngine> _logger;
    private readonly ConsoleDisplay _display;

    private readonly List<ProductionLine> _lines = [];
    private MaintenanceManager? _maintenanceManager;
    private CancellationTokenSource? _cts;
    private Task? _runTask;

    public SimulationEngine(
        IOptions<SimulatorConfig> config,
        ITelemetrySink sink,
        TelemetryLog telemetryLog,
        ILoggerFactory loggerFactory,
        ConsoleDisplay display)
    {
        _config = config.Value;
        _sink = sink;
        _telemetryLog = telemetryLog;
        _loggerFactory = loggerFactory;
        _logger = loggerFactory.CreateLogger<SimulationEngine>();
        _display = display;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        _logger.LogInformation("Initializing OEE Simulator with {LineCount} production lines...", _config.Lines.Count);

        // Initialize telemetry sink
        await _sink.InitializeAsync(cancellationToken);

        // Create maintenance manager (shared across all lines)
        _maintenanceManager = new MaintenanceManager(
            _config.Maintenance, _sink, _loggerFactory.CreateLogger<MaintenanceManager>());

        // Create production lines
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
        // Start all lines in parallel
        var lineTasks = _lines.Select(l => l.RunAsync(ct)).ToList();

        // Start console display
        var displayTask = _display.RunAsync(_lines, _maintenanceManager!, _telemetryLog, ct);

        await Task.WhenAll(lineTasks.Append(displayTask));
    }
}
