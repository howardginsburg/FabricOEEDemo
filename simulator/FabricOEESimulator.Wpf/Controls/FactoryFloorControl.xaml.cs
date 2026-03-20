using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using FabricOEESimulator.Wpf.ViewModels;

namespace FabricOEESimulator.Wpf.Controls;

public partial class FactoryFloorControl : UserControl
{
    public static readonly DependencyProperty SelectedStationProperty =
        DependencyProperty.Register(
            nameof(SelectedStation),
            typeof(StationViewModel),
            typeof(FactoryFloorControl),
            new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.BindsTwoWayByDefault));

    public StationViewModel? SelectedStation
    {
        get => (StationViewModel?)GetValue(SelectedStationProperty);
        set => SetValue(SelectedStationProperty, value);
    }

    public FactoryFloorControl()
    {
        InitializeComponent();
    }

    private void StationCard_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.Tag is StationViewModel station)
        {
            SelectedStation = station;
        }
    }

    private void InjectFault_Click(object sender, RoutedEventArgs e)
    {
        if (sender is MenuItem mi && mi.Tag is StationViewModel station)
        {
            station.ForceInjectFault();
        }
    }
}
