using System.Collections.ObjectModel;
using FabricOEESimulator.Wpf.Models;
using FabricOEESimulator.Wpf.Simulation;

namespace FabricOEESimulator.Wpf.ViewModels;

public sealed class StationViewModel : ViewModelBase
{
    private readonly Station _station;
    private long _prevPartsProcessed;
    private int _throughputTickCounter;

    public StationViewModel(Station station)
    {
        _station = station;
    }

    public string DeviceId => _station.DeviceId;
    public string MachineType => _station.MachineType;
    public string LineId => _station.LineId;
    public int Position => _station.Position;
    public int BufferCapacity => _station.BufferCapacity;

    private MachineStatus _status;
    public MachineStatus Status
    {
        get => _status;
        private set => SetProperty(ref _status, value);
    }

    private string? _currentPartId;
    public string? CurrentPartId
    {
        get => _currentPartId;
        private set => SetProperty(ref _currentPartId, value);
    }

    private double _lastCycleTime;
    public double LastCycleTime
    {
        get => _lastCycleTime;
        private set => SetProperty(ref _lastCycleTime, value);
    }

    private long _totalPartsProcessed;
    public long TotalPartsProcessed
    {
        get => _totalPartsProcessed;
        private set => SetProperty(ref _totalPartsProcessed, value);
    }

    private long _rejectedParts;
    public long RejectedParts
    {
        get => _rejectedParts;
        private set => SetProperty(ref _rejectedParts, value);
    }

    private int _inputBufferCount;
    public int InputBufferCount
    {
        get => _inputBufferCount;
        private set => SetProperty(ref _inputBufferCount, value);
    }

    private int _outputBufferCount;
    public int OutputBufferCount
    {
        get => _outputBufferCount;
        private set => SetProperty(ref _outputBufferCount, value);
    }

    private bool _isSelected;
    public bool IsSelected
    {
        get => _isSelected;
        set => SetProperty(ref _isSelected, value);
    }

    public double RejectRate => TotalPartsProcessed > 0
        ? (double)RejectedParts / TotalPartsProcessed * 100.0
        : 0;

    // --- Status history for timeline bar (last 60 samples @ 500ms = 30s) ---
    public ObservableCollection<StatusHistoryEntry> StatusHistory { get; } = [];
    private const int MaxStatusHistory = 60;

    // --- Throughput history for sparkline (sampled every 5 ticks = 2.5s, keep 30 = 75s) ---
    public ObservableCollection<double> ThroughputHistory { get; } = [];
    private const int MaxThroughputHistory = 30;
    private const int ThroughputSampleInterval = 5;

    private bool _hasPartInProcess;
    public bool HasPartInProcess
    {
        get => _hasPartInProcess;
        private set => SetProperty(ref _hasPartInProcess, value);
    }

    private bool _isPulsing;
    public bool IsPulsing
    {
        get => _isPulsing;
        private set => SetProperty(ref _isPulsing, value);
    }

    public void Refresh()
    {
        var prevStatus = Status;
        Status = _station.Status;
        CurrentPartId = _station.CurrentPartId;
        LastCycleTime = _station.LastCycleTime;
        TotalPartsProcessed = _station.TotalPartsProcessed;
        RejectedParts = _station.RejectedParts;
        InputBufferCount = _station.InputBuffer?.Count ?? 0;
        OutputBufferCount = _station.OutputBuffer?.Count ?? 0;
        OnPropertyChanged(nameof(RejectRate));

        HasPartInProcess = CurrentPartId is not null && Status == MachineStatus.Running;
        IsPulsing = Status is MachineStatus.Fault or MachineStatus.Maintenance;

        // Record status history
        StatusHistory.Add(new StatusHistoryEntry(DateTime.UtcNow, Status));
        while (StatusHistory.Count > MaxStatusHistory)
            StatusHistory.RemoveAt(0);

        // Track throughput every N ticks
        _throughputTickCounter++;
        if (_throughputTickCounter >= ThroughputSampleInterval)
        {
            _throughputTickCounter = 0;
            var delta = TotalPartsProcessed - _prevPartsProcessed;
            _prevPartsProcessed = TotalPartsProcessed;
            ThroughputHistory.Add(delta);
            while (ThroughputHistory.Count > MaxThroughputHistory)
                ThroughputHistory.RemoveAt(0);
        }
    }

    /// <summary>Inject a fault into this station for demo purposes.</summary>
    public void ForceInjectFault()
    {
        _station.InjectFault();
    }
}

public record StatusHistoryEntry(DateTime Timestamp, MachineStatus Status);
