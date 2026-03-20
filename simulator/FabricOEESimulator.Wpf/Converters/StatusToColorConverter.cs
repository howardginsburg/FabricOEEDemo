using System.Globalization;
using System.Windows.Data;
using System.Windows.Media;
using FabricOEESimulator.Wpf.Models;

namespace FabricOEESimulator.Wpf.Converters;

public sealed class StatusToColorConverter : IValueConverter
{
    private static readonly SolidColorBrush Running = new(Color.FromRgb(0x2E, 0xCC, 0x71));    // green
    private static readonly SolidColorBrush IdleStarved = new(Color.FromRgb(0xF3, 0x9C, 0x12)); // amber
    private static readonly SolidColorBrush IdleBlocked = new(Color.FromRgb(0xE6, 0x7E, 0x22)); // orange
    private static readonly SolidColorBrush Fault = new(Color.FromRgb(0xE7, 0x4C, 0x3C));       // red
    private static readonly SolidColorBrush Maintenance = new(Color.FromRgb(0x34, 0x98, 0xDB)); // blue
    private static readonly SolidColorBrush Default = new(Color.FromRgb(0x7F, 0x8C, 0x8D));     // gray

    static StatusToColorConverter()
    {
        Running.Freeze(); IdleStarved.Freeze(); IdleBlocked.Freeze();
        Fault.Freeze(); Maintenance.Freeze(); Default.Freeze();
    }

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is MachineStatus status ? status switch
        {
            MachineStatus.Running => Running,
            MachineStatus.IdleStarved => IdleStarved,
            MachineStatus.IdleBlocked => IdleBlocked,
            MachineStatus.Fault => Fault,
            MachineStatus.Maintenance => Maintenance,
            _ => Default
        } : Default;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
