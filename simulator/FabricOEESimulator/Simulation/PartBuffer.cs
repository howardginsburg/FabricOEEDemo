using System.Threading.Channels;
using FabricOEESimulator.Models;

namespace FabricOEESimulator.Simulation;

public sealed class PartBuffer
{
    private readonly Channel<Part> _channel;

    public int Capacity { get; }

    public int Count => _channel.Reader.Count;

    public PartBuffer(int capacity)
    {
        Capacity = capacity;
        _channel = Channel.CreateBounded<Part>(new BoundedChannelOptions(capacity)
        {
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = true,
            SingleWriter = true
        });
    }

    public ValueTask WriteAsync(Part part, CancellationToken ct) =>
        _channel.Writer.WriteAsync(part, ct);

    public ValueTask<Part> ReadAsync(CancellationToken ct) =>
        _channel.Reader.ReadAsync(ct);

    public bool TryRead(out Part? part) =>
        _channel.Reader.TryRead(out part);

    public bool TryPeekCount(out int count)
    {
        count = _channel.Reader.Count;
        return true;
    }
}
