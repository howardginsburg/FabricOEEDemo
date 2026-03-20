using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using FabricOEESimulator.Wpf.ViewModels;

namespace FabricOEESimulator.Wpf.Controls;

public partial class AllLinesOverview : UserControl
{
    public AllLinesOverview()
    {
        InitializeComponent();
    }

    private void LineCard_Click(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.Tag is ProductionLineViewModel line
            && DataContext is MainViewModel vm)
        {
            vm.SelectedLine = line;
            vm.IsOverviewMode = false;
        }
    }
}
