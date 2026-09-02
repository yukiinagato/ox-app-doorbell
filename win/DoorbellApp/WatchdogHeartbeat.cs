using System;
using System.Threading;

namespace DoorbellApp
{
    internal sealed class WatchdogHeartbeat : IDisposable
    {
        public const string EventName = @"Global\DoorbellAppHeartbeat.v1";
        private readonly Timer _timer;
        private int _available;
        private long _lastSignalWallMs;

        public bool Available => Volatile.Read(ref _available) != 0;
        public long LastSignalWallMs => Interlocked.Read(ref _lastSignalWallMs);

        public WatchdogHeartbeat()
        {
            Signal(null);
            _timer = new Timer(Signal, null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
        }

        private void Signal(object state)
        {
            try
            {
                using (var heartbeat = EventWaitHandle.OpenExisting(EventName)) heartbeat.Set();
                Volatile.Write(ref _available, 1);
                Interlocked.Exchange(ref _lastSignalWallMs,
                    (DateTime.UtcNow.Ticks - 621355968000000000L) / TimeSpan.TicksPerMillisecond);
            }
            catch (WaitHandleCannotBeOpenedException) { Volatile.Write(ref _available, 0); }
            catch (UnauthorizedAccessException) { Volatile.Write(ref _available, 0); }
        }

        public void Dispose() => _timer.Dispose();
    }
}
