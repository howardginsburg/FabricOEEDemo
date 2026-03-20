using System.Collections.ObjectModel;
using FabricOEESimulator.Wpf.Simulation;

namespace FabricOEESimulator.Wpf.ViewModels;

public sealed class ProductionLineViewModel : ViewModelBase
{
    private readonly ProductionLine _line;
    private long _prevPartsProduced;
    private int _throughputTickCounter;

    public ProductionLineViewModel(ProductionLine line)
    {
        _line = line;
        foreach (var station in line.Stations)
            Stations.Add(new StationViewModel(station));
    }

    public string LineId => _line.LineId;
    public string LineName => _line.LineName;
    public string Purpose => _line.Purpose;
    public int StationCount => _line.Stations.Count;

    public ObservableCollection<StationViewModel> Stations { get; } = [];

    private long _partsProduced;
    public long PartsProduced
    {
        get => _partsProduced;
        private set => SetProperty(ref _partsProduced, value);
    }

    private int _faultCount;
    public int FaultCount
    {
        get => _faultCount;
        private set => SetProperty(ref _faultCount, value);
    }

    private bool _isSelected;
    public bool IsSelected
    {
        get => _isSelected;
        set => SetProperty(ref _isSelected, value);
    }

    // Throughput history for sparkline (sampled every 5 ticks = 2.5s, keep 30 = 75s)
    public ObservableCollection<double> ThroughputHistory { get; } = [];
    private const int MaxThroughputHistory = 30;
    private const int ThroughputSampleInterval = 5;

    public void Refresh()
    {
        PartsProduced = _line.PartsProduced;
        int faults = 0;
        foreach (var stationVm in Stations)
        {
            stationVm.Refresh();
            if (stationVm.Status == Models.MachineStatus.Fault || stationVm.Status == Models.MachineStatus.Maintenance)
                faults++;
        }
        FaultCount = faults;

        // Track throughput every N ticks
        _throughputTickCounter++;
        if (_throughputTickCounter >= ThroughputSampleInterval)
        {
            _throughputTickCounter = 0;
            var delta = PartsProduced - _prevPartsProduced;
            _prevPartsProduced = PartsProduced;
            ThroughputHistory.Add(delta);
            while (ThroughputHistory.Count > MaxThroughputHistory)
                ThroughputHistory.RemoveAt(0);
        }
    }
}
