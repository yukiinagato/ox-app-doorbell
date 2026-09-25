namespace DoorbellApp.Core
{
    public enum CallLifecycleReportResult { Accepted, Pending, Rejected }

    public sealed class CallLifecycleState
    {
        public CallLifecycleReportResult AnswerResult { get; private set; }
        public CallLifecycleReportResult EndResult { get; private set; }
        public bool AnswerReported { get; private set; }
        public bool Ended { get; private set; }

        public bool MayReportEnd => AnswerReported &&
            (AnswerResult == CallLifecycleReportResult.Accepted ||
             AnswerResult == CallLifecycleReportResult.Pending) && !Ended;

        public void Reset()
        {
            AnswerResult = CallLifecycleReportResult.Rejected;
            EndResult = CallLifecycleReportResult.Rejected;
            AnswerReported = false;
            Ended = false;
        }

        public bool RecordAnswer(CallLifecycleReportResult result)
        {
            AnswerReported = true;
            AnswerResult = result;
            if (result == CallLifecycleReportResult.Rejected) Ended = true;
            return result == CallLifecycleReportResult.Rejected;
        }

        public bool ConfirmOwner(bool ownerIsLocal)
        {
            AnswerReported = true;
            AnswerResult = ownerIsLocal
                ? CallLifecycleReportResult.Accepted : CallLifecycleReportResult.Rejected;
            if (!ownerIsLocal) Ended = true;
            return !ownerIsLocal;
        }

        public void RecordEnd(CallLifecycleReportResult result)
        {
            EndResult = result;
            Ended = true;
        }
    }
}
