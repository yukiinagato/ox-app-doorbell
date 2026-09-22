# T15 Windows receiver independent review

Result: PASS in the inspected scope. Reviewer: `/root/t02_translation`, independent of the Windows implementation by `/root`. Reviewed on 2026-09-23 JST.

The real `MainWindow.PollPeerFrame` captures the current local door/call/revision/owner and Core/view identity before the worker starts. It uses a relative-to-loopback fixed endpoint with escaped identity query, disables redirects, caps the body at 1 MiB, and combines a 2-second abort timer with request/read timeouts. `OnSipInCall` and `CloseInCall` retire the request and view generation. A late worker cannot clear another request's busy flag, because final dispatch first compares the actual owned request object. Before rendering it captures current Core/call state again and delegates the five header checks to production `PeerFrameGate`.

The gate rejects wrong call, owner, revision, Core/view generation, missing identity, malformed media generations, noncanonical/out-of-range sequences, duplicate frames and backwards sequences. Generation renewal resets only the sequence comparison for the new generation. The current single-flight receiver prevents an older parallel request from reintroducing a previously retired generation.

I inspected the implementation, its caller lifecycle and the supplied production helper test source. The parent-run raw evidence reports 36 helper assertions and 70 existing Windows contract assertions passing. I did not repeat those runs and did not launch WPF. This is code review plus existing actual Mono helper evidence, not a full Windows UI/network or physical display qualification. Cross-node media remains the T16 transport gate.

## Exact inspected source hashes

- `win/DoorbellApp/MainWindow.xaml.cs`: `0e6ae9cf2e56c466e41e3b5303b5cea30b28f5995d0297c61274c56d25d2c812`
- `win/DoorbellApp/Core/PeerFrameGate.cs`: `67aadedd395a0b4e00bbfae44514198b342937fd3de66f00cafef821d9b4927f`
- `win/DoorbellApp/Core/CallTiming.cs`: `a3ee7ad6489167be490735eb2d829f03d6e4884f9785f6ab476b3dae0898aca5`
- `win/tests/PeerFrameGateTests.cs`: `51520fa70512ddbce97180d5394339d18d823222b111457946db5edfaac7a179`
