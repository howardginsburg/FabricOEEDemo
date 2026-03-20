using System.Collections.ObjectModel;
using System.Windows.Input;
using System.Windows.Threading;
using FabricOEESimulator.Wpf.Models;
using FabricOEESimulator.Wpf.Simulation;

namespace FabricOEESimulator.Wpf.ViewModels;

public sealed class ToastNotification : ViewModelBase
{
    public string Message { get; }
    public string Severity { get; } // "Fault", "Maintenance", "Info"
    public DateTime CreatedAt { get; }
    public string DeviceId { get; }

    public ToastNotification(string message, string severity, string deviceId)
    {
        Message = message;
        Severity = severity;
        DeviceId = deviceId;
        CreatedAt = DateTime.UtcNow;
    }
}

public sealed class MainViewModel : ViewModelBase
{
    private readonly DispatcherTimer _refreshTimer;
    private SimulationEngine? _engine;
    private readonly Dictionary<string, MachineStatus> _prevStationStatuses = [];

    public MainViewModel()
    {
        _refreshTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(500)
        };
        _refreshTimer.Tick += OnRefreshTick;

        SelectLineCommand = new RelayCommand(o =>
        {
            if (o is ProductionLineViewModel lineVm)
                SelectedLine = lineVm;
        });

        ToggleOverviewCommand = new RelayCommand(_ => IsOverviewMode = !IsOverviewMode);

        DismissToastCommand = new RelayCommand(o =>
        {
            if (o is ToastNotification toast)
                Toasts.Remove(toast);
        });
    }

    public ObservableCollection<ProductionLineViewModel> Lines { get; } = [];
    public ObservableCollection<ToastNotification> Toasts { get; } = [];

    private ProductionLineViewModel? _selectedLine;
    public ProductionLineViewModel? SelectedLine
    {
        get => _selectedLine;
        set
        {
            if (_selectedLine is not null) _selectedLine.IsSelected = false;
            if (SetProperty(ref _selectedLine, value) && value is not null)
                value.IsSelected = true;
        }
    }

    private MaintenanceViewModel? _maintenance;
    public MaintenanceViewModel? Maintenance
    {
        get => _maintenance;
        private set => SetProperty(ref _maintenance, value);
    }

    private TelemetryLogViewModel? _telemetryLog;
    public TelemetryLogViewModel? TelemetryLog
    {
        get => _telemetryLog;
        private set => SetProperty(ref _telemetryLog, value);
    }

    private StationViewModel? _selectedStation;
    public StationViewModel? SelectedStation
    {
        get => _selectedStation;
        set
        {
            if (_selectedStation is not null) _selectedStation.IsSelected = false;
            if (SetProperty(ref _selectedStation, value) && value is not null)
                value.IsSelected = true;
        }
    }

    private bool _isOverviewMode;
    public bool IsOverviewMode
    {
        get => _isOverviewMode;
        set => SetProperty(ref _isOverviewMode, value);
    }

    private long _totalPartsProduced;
    public long TotalPartsProduced
    {
        get => _totalPartsProduced;
        private set => SetProperty(ref _totalPartsProduced, value);
    }

    private int _totalFaults;
    public int TotalFaults
    {
        get => _totalFaults;
        private set => SetProperty(ref _totalFaults, value);
    }

    private int _totalStations;
    public int TotalStations
    {
        get => _totalStations;
        private set => SetProperty(ref _totalStations, value);
    }

    public ICommand SelectLineCommand { get; }
    public ICommand ToggleOverviewCommand { get; }
    public ICommand DismissToastCommand { get; }

    public void Initialize(SimulationEngine engine)
    {
        _engine = engine;

        foreach (var line in engine.Lines)
            Lines.Add(new ProductionLineViewModel(line));

        if (engine.MaintenanceManager is not null)
            Maintenance = new MaintenanceViewModel(engine.MaintenanceManager);

        TelemetryLog = new TelemetryLogViewModel(engine.TelemetryLog);

        TotalStations = engine.Lines.Sum(l => l.Stations.Count);

        if (Lines.Count > 0)
            SelectedLine = Lines[0];

        _refreshTimer.Start();
    }

    public void Shutdown()
    {
        _refreshTimer.Stop();
    }

    private void OnRefreshTick(object? sender, EventArgs e)
    {
        long totalParts = 0;
        int totalFaults = 0;

        foreach (var lineVm in Lines)
        {
            lineVm.Refresh();
            totalParts += lineVm.PartsProduced;
            totalFaults += lineVm.FaultCount;

            // Detect status transitions for toast notifications
            foreach (var stationVm in lineVm.Stations)
            {
                var key = stationVm.DeviceId;
                var newStatus = stationVm.Status;

                if (_prevStationStatuses.TryGetValue(key, out var prevStatus) && prevStatus != newStatus)
                {
                    if (newStatus == MachineStatus.Fault)
                        AddToast($"{stationVm.MachineType} on {lineVm.LineName} has FAULTED", "Fault", key);
                    else if (newStatus == MachineStatus.Maintenance)
                        AddToast($"{stationVm.MachineType} on {lineVm.LineName} entered MAINTENANCE", "Maintenance", key);
                    else if (prevStatus is MachineStatus.Fault or MachineStatus.Maintenance && newStatus == MachineStatus.Running)
                        AddToast($"{stationVm.MachineType} on {lineVm.LineName} is back ONLINE", "Info", key);
                }

                _prevStationStatuses[key] = newStatus;
            }
        }

        TotalPartsProduced = totalParts;
        TotalFaults = totalFaults;

        Maintenance?.Refresh();
        TelemetryLog?.Refresh();

        // Auto-dismiss toasts older than 8 seconds
        var cutoff = DateTime.UtcNow.AddSeconds(-8);
        for (int i = Toasts.Count - 1; i >= 0; i--)
        {
            if (Toasts[i].CreatedAt < cutoff)
                Toasts.RemoveAt(i);
        }
    }

    private void AddToast(string message, string severity, string deviceId)
    {
        Toasts.Add(new ToastNotification(message, severity, deviceId));
        // Keep max 5 toasts visible
        while (Toasts.Count > 5)
            Toasts.RemoveAt(0);
    }
}
