# Event conformance harness

`run.py` replays the versioned golden traces in `fixtures/event-traces-v2.json`
through a bounded reference projection for every declared platform profile. It
also checks narrow source anchors that bind the reference behavior to each
client's actual event-routing and SOS channel implementation.

Run it from the repository root:

```sh
python3 tools/conformance/run.py
python3 -m unittest tools/tests/test_event_conformance.py
python3 -m unittest tools/tests/test_visitor_flow_conformance.py
```

The platform profiles are protocol expectations, not hardware certification.
Source anchors prove routing structure but cannot prove UIKit, Android,
browser, or WPF timing and rendering. Platform unit/build jobs and physical
hardware gates remain authoritative for those behaviors.

The reducer accepts at most 256 events per trace. Its call cache, resolved-call
set, and chime replay set are independently bounded so malformed fixtures
cannot create unbounded test memory use.

## Visitor flow fixture

`fixtures/visitor-flow-v1.json` is the contract for the door-station wizard
(`docs/en/visitor-flow-contract.md`). Its `resolve` cases give a configuration
and the resolved document Core must produce (and whether the write validator
accepts it); `core/tests/test_visitor_flow.cpp` replays them against the C++
resolver. Its `walk` cases give a tap sequence and the screen and Core calls a
shell must produce; `visitor_flow.py` holds the reference walker (`FlowWalker`),
which `run.py` replays and which each shell ports. The golden document is
checked by `check_resolved_document` for the structural guarantees.
