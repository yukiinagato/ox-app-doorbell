namespace DoorbellApp.Ui
{
    internal enum VisitorActionKind { Cancel, End }

    /// <summary>A held input belongs to the displayed call and phase, even if the UI changes.</summary>
    internal sealed class VisitorActionGuard
    {
        private bool _pressed;
        private string _call;
        private long _generation;
        private long _revision;
        private VisitorActionKind _kind;
        private long _inputRevision;

        internal long Begin(string call, long generation, long revision, VisitorActionKind kind)
        {
            _pressed = true;
            _call = call ?? "";
            _generation = generation;
            _revision = revision;
            _kind = kind;
            return ++_inputRevision;
        }

        internal void CompleteInput(long inputRevision)
        {
            if (inputRevision == _inputRevision) _pressed = false;
        }

        internal bool Consume(string call, long generation, long revision,
                              VisitorActionKind kind, bool phaseVisible)
        {
            bool current = !_pressed || (_call == (call ?? "") && _generation == generation &&
                                        _revision == revision && _kind == kind);
            _pressed = false;
            return phaseVisible && current;
        }
    }

    /// <summary>Nested modal dispatch must not confirm a replaced or cancelled SOS review.</summary>
    internal sealed class SosReviewGuard
    {
        private long _revision;
        internal long Begin() { return ++_revision; }
        internal void Revoke() { ++_revision; }
        internal bool Consume(long revision, long expectedGeneration, long currentGeneration,
                              bool available)
        {
            if (revision != _revision) return false;
            ++_revision;
            return available && expectedGeneration == currentGeneration;
        }
    }
}
