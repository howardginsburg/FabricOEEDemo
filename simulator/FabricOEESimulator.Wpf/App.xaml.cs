using System.Windows;
using FabricOEESimulator.Wpf.Configuration;
using FabricOEESimulator.Wpf.Simulation;
using FabricOEESimulator.Wpf.Telemetry;
using FabricOEESimulator.Wpf.ViewModels;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using NetEscapades.Configuration.Yaml;
using Serilog;

namespace FabricOEESimulator.Wpf;

public partial class App : Application
{
    private IHost? _host;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _host = Host.CreateDefaultBuilder(Environment.GetCommandLineArgs())
            .ConfigureAppConfiguration((_, config) =>
            {
                config.Sources.Clear();
                config.AddJsonFile("appsettings.json", optional: true, reloadOnChange: false);
                config.AddYamlFile("simulator.yaml", optional: false, reloadOnChange: false);
                config.AddYamlFile("simulator.local.yaml", optional: true, reloadOnChange: false);
                config.AddEnvironmentVariables("OEE_");
            })
            .UseSerilog((_, loggerConfig) =>
            {
                loggerConfig
                    .MinimumLevel.Information()
                    .WriteTo.File("logs/simulator-.log",
                        rollingInterval: RollingInterval.Day,
                        outputTemplate: "{Timestamp:yyyy-MM-dd HH:mm:ss.fff} [{Level:u3}] {Message:lj}{NewLine}{Exception}");
            })
            .ConfigureServices((context, services) =>
            {
                services.Configure<SimulatorConfig>(context.Configuration.GetSection("simulator"));

                services.AddSingleton<ITelemetrySink>(sp =>
                {
                    var config = sp.GetRequiredService<IOptions<SimulatorConfig>>().Value;
                    var loggerFactory = sp.GetRequiredService<ILoggerFactory>();

                    return config.Broker.Type.ToLowerInvariant() switch
                    {
                        "eventhub" => new EventHubSink(config.Broker, loggerFactory.CreateLogger<EventHubSink>()),
                        "mqtt" or "mqtttls" => new MqttSink(config.Broker, loggerFactory.CreateLogger<MqttSink>()),
                        _ => new ConsoleSink(loggerFactory.CreateLogger<ConsoleSink>())
                    };
                });

                services.AddSingleton<TelemetryLog>();
                services.AddSingleton<SimulationEngine>();
                services.AddHostedService(sp => sp.GetRequiredService<SimulationEngine>());
                services.AddSingleton<MainViewModel>();
            })
            .Build();

        await _host.StartAsync();

        var engine = _host.Services.GetRequiredService<SimulationEngine>();
        var viewModel = _host.Services.GetRequiredService<MainViewModel>();
        viewModel.Initialize(engine);

        var mainWindow = new MainWindow { DataContext = viewModel };
        mainWindow.Show();
        MainWindow = mainWindow;
    }

    protected override async void OnExit(ExitEventArgs e)
    {
        if (MainWindow?.DataContext is MainViewModel vm)
            vm.Shutdown();

        if (_host is not null)
        {
            await _host.StopAsync(TimeSpan.FromSeconds(5));
            _host.Dispose();
        }

        base.OnExit(e);
    }
}
