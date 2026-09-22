using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;

namespace DoorbellApp.Core
{
    // JSON durations are Core-sampled; Stopwatch only reduces a displayed duration.
    public sealed class CallTiming
    {
        public sealed class Snapshot
        {
            public Dictionary<string, object> Document;
            public long CoreGeneration;
            public double RequestedAtMs;
        }

        public sealed class Reading
        {
            public Dictionary<string, object> Call;
            public long CoreGeneration;
            public bool Absent;
            public double? RemainingMs;
            public double? RecoveryRemainingMs;
        }

        private string[] _identity;
        private double? _deadline, _recoveryDeadline;
        private long _sampleCore;
        private string _sample = "";
        private bool _awaitFresh;

        public static double MonotonicMs => Stopwatch.GetTimestamp() * (1000.0 / Stopwatch.Frequency);

        public static string Text(Dictionary<string, object> document, string key)
        {
            object value;
            return document != null && document.TryGetValue(key, out value) ? value as string ?? "" : "";
        }

        public static long? Milliseconds(Dictionary<string, object> document, string key)
        {
            object value;
            if (document == null || !document.TryGetValue(key, out value) ||
                !(value is int || value is long || value is double || value is decimal)) return null;
            try
            {
                decimal number = Convert.ToDecimal(value);
                if (number < 0 || number > 9007199254740991m || decimal.Truncate(number) != number)
                    return null;
                return (long)number;
            }
            catch { return null; }
        }

        public void RequireFresh(Snapshot baseline)
        {
            if (baseline != null && !string.IsNullOrEmpty(Text(baseline.Document, "snapshot_generation")))
            {
                _sampleCore = baseline.CoreGeneration;
                _sample = Text(baseline.Document, "snapshot_generation");
            }
            _identity = null;
            _deadline = _recoveryDeadline = null;
            _awaitFresh = true;
        }

        public bool Accepts(Snapshot snapshot)
        {
            if (snapshot == null || snapshot.CoreGeneration <= 0 ||
                string.IsNullOrEmpty(Text(snapshot.Document, "snapshot_generation")) ||
                !Milliseconds(snapshot.Document, "snapshot_age_ms").HasValue) return false;
            string sample = Text(snapshot.Document, "snapshot_generation");
            if (_awaitFresh && (_sample == "" ||
                (_sampleCore == snapshot.CoreGeneration && _sample == sample)))
            {
                _sampleCore = snapshot.CoreGeneration;
                _sample = sample;
                return false;
            }
            _awaitFresh = false;
            _sampleCore = snapshot.CoreGeneration;
            _sample = sample;
            return true;
        }

        public Reading Observe(Snapshot snapshot, string callId, double nowMs)
        {
            if (!Accepts(snapshot) || string.IsNullOrEmpty(callId) ||
                double.IsNaN(nowMs) || double.IsInfinity(nowMs) ||
                double.IsNaN(snapshot.RequestedAtMs) || double.IsInfinity(snapshot.RequestedAtMs) ||
                nowMs < snapshot.RequestedAtMs) return null;
            object value;
            if (!snapshot.Document.TryGetValue("active_calls", out value) || !(value is IList))
                return null;
            Dictionary<string, object> call = null;
            foreach (object item in (IEnumerable)value)
            {
                var candidate = item as Dictionary<string, object>;
                if (Text(candidate, "call_id") == callId) { call = candidate; break; }
            }
            if (call == null) return new Reading { Absent = true, CoreGeneration = snapshot.CoreGeneration };
            if (Text(call, "snapshot_generation") != _sample ||
                !Milliseconds(call, "stage_revision").HasValue) return null;
            string state = Text(call, "state");
            if (state != "ringing" && state != "purpose_pending" && state != "in_call") return null;
            var identity = new[] { snapshot.CoreGeneration.ToString(), _sample, callId,
                Text(call, "door"), Text(call, "dialog_owner"), state,
                Milliseconds(call, "stage_revision").Value.ToString() };
            bool same = _identity != null;
            for (int i = 0; same && i < identity.Length; i++) same = _identity[i] == identity[i];
            long age = Milliseconds(snapshot.Document, "snapshot_age_ms").Value;
            var duration = Milliseconds(call, "remaining_ms");
            var recovery = Milliseconds(call, "recovery_remaining_ms");
            if (recovery.HasValue && recovery.Value > 10000) recovery = null;
            double? deadline = duration.HasValue
                ? (double?)(snapshot.RequestedAtMs + Math.Max(0L, duration.Value - age)) : null;
            double? recoveryDeadline = recovery.HasValue
                ? (double?)(snapshot.RequestedAtMs + Math.Max(0L, recovery.Value - age)) : null;
            if (!same) { _identity = identity; _deadline = deadline; _recoveryDeadline = recoveryDeadline; }
            else
            {
                if (deadline.HasValue) _deadline = _deadline.HasValue ? Math.Min(_deadline.Value, deadline.Value) : deadline;
                if (recoveryDeadline.HasValue) _recoveryDeadline = _recoveryDeadline.HasValue
                    ? Math.Min(_recoveryDeadline.Value, recoveryDeadline.Value) : recoveryDeadline;
            }
            return new Reading { Call = call, CoreGeneration = snapshot.CoreGeneration,
                RemainingMs = deadline.HasValue && _deadline.HasValue ? (double?)Math.Max(0, _deadline.Value - nowMs) : null,
                RecoveryRemainingMs = recoveryDeadline.HasValue && _recoveryDeadline.HasValue
                    ? (double?)Math.Max(0, _recoveryDeadline.Value - nowMs) : null };
        }

        public static bool OwnedRecovery(Dictionary<string, object> call, string node,
                                         string role, string door)
        {
            object required;
            if (call == null || string.IsNullOrEmpty(node) ||
                !call.TryGetValue("recovery_required", out required) || !Equals(required, true)) return false;
            string state = Text(call, "state");
            if (state == "in_call") return Text(call, "dialog_owner") == node;
            return (state == "ringing" || state == "purpose_pending") && role == "door_station" &&
                Text(call, "origin") == node && Text(call, "door") == door;
        }

        public static bool CallbackMatches(long expectedCore, string expectedCall, long expectedRevision,
                                           long currentCore, string currentCall, long currentRevision)
        {
            return expectedCore > 0 && expectedCore == currentCore &&
                expectedCall == currentCall && expectedRevision == currentRevision;
        }
    }
}
