using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using FabricOEESimulator.Wpf.ViewModels;

namespace FabricOEESimulator.Wpf.Controls;

public partial class ToastOverlay : UserControl
{
    public ToastOverlay()
    {
        InitializeComponent();
    }

    private void Toast_Click(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.Tag is ToastNotification toast
            && DataContext is MainViewModel vm)
        {
            vm.DismissToastCommand.Execute(toast);
        }
    }
}
