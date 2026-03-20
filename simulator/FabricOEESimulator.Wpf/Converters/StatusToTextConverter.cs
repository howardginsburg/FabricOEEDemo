using System.Globalization;
using System.Windows.Data;
using FabricOEESimulator.Wpf.Models;

namespace FabricOEESimulator.Wpf.Converters;

public sealed class StatusToTextConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is MachineStatus status ? status switch
        {
            MachineStatus.Running => "RUNNING",
            MachineStatus.IdleStarved => "STARVED",
            MachineStatus.IdleBlocked => "BLOCKED",
            MachineStatus.Fault => "FAULT",
            MachineStatus.Maintenance => "MAINT",
            _ => "UNKNOWN"
        } : "UNKNOWN";

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
