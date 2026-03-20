using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace FabricOEESimulator.Wpf.Converters;

public sealed class MachineTypeToIconConverter : IValueConverter
{
    public object? Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not string machineType || string.IsNullOrEmpty(machineType))
            return Application.Current.TryFindResource("Unknown-Machine");

        return Application.Current.TryFindResource(machineType)
            ?? Application.Current.TryFindResource("Unknown-Machine");
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
