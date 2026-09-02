# Event conformance harness

`run.py` replays the versioned golden traces in `fixtures/event-traces-v2.json`
through a bounded reference projection for every declared platform profile. It
also checks narrow source anchors that bind the reference behavior to each
client's actual event-routing and SOS channel implementation.

Run it from the repository root:

```sh
python3 tools/conformance/run.py
python3 -m unittest tools/tests/test_event_conformance.py
```

The platform profiles are protocol expectations, not hardware certification.
Source anchors prove routing structure but cannot prove UIKit, Android,
browser, or WPF timing and rendering. Platform unit/build jobs and physical
hardware gates remain authoritative for those behaviors.

The reducer accepts at most 256 events per trace. Its call cache, resolved-call
set, and chime replay set are independently bounded so malformed fixtures
cannot create unbounded test memory use.
