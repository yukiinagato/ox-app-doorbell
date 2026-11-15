using System;
using System.Collections.Concurrent;
using System.Threading;

namespace DoorbellApp.Settings
{
    /// <summary>
    /// Runs settings writes one at a time, in submission order, off the dispatcher thread.
    /// A later write therefore never overtakes an earlier one for the same key.
    /// </summary>
    internal sealed class WriteLane : IDisposable
    {
        private readonly BlockingCollection<Action> _queue = new BlockingCollection<Action>();
        private readonly Thread _worker;

        public WriteLane()
        {
            _worker = new Thread(Pump) { IsBackground = true, Name = "doorbell-settings-writes" };
            _worker.Start();
        }

        public void Run(Action work)
        {
            if (work == null) throw new ArgumentNullException("work");
            _queue.Add(work);
        }

        private void Pump()
        {
            foreach (Action work in _queue.GetConsumingEnumerable())
            {
                try { work(); }
                catch (Exception ex) { System.Diagnostics.Debug.WriteLine(ex); }
            }
        }

        public void Dispose()
        {
            _queue.CompleteAdding();
        }
    }

    /// <summary>
    /// The value a stepper shows while its write is still pending. Clicks change what is shown
    /// at once; only the final value is written, and a refused write puts the committed one back.
    /// </summary>
    internal sealed class StepAccumulator
    {
        private readonly double _min;
        private readonly double _max;
        private readonly double _step;

        public StepAccumulator(double committed, double min, double max, double step)
        {
            _min = min;
            _max = max;
            _step = step > 0 ? step : 1;
            Committed = committed;
            Shown = committed;
        }

        public double Committed { get; private set; }
        public double Shown { get; private set; }
        public bool Dirty { get { return Math.Abs(Shown - Committed) >= 1e-9; } }

        public double Snap(double wanted)
        {
            double next = Math.Round(wanted / _step) * _step;
            return Math.Min(_max, Math.Max(_min, next));
        }

        public double Set(double wanted)
        {
            Shown = Snap(wanted);
            return Shown;
        }

        public void Succeeded(double written)
        {
            Committed = written;
        }

        public double Failed()
        {
            Shown = Committed;
            return Shown;
        }
    }
}
