using System.Globalization;
using System.Windows.Data;

namespace FabricOEESimulator.Wpf.Converters;

public sealed class BufferFillConverter : IMultiValueConverter
{
    public object Convert(object[] values, Type targetType, object parameter, CultureInfo culture)
    {
        if (values.Length >= 2 && values[0] is int count && values[1] is int capacity && capacity > 0)
            return (double)count / capacity;
        return 0.0;
    }

    public object[] ConvertBack(object value, Type[] targetTypes, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
