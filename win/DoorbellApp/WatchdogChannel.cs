using System;
using System.Collections.Concurrent;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using System.Windows.Threading;

namespace DoorbellApp
{
    /// <summary>
    /// The app's side of the supervisor channel (win/watchdog/main.cpp). The service accepts only
    /// the process it launched, so these messages cannot be forged by another local program:
    /// "hb" every two seconds from the UI dispatcher (a hung UI thread stops them), "unlock N" /
    /// "lock" for the kiosk unlock window, and "expect clean|restart|session" just before a
    /// deliberate exit. The service may answer "exit &lt;reason&gt;" when the console session
    /// changes or the service stops. All pipe I/O runs on one background thread.
    /// </summary>
    internal sealed class WatchdogChannel : IDisposable
    {
        public const string PipeName = "DoorbellWatchdog.v1";
        private sealed class Outgoing
        {
            public string Text;
            public ManualResetEventSlim Sent;
        }

        private readonly DispatcherTimer _beat;
        private readonly BlockingCollection<Outgoing> _outbox =
            new BlockingCollection<Outgoing>(new ConcurrentQueue<Outgoing>(), 64);
        private readonly Thread _io;
        private readonly bool _supervised;
        private volatile bool _disposed;
        private int _available;
        private long _lastSignalWallMs;

        /// <summary>Raised on the channel thread when the supervisor asks the app to exit.</summary>
        public event Action<string> ExitRequested;

        public bool Available => Volatile.Read(ref _available) != 0;
        public long LastSignalWallMs => Interlocked.Read(ref _lastSignalWallMs);

        public WatchdogChannel(Dispatcher dispatcher, bool supervised)
        {
            _supervised = supervised;
            // Normal priority: the beat is meant to stop when the UI thread is stuck, not when it
            // is merely busy rendering.
            _beat = new DispatcherTimer(TimeSpan.FromSeconds(2), DispatcherPriority.Normal,
                (sender, args) => Enqueue("hb", null), dispatcher);
            _io = new Thread(Run) { IsBackground = true, Name = "watchdog-channel" };
            _io.Start();
            _beat.Start();
            Enqueue("hb", null);
        }

        /// <summary>Keeps the supervisor from relaunching a closed app for this long.</summary>
        public void Unlock(TimeSpan duration)
        {
            Enqueue("unlock " + (int)Math.Max(60, duration.TotalSeconds), null);
        }

        public void Lock() => Enqueue("lock", null);

        /// <summary>
        /// Announces why the app is about to exit and waits briefly until the supervisor has the
        /// message, so the exit is not counted as a crash.
        /// </summary>
        public void ExpectExit(string reason)
        {
            if (!Available) return;
            using (var sent = new ManualResetEventSlim(false))
            {
                if (Enqueue("expect " + reason, sent)) sent.Wait(1000);
            }
        }

        private bool Enqueue(string text, ManualResetEventSlim sent)
        {
            if (_disposed) return false;
            try { return _outbox.TryAdd(new Outgoing { Text = text, Sent = sent }); }
            catch (InvalidOperationException) { return false; }
        }

        private void Run()
        {
            while (!_disposed)
            {
                NamedPipeClientStream pipe = null;
                try
                {
                    pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut,
                                                     PipeOptions.Asynchronous);
                    pipe.Connect(_supervised ? 2000 : 500);
                    pipe.ReadMode = PipeTransmissionMode.Message;
                    Volatile.Write(ref _available, 1);
                    StartReader(pipe);
                    Pump(pipe);
                }
                catch (TimeoutException) { }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                catch (InvalidOperationException) { }
                finally
                {
                    Volatile.Write(ref _available, 0);
                    try { pipe?.Dispose(); } catch { }
                }
                if (_disposed) break;
                // Not supervised: a supervisor started later is still found, just less eagerly.
                Thread.Sleep(_supervised ? 1000 : 10000);
            }
        }

        private void Pump(NamedPipeClientStream pipe)
        {
            while (!_disposed && pipe.IsConnected)
            {
                Outgoing item;
                if (!_outbox.TryTake(out item, 1000)) continue;
                byte[] bytes = Encoding.ASCII.GetBytes(item.Text);
                try
                {
                    pipe.Write(bytes, 0, bytes.Length);
                    pipe.Flush();
                    if (item.Text == "hb")
                        Interlocked.Exchange(ref _lastSignalWallMs,
                            (DateTime.UtcNow.Ticks - 621355968000000000L) /
                            TimeSpan.TicksPerMillisecond);
                }
                finally
                {
                    try { item.Sent?.Set(); } catch (ObjectDisposedException) { }
                }
            }
        }

        private void StartReader(NamedPipeClientStream pipe)
        {
            var buffer = new byte[256];
            AsyncCallback onRead = null;
            onRead = result =>
            {
                int read;
                try { read = pipe.EndRead(result); }
                catch { return; }
                if (read <= 0) return;
                string message = Encoding.ASCII.GetString(buffer, 0, read).Trim();
                if (message.StartsWith("exit ", StringComparison.Ordinal))
                {
                    try { ExitRequested?.Invoke(message.Substring(5)); } catch { }
                }
                try { pipe.BeginRead(buffer, 0, buffer.Length, onRead, null); } catch { }
            };
            pipe.BeginRead(buffer, 0, buffer.Length, onRead, null);
        }

        public void Dispose()
        {
            _disposed = true;
            _beat.Stop();
            _outbox.CompleteAdding();
            _io.Join(1500);
        }
    }
}
