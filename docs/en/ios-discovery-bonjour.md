# iOS Discovery over Bonjour

Status: design note, not implemented. Written 2026-09-06 after the first sandboxed iOS node
(an iPhone 17 on iOS 26, signed with a free personal team) joined the household cluster.
Manual pairing by host + PIN is the supported workaround until this lands.

## Problem

Mesh discovery is a UDP multicast beacon on `239.255.71.71:47171`
(`core/src/mesh/udp_beacon.cpp`). Since iOS 14 an app may send or receive multicast only with
the `com.apple.developer.networking.multicast` entitlement. Apple grants it on request to paid
Developer Program members; a personal team cannot hold it. The kernel drops the packets
silently, so `IP_ADD_MEMBERSHIP` succeeds and Core never logs a failure:

```
kernel: necp_check_restricted_multicast_drop: Dropping unentitled multicast (SDK 0x1a0500, min 0xc0000)
```

Consequences on such a node:

- It is invisible to the cluster and sees no peers, so the pairing screen never lists anything.
- Unicast is unaffected. `POST /api/pairing/join {host,pin}` works, `seed_peers` is persisted
  in `boot.json`, and every mesh link afterwards is unicast TCP. Only automatic discovery is lost.
- Broadcast (`255.255.255.255`) is restricted by the same rule, so it is not an alternative.

Not affected: iOS 12 shells (the rule starts at iOS 14), jailbroken shells with injected
entitlements, Windows, Android.

## Constraint that shapes the design

Bonjour through the system APIs (`NWListener`, `NWBrowser`, `NetService`) is exempt: the
multicast is done by `mDNSResponder`, not by the app. A raw mDNS socket opened by Core would hit
the same drop. Therefore:

- on iOS the mDNS traffic must go through the platform API, and
- every other platform must speak mDNS too, or the iPhone advertises to nobody and hears nobody.

## Design

1. **Discovery set.** `IDiscovery` (`core/src/mesh/transport.h`) already abstracts the beacon.
   Add `DiscoverySet : IDiscovery` that fans `start/announce/stop/setPairAnnounce/setPairFound/
   setPsk` out to several backends and merges their callbacks, deduplicated by node id.
   The multicast beacon stays; where it is blocked it simply contributes nothing.
2. **Shared beacon codec.** Move the HELLO and pair-announce encode/verify out of `UdpBeacon`
   into `mesh/beacon_packet.{h,cpp}`. The Bonjour TXT record carries the same MAC-authenticated
   JSON, so cluster-membership security is unchanged and tested once.
3. **Service shape.** Type `_doorbell._udp`, instance name = node id, port = mesh listen port.
   TXT: `v=1` and the packet as base64 in `p0`, `p1`, … (one TXT string is limited to 255
   bytes; a HELLO is about 150 bytes, a pair-announce may need two chunks). Peer addresses come
   from the resolved SRV/A records; the packet's own `addr` is still verified through the MAC.
4. **Platform SPI.** Append to `db_platform_v2` (fields are only ever appended):
   `int (*discovery_advertise)(user, service_type, instance, txt_json)` where an empty
   `txt_json` stops advertising, and `int (*discovery_browse)(user, service_type, on)`.
   Add `db_core_discovery_result(core, json)` for the shell to push a resolved service
   `{"instance","addrs":[…],"port","txt":{…}}`. Core wraps these in
   `PlatformDiscovery : IDiscovery`. Shells that leave the hooks `NULL` get no Bonjour backend.
5. **iOS shell.** `NWListener(service:)` to advertise, `NWBrowser` to browse and resolve, both
   feeding the hooks above. `Info.plist` gains `NSBonjourServices = ["_doorbell._udp"]`
   (browsing is refused without it on iOS 14+). Local Network permission is still required
   and is requested by the system on first use.
6. **Everyone else.** A minimal mDNS responder and browser in Core (`mesh/mdns.{h,cpp}`): PTR,
   SRV, TXT and A records for the service above, three unsolicited announcements then answers
   to PTR queries, and a PTR query every few seconds while browsing. It reuses the multicast
   helpers in `socket_compat.h`. Windows, Android, Linux hosts and the jailbroken iPads get it
   through Core with no shell work.
7. **Configuration.** `discovery.mdns = on|off`, default `on`. Traffic is a few packets per
   node per announcement interval, comparable to the beacon.

## Security

The HELLO stays keyed by the cluster PSK; the pair-announce stays unauthenticated by design,
exactly as on the beacon today. TXT records are readable by anyone on the LAN, which is the same
exposure the multicast beacon already has. No secrets ever appear in a TXT record.

## Rollout

1. Core: codec extraction, `DiscoverySet`, `PlatformDiscovery`, SPI fields, in-memory tests.
   iOS shell backend. Verify with a host node on the Mac as the peer.
2. Core mDNS backend. Verify Windows ↔ iPhone on the household LAN.
3. Android and the kiosk pick it up through Core; qualify on hardware.

Rejected alternatives: a unicast subnet sweep (slow, noisy, wrong on larger networks);
broadcast (restricted the same way); relying on the multicast entitlement alone (requires the
paid program plus Apple's approval; still worth requesting for the App Store build, but it
does not help test builds).

## Open points

- Whether to advertise while unpaired. The beacon does (pair-announce), so mirror it.
- Bonjour stops when the app is suspended, like every other socket the shell owns; the
  keepalive story is unchanged.
- Service type registration with IANA is optional for a private LAN service.
