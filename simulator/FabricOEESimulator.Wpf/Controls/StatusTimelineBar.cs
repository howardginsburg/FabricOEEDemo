using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using FabricOEESimulator.Wpf.Models;
using FabricOEESimulator.Wpf.ViewModels;

namespace FabricOEESimulator.Wpf.Controls;

public class StatusTimelineBar : Control
{
    private static readonly Dictionary<MachineStatus, Brush> StatusBrushes = new()
    {
        [MachineStatus.Running] = new SolidColorBrush(Color.FromRgb(0x2E, 0xCC, 0x71)),
        [MachineStatus.IdleStarved] = new SolidColorBrush(Color.FromRgb(0xF3, 0x9C, 0x12)),
        [MachineStatus.IdleBlocked] = new SolidColorBrush(Color.FromRgb(0xE6, 0x7E, 0x22)),
        [MachineStatus.Fault] = new SolidColorBrush(Color.FromRgb(0xE7, 0x4C, 0x3C)),
        [MachineStatus.Maintenance] = new SolidColorBrush(Color.FromRgb(0x34, 0x98, 0xDB)),
    };

    private static readonly Brush DefaultBrush = new SolidColorBrush(Color.FromRgb(0x7F, 0x8C, 0x8D));
    private static readonly Brush BackgroundFill = new SolidColorBrush(Color.FromRgb(0x22, 0x22, 0x33));

    static StatusTimelineBar()
    {
        foreach (var brush in StatusBrushes.Values)
            ((SolidColorBrush)brush).Freeze();
        ((SolidColorBrush)DefaultBrush).Freeze();
        ((SolidColorBrush)BackgroundFill).Freeze();
    }

    public StatusTimelineBar()
    {
        DataContextChanged += OnDataContextChanged;
    }

    private void OnDataContextChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (e.OldValue is StationViewModel oldVm)
            oldVm.StatusHistory.CollectionChanged -= OnHistoryChanged;
        if (e.NewValue is StationViewModel newVm)
            newVm.StatusHistory.CollectionChanged += OnHistoryChanged;
        InvalidateVisual();
    }

    private void OnHistoryChanged(object? sender, NotifyCollectionChangedEventArgs e) => InvalidateVisual();

    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        var w = ActualWidth;
        var h = ActualHeight;
        if (w <= 0 || h <= 0) return;

        // Background
        dc.DrawRoundedRectangle(BackgroundFill, null, new Rect(0, 0, w, h), 2, 2);

        if (DataContext is not StationViewModel vm || vm.StatusHistory.Count == 0) return;

        var entries = vm.StatusHistory;
        int count = entries.Count;
        double segWidth = w / 60.0; // 60 max slots

        for (int i = 0; i < count; i++)
        {
            var brush = StatusBrushes.GetValueOrDefault(entries[i].Status, DefaultBrush);
            double x = (60 - count + i) * segWidth;
            dc.DrawRectangle(brush, null, new Rect(x, 0, segWidth + 0.5, h));
        }
    }
}
