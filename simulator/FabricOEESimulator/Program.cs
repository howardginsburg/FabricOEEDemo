using FabricOEESimulator.Configuration;
using FabricOEESimulator.Display;
using FabricOEESimulator.Simulation;
using FabricOEESimulator.Telemetry;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using NetEscapades.Configuration.Yaml;
using Serilog;

var host = Host.CreateDefaultBuilder(args)
    .ConfigureAppConfiguration((context, config) =>
    {
        config.Sources.Clear();
        config.AddJsonFile("appsettings.json", optional: true, reloadOnChange: false);
        config.AddYamlFile("simulator.yaml", optional: false, reloadOnChange: false);
        config.AddYamlFile("simulator.local.yaml", optional: true, reloadOnChange: false);
        config.AddEnvironmentVariables("OEE_");
    })
    .UseSerilog((context, loggerConfig) =>
    {
        loggerConfig
            .MinimumLevel.Information()
            .WriteTo.File("logs/simulator-.log",
                rollingInterval: RollingInterval.Day,
                outputTemplate: "{Timestamp:yyyy-MM-dd HH:mm:ss.fff} [{Level:u3}] {Message:lj}{NewLine}{Exception}");
    })
    .ConfigureServices((context, services) =>
    {
        // Bind configuration
        services.Configure<SimulatorConfig>(context.Configuration.GetSection("simulator"));

        // Register telemetry sink based on broker type
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

        // Register telemetry log (shared tracker for recent sends)
        services.AddSingleton<TelemetryLog>();

        // Register display and engine
        services.AddSingleton(sp =>
        {
            var pageSize = context.Configuration.GetValue<int>("Display:PageSize");
            return new ConsoleDisplay(pageSize > 0 ? pageSize : 10);
        });
        services.AddHostedService<SimulationEngine>();
    })
    .Build();

await host.RunAsync();
