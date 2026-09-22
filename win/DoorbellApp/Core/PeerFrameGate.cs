using System;
using System.Collections;
using System.Globalization;
using System.Collections.Generic;

namespace DoorbellApp.Core
{
    public sealed class PeerFrameGate
    {
        public sealed class Identity
        {
            public string Door, CallId, Owner;
            public int Revision;
            public long CoreGeneration, ViewGeneration;

            public bool Matches(Identity other)
            {
                return other != null && Door == other.Door && CallId == other.CallId &&
                    Owner == other.Owner && Revision == other.Revision &&
                    CoreGeneration == other.CoreGeneration && ViewGeneration == other.ViewGeneration;
            }

            public string Query => "?door=" + Uri.EscapeDataString(Door) + "&call_id=" +
                Uri.EscapeDataString(CallId) + "&stage_revision=" + Revision.ToString(CultureInfo.InvariantCulture);
        }

        private Identity _displayed;
        private string _mediaGeneration;
        private long _sequence;

        public static Identity Capture(CallTiming.Snapshot snapshot, string door, string callId,
                                       long viewGeneration)
        {
            if (snapshot == null || snapshot.CoreGeneration <= 0 ||
                string.IsNullOrEmpty(door) || string.IsNullOrEmpty(callId)) return null;
            object calls;
            if (snapshot.Document == null || !snapshot.Document.TryGetValue("active_calls", out calls) ||
                !(calls is IEnumerable)) return null;
            Identity result = null;
            foreach (var item in (IEnumerable)calls)
            {
                var call = item as Dictionary<string, object>;
                if (CallTiming.Text(call, "door") != door || CallTiming.Text(call, "call_id") != callId ||
                    CallTiming.Text(call, "state") != "in_call") continue;
                long? revision = CallTiming.Milliseconds(call, "stage_revision");
                string owner = CallTiming.Text(call, "dialog_owner");
                if (!revision.HasValue || revision.Value > int.MaxValue || string.IsNullOrEmpty(owner) ||
                    result != null) return null;
                result = new Identity { Door = door, CallId = callId, Owner = owner,
                    Revision = (int)revision.Value, CoreGeneration = snapshot.CoreGeneration,
                    ViewGeneration = viewGeneration };
            }
            return result;
        }

        public bool Accept(Identity requested, Identity current, string callId, string revision,
                           string owner, string mediaGeneration, string sequence)
        {
            if (requested == null || !requested.Matches(current) || requested.CallId != callId ||
                requested.Revision.ToString(CultureInfo.InvariantCulture) != revision ||
                requested.Owner != owner || mediaGeneration == null || mediaGeneration.Length != 32 ||
                string.IsNullOrEmpty(sequence) || sequence.Length > 19 || sequence[0] == '0') return false;
            foreach (char c in mediaGeneration)
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
            foreach (char c in sequence) if (c < '0' || c > '9') return false;
            long number;
            if (!long.TryParse(sequence, NumberStyles.None, CultureInfo.InvariantCulture, out number) || number <= 0)
                return false;
            if (requested.Matches(_displayed) && _mediaGeneration == mediaGeneration && number <= _sequence)
                return false;
            _displayed = requested;
            _mediaGeneration = mediaGeneration;
            _sequence = number;
            return true;
        }

        public void Reset()
        {
            _displayed = null;
            _mediaGeneration = null;
            _sequence = 0;
        }
    }
}
