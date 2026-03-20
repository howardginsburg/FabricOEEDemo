using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace FabricOEESimulator.Wpf.Controls;

public class SparklineControl : Control
{
    public static readonly DependencyProperty ValuesProperty =
        DependencyProperty.Register(nameof(Values), typeof(ObservableCollection<double>),
            typeof(SparklineControl), new FrameworkPropertyMetadata(null, OnValuesChanged));

    public static readonly DependencyProperty LineBrushProperty =
        DependencyProperty.Register(nameof(LineBrush), typeof(Brush),
            typeof(SparklineControl), new FrameworkPropertyMetadata(Brushes.LimeGreen, FrameworkPropertyMetadataOptions.AffectsRender));

    public ObservableCollection<double>? Values
    {
        get => (ObservableCollection<double>?)GetValue(ValuesProperty);
        set => SetValue(ValuesProperty, value);
    }

    public Brush LineBrush
    {
        get => (Brush)GetValue(LineBrushProperty);
        set => SetValue(LineBrushProperty, value);
    }

    private static void OnValuesChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var ctrl = (SparklineControl)d;
        if (e.OldValue is ObservableCollection<double> oldCol)
            oldCol.CollectionChanged -= ctrl.OnCollectionChanged;
        if (e.NewValue is ObservableCollection<double> newCol)
            newCol.CollectionChanged += ctrl.OnCollectionChanged;
        ctrl.InvalidateVisual();
    }

    private void OnCollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
        => InvalidateVisual();

    private static readonly Brush BgBrush = new SolidColorBrush(Color.FromRgb(0x22, 0x22, 0x33));
    static SparklineControl() { ((SolidColorBrush)BgBrush).Freeze(); }

    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        var w = ActualWidth;
        var h = ActualHeight;
        if (w <= 0 || h <= 0) return;

        dc.DrawRoundedRectangle(BgBrush, null, new Rect(0, 0, w, h), 2, 2);

        var values = Values;
        if (values is null || values.Count < 2) return;

        double max = 1;
        foreach (var v in values)
            if (v > max) max = v;

        var pen = new Pen(LineBrush, 1.5) { LineJoin = PenLineJoin.Round };
        pen.Freeze();

        var geo = new StreamGeometry();
        using (var ctx = geo.Open())
        {
            double xStep = w / (values.Count - 1);
            double padding = 2;
            double drawH = h - padding * 2;

            ctx.BeginFigure(new Point(0, h - padding - (values[0] / max * drawH)), false, false);
            for (int i = 1; i < values.Count; i++)
            {
                double x = i * xStep;
                double y = h - padding - (values[i] / max * drawH);
                ctx.LineTo(new Point(x, y), true, true);
            }
        }
        geo.Freeze();
        dc.DrawGeometry(null, pen, geo);
    }
}
