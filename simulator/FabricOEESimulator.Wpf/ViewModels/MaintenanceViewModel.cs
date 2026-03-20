using System.Collections.ObjectModel;
using FabricOEESimulator.Wpf.Models;
using FabricOEESimulator.Wpf.Simulation;

namespace FabricOEESimulator.Wpf.ViewModels;

public sealed class WorkOrderViewModel : ViewModelBase
{
    public string Id { get; }
    public string DeviceId { get; }
    public string MachineType { get; }
    public string LineId { get; }
    public int StationPosition { get; }
    public string IssueType { get; }
    public string TechnicianId { get; }
    public DateTime CreatedAtUtc { get; }

    private WorkOrderStatus _status;
    public WorkOrderStatus Status
    {
        get => _status;
        set => SetProperty(ref _status, value);
    }

    public WorkOrderViewModel(MaintenanceWorkOrder wo)
    {
        Id = wo.Id;
        DeviceId = wo.DeviceId;
        MachineType = wo.MachineType;
        LineId = wo.LineId;
        StationPosition = wo.StationPosition;
        IssueType = wo.IssueType;
        TechnicianId = wo.TechnicianId;
        CreatedAtUtc = wo.CreatedAtUtc;
        Status = wo.Status;
    }
}

public sealed class MaintenanceViewModel : ViewModelBase
{
    private readonly MaintenanceManager _manager;

    public MaintenanceViewModel(MaintenanceManager manager)
    {
        _manager = manager;
    }

    public ObservableCollection<WorkOrderViewModel> ActiveOrders { get; } = [];

    private int _activeCount;
    public int ActiveCount
    {
        get => _activeCount;
        private set => SetProperty(ref _activeCount, value);
    }

    public void Refresh()
    {
        var orders = _manager.ActiveOrders;
        var currentIds = new HashSet<string>(orders.Select(o => o.Id));

        // Remove resolved orders
        for (int i = ActiveOrders.Count - 1; i >= 0; i--)
        {
            if (!currentIds.Contains(ActiveOrders[i].Id))
                ActiveOrders.RemoveAt(i);
        }

        // Update existing / add new
        var existingIds = new HashSet<string>(ActiveOrders.Select(o => o.Id));
        foreach (var wo in orders)
        {
            if (existingIds.Contains(wo.Id))
            {
                var existing = ActiveOrders.First(o => o.Id == wo.Id);
                existing.Status = wo.Status;
            }
            else
            {
                ActiveOrders.Add(new WorkOrderViewModel(wo));
            }
        }

        ActiveCount = ActiveOrders.Count;
    }
}
