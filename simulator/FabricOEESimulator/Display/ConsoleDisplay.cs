using FabricOEESimulator.Models;
using FabricOEESimulator.Simulation;
using Spectre.Console;

namespace FabricOEESimulator.Display;

public sealed class ConsoleDisplay
{
    private readonly int _pageSize;
    private int _currentPage;

    public ConsoleDisplay(int pageSize = 10)
    {
        _pageSize = pageSize;
    }

    public async Task RunAsync(IReadOnlyList<ProductionLine> lines, MaintenanceManager maintenanceManager, CancellationToken ct)
    {
        // Build flat list of (lineId, station) for paging
        var allStations = new List<(string LineId, Station Station, bool IsFirstInLine)>();
        foreach (var line in lines)
        {
            bool first = true;
            foreach (var station in line.Stations)
            {
                allStations.Add((line.LineId, station, first));
                first = false;
            }
        }

        int totalStations = allStations.Count;
        int totalPages = Math.Max(1, (int)Math.Ceiling((double)totalStations / _pageSize));
        _currentPage = 0;

        // Listen for keyboard input on a background thread
        _ = Task.Run(() => ReadKeyInput(totalPages, ct), ct);

        var table = CreateTable(1, totalPages);

        await AnsiConsole.Live(table)
            .AutoClear(false)
            .Overflow(VerticalOverflow.Ellipsis)
            .StartAsync(async ctx =>
            {
                while (!ct.IsCancellationRequested)
                {
                    int page = _currentPage;
                    int skip = page * _pageSize;
                    var pageStations = allStations.Skip(skip).Take(_pageSize).ToList();

                    table = CreateTable(page + 1, totalPages);

                    foreach (var (lineId, station, isFirst) in pageStations)
                    {
                        var lineLabel = isFirst
                            ? $"[bold]{Markup.Escape(lineId)}[/]"
                            : "";

                        // If the first station on this page is a continuation, show the line id dimmed
                        if (!isFirst && pageStations.IndexOf((lineId, station, isFirst)) == 0)
                            lineLabel = $"[dim]{Markup.Escape(lineId)}[/]";

                        var statusMarkup = FormatStatus(station.Status);
                        var inBuf = station.InputBuffer is not null
                            ? $"{station.InputBuffer.Count}/{station.InputBuffer.Capacity}"
                            : "—";
                        var outBuf = station.OutputBuffer is not null
                            ? $"{station.OutputBuffer.Count}/{station.OutputBuffer.Capacity}"
                            : "—";

                        table.AddRow(
                            lineLabel,
                            Markup.Escape(station.MachineType),
                            station.Position.ToString(),
                            statusMarkup,
                            inBuf,
                            outBuf,
                            station.LastCycleTime > 0 ? $"{station.LastCycleTime:F1}" : "—",
                            station.TotalPartsProcessed.ToString("N0"),
                            station.RejectedParts.ToString("N0"),
                            Markup.Escape(station.CurrentPartId ?? "—"));
                    }

                    table.AddEmptyRow();

                    // Maintenance summary
                    var activeWOs = maintenanceManager.ActiveOrders;
                    if (activeWOs.Count > 0)
                    {
                        table.AddRow(
                            $"[bold red]Maint WOs[/]",
                            $"[red]{activeWOs.Count} active[/]",
                            "", "", "", "", "", "", "", "");
                    }

                    // Line throughput summary
                    foreach (var line in lines)
                    {
                        table.AddRow(
                            $"[bold cyan]{Markup.Escape(line.LineId)}[/]",
                            $"[bold cyan]Finished: {line.PartsProduced:N0} parts[/]",
                            "", "", "", "", "", "", "", "");
                    }

                    ctx.UpdateTarget(table);

                    try
                    {
                        await Task.Delay(2000, ct);
                    }
                    catch (OperationCanceledException)
                    {
                        break;
                    }
                }
            });
    }

    private static Table CreateTable(int currentPage, int totalPages)
    {
        return new Table()
            .Border(TableBorder.Rounded)
            .Title($"[bold cyan]OEE Production Line Simulator[/]  [dim]Page {currentPage}/{totalPages}  (← → to navigate)[/]")
            .AddColumn(new TableColumn("[bold]Line[/]").Width(12))
            .AddColumn(new TableColumn("[bold]Station[/]").Width(20))
            .AddColumn(new TableColumn("[bold]Pos[/]").Centered().Width(4))
            .AddColumn(new TableColumn("[bold]Status[/]").Centered().Width(14))
            .AddColumn(new TableColumn("[bold]In Buf[/]").Centered().Width(7))
            .AddColumn(new TableColumn("[bold]Out Buf[/]").Centered().Width(7))
            .AddColumn(new TableColumn("[bold]Cycle(s)[/]").Centered().Width(9))
            .AddColumn(new TableColumn("[bold]Processed[/]").RightAligned().Width(10))
            .AddColumn(new TableColumn("[bold]Rejected[/]").RightAligned().Width(9))
            .AddColumn(new TableColumn("[bold]Part ID[/]").Width(14));
    }

    private void ReadKeyInput(int totalPages, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            if (!Console.KeyAvailable)
            {
                Thread.Sleep(100);
                continue;
            }

            var key = Console.ReadKey(intercept: true);
            switch (key.Key)
            {
                case ConsoleKey.RightArrow:
                case ConsoleKey.PageDown:
                    if (_currentPage < totalPages - 1)
                        _currentPage++;
                    break;

                case ConsoleKey.LeftArrow:
                case ConsoleKey.PageUp:
                    if (_currentPage > 0)
                        _currentPage--;
                    break;

                case ConsoleKey.Home:
                    _currentPage = 0;
                    break;

                case ConsoleKey.End:
                    _currentPage = totalPages - 1;
                    break;
            }
        }
    }

    private static string FormatStatus(MachineStatus status) => status switch
    {
        MachineStatus.Running => "[bold green]Running[/]",
        MachineStatus.IdleStarved => "[bold yellow]Starved[/]",
        MachineStatus.IdleBlocked => "[bold yellow]Blocked[/]",
        MachineStatus.Fault => "[bold red]FAULT[/]",
        MachineStatus.Maintenance => "[bold red]MAINT[/]",
        _ => "[dim]Unknown[/]"
    };
}
