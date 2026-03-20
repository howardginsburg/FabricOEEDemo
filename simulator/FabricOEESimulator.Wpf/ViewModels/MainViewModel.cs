using System.Collections.ObjectModel;
using System.Windows.Input;
using System.Windows.Threading;
using FabricOEESimulator.Wpf.Simulation;

namespace FabricOEESimulator.Wpf.ViewModels;

public sealed class MainViewModel : ViewModelBase
{
    private readonly DispatcherTimer _refreshTimer;
    private SimulationEngine? _engine;

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
    }

    public ObservableCollection<ProductionLineViewModel> Lines { get; } = [];

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
        }

        TotalPartsProduced = totalParts;
        TotalFaults = totalFaults;

        Maintenance?.Refresh();
        TelemetryLog?.Refresh();
    }
}
