using FabricOEESimulator.Wpf.Configuration;
using FabricOEESimulator.Wpf.Models;
using FabricOEESimulator.Wpf.Telemetry;
using Microsoft.Extensions.Logging;

namespace FabricOEESimulator.Wpf.Simulation;

public sealed class MaintenanceManager
{
    private readonly MaintenanceConfig _config;
    private readonly ITelemetrySink _sink;
    private readonly ILogger<MaintenanceManager> _logger;
    private readonly Random _random = new();
    private readonly List<MaintenanceWorkOrder> _activeOrders = [];
    private readonly object _lock = new();

    public MaintenanceManager(MaintenanceConfig config, ITelemetrySink sink, ILogger<MaintenanceManager> logger)
    {
        _config = config;
        _sink = sink;
        _logger = logger;
    }

    public IReadOnlyList<MaintenanceWorkOrder> ActiveOrders
    {
        get
        {
            lock (_lock)
                return _activeOrders.ToList();
        }
    }

    public MaintenanceWorkOrder CreateWorkOrder(string deviceId, string machineType, string lineId, int stationPosition,
        string issueType, MaintenanceTiming? timing = null)
    {
        var wo = new MaintenanceWorkOrder(deviceId, machineType, lineId, stationPosition, issueType);
        wo.TechnicianId = _config.Technicians[_random.Next(_config.Technicians.Count)];

        lock (_lock)
            _activeOrders.Add(wo);

        _logger.LogInformation("Work order {WoId} created for {DeviceId}: {IssueType}", wo.Id, deviceId, issueType);

        _ = RunLifecycleAsync(wo, timing);
        return wo;
    }

    private async Task RunLifecycleAsync(MaintenanceWorkOrder wo, MaintenanceTiming? timing)
    {
        try
        {
            await EmitEventAsync(wo, "Created");

            var ackDelay = timing?.Acknowledge ?? RandomDelay(_config.AcknowledgeDelayMinSeconds, _config.AcknowledgeDelayMaxSeconds);
            await Task.Delay(ackDelay);
            wo.Status = WorkOrderStatus.Acknowledged;
            wo.AcknowledgedAtUtc = DateTime.UtcNow;
            await EmitEventAsync(wo, "Acknowledged");
            _logger.LogInformation("Work order {WoId} acknowledged after {Delay}s", wo.Id, ackDelay.TotalSeconds);

            var ipDelay = timing?.InProgress ?? RandomDelay(_config.InProgressDelayMinSeconds, _config.InProgressDelayMaxSeconds);
            await Task.Delay(ipDelay);
            wo.Status = WorkOrderStatus.InProgress;
            wo.InProgressAtUtc = DateTime.UtcNow;
            await EmitEventAsync(wo, "InProgress");
            _logger.LogInformation("Work order {WoId} in progress after {Delay}s", wo.Id, ipDelay.TotalSeconds);

            var resolveDelay = timing?.Resolve ?? RandomDelay(_config.ResolveDelayMinSeconds, _config.ResolveDelayMaxSeconds);
            await Task.Delay(resolveDelay);
            wo.MarkResolved();
            await EmitEventAsync(wo, "Resolved");
            _logger.LogInformation("Work order {WoId} resolved after {Delay}s", wo.Id, resolveDelay.TotalSeconds);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error in maintenance lifecycle for {WoId}", wo.Id);
            wo.MarkResolved();
        }
        finally
        {
            lock (_lock)
                _activeOrders.Remove(wo);
        }
    }

    private TimeSpan RandomDelay(int minSeconds, int maxSeconds) =>
        TimeSpan.FromSeconds(_random.Next(minSeconds, maxSeconds + 1));

    private Task EmitEventAsync(MaintenanceWorkOrder wo, string action)
    {
        var evt = new MaintenanceTelemetryEvent
        {
            WorkOrderId = wo.Id,
            DeviceId = wo.DeviceId,
            MachineType = wo.MachineType,
            LineId = wo.LineId,
            StationPosition = wo.StationPosition,
            IssueType = wo.IssueType,
            Action = action,
            TechnicianId = wo.TechnicianId,
            Timestamp = DateTime.UtcNow
        };
        return _sink.SendAsync(evt, CancellationToken.None);
    }
}
