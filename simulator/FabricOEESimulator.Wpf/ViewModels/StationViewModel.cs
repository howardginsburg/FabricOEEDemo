using FabricOEESimulator.Wpf.Models;
using FabricOEESimulator.Wpf.Simulation;

namespace FabricOEESimulator.Wpf.ViewModels;

public sealed class StationViewModel : ViewModelBase
{
    private readonly Station _station;

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

    public void Refresh()
    {
        Status = _station.Status;
        CurrentPartId = _station.CurrentPartId;
        LastCycleTime = _station.LastCycleTime;
        TotalPartsProcessed = _station.TotalPartsProcessed;
        RejectedParts = _station.RejectedParts;
        InputBufferCount = _station.InputBuffer?.Count ?? 0;
        OutputBufferCount = _station.OutputBuffer?.Count ?? 0;
        OnPropertyChanged(nameof(RejectRate));
    }
}
