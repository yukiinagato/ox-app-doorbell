# Security protocol v3

Status: accepted for implementation on branch `fix/full-review-2026-11`.
This revision deliberately breaks wire compatibility with v2. Every device must
run a v3 build, and every device except the migrated founder must be paired
again. There is no mixed v2/v3 cluster.

## 1. Goals

| Finding | v3 answer |
|---|---|
| A captured PIN join can be brute-forced offline | PAKE pairing (CPace over X25519) |
| One shared PSK, self-asserted peer IDs, removal is advisory | Per-device Ed25519 identity, replicated membership, PSK rotation on removal |
| No forward secrecy on the mesh channel | Ephemeral X25519 in every mesh handshake |
| Camera endpoints are unauthenticated and `ACAO: *` | Media authentication on every media route, no wildcard CORS |
| Core HTTP is cleartext on the LAN | TLS listener (mbedTLS) with a per-node certificate pinned through the mesh |
| Fast admin hash, 4-character minimum, first-password race | Argon2id, 8-character minimum, first password only from a trusted context |
| Native config writes bypass admin authentication | Native admin unlock window enforced in Core |
| Spoofed UDP INVITE can auto-answer a monitor call | Signed peer INVITE header, default-deny source list, SRTP between peers |
| Unauthenticated resource exhaustion | Pre-handshake caps, connection caps, stream caps, MQTT packet cap |

## 2. Device identity and membership

- On first start each node creates an Ed25519 key pair (Monocypher). The secret
  key is stored through platform secure storage as `secret:mesh.identity`; it is
  never written to config, events, logs or `boot.json`.
- The replicated key `mesh.members.<node_id>` holds
  `{"pk":"<hex32>","added_hlc":"…","added_by":"<node_id>"}`. Only a member may
  write membership. A node ID is accepted only when the handshake proves
  possession of the secret key that matches its member record.
- `removed_devices.<id>` stays as the audit marker. Removal deletes the member
  record and triggers PSK rotation (section 4). A removed node can no longer
  complete a handshake, whatever ID it claims.
- Roles in protocol messages (for example `pairing_revoked`) are taken from the
  member's replicated device record, never from the message.

## 3. Mesh handshake (replaces HS1/HS2/CONFIRM)

Frame types keep their numeric values; the protocol version byte `0x03` is
appended to HS1 and HS2. A v2 hello is rejected and the peer is reported with
`protocol_upgrade_required`.

1. Each side sends `HS = version ‖ node_id ‖ eph_x25519_pk ‖ nonce32`.
2. `dh = X25519(eph_sk, peer_eph_pk)`.
3. `transcript = BLAKE2b("doorbell-mesh-v3" ‖ psk_id ‖ HS_initiator ‖ HS_responder)`.
4. `session = BLAKE2b-keyed(psk, dh ‖ transcript)`; direction keys are derived
   from `session` with distinct labels.
5. CONFIRM carries `Ed25519_sign(identity_sk, "confirm" ‖ dir ‖ transcript)`
   plus the existing confirmation MAC. The receiver verifies the signature
   against `mesh.members.<peer_id>.pk`.
6. Data frames are unchanged (XChaCha20-Poly1305, monotonically numbered).

Until the first membership record for a peer has replicated, a node accepts a
peer that is listed in the most recent join or invitation it took part in
(section 5), so a fresh joiner can complete its first sync.

## 4. PSK rotation

- `psk_id` becomes `k<n>`. Removal or an explicit Admin "rotate" action makes
  the acting node generate `k<n+1>` and send it as `PSK_ROTATE` over each
  established v3 channel to current members only, encrypted under that
  channel. The new PSK is persisted through secure storage before use.
- Nodes accept handshakes with the previous PSK from members only, for a grace
  period of 7 days, so devices that were offline can catch up. After the grace
  period, or once every member has acknowledged, the previous PSK is erased.
- A member that missed rotation and is past the grace period must be paired
  again. The Admin device list shows it as `rekey_required`.

## 5. Pairing

### PIN join (CPace)

- `sid = 32` random bytes from the host; `G = elligator_map(BLAKE2b("doorbell-cpace-v3" ‖ pin ‖ sid ‖ host_id ‖ joiner_id))`.
- Each side picks a scalar `y`, sends `Y = y·G`; `K = BLAKE2b(sid ‖ Y_host ‖ Y_joiner ‖ y·Y_peer)`.
- Both sides exchange key-confirmation MACs before any payload is sent. A wrong
  PIN reveals nothing that can be checked offline; the existing three-attempt
  limit and token lifetime still bound online guessing.
- `JOIN_OK` is encrypted under `K`. It carries the current PSK and `psk_id`,
  the host's member record, and the full configuration snapshot. The joiner
  sends its identity public key inside the confirmed exchange; the host writes
  `mesh.members.<joiner>` before sending `JOIN_OK`.

### Invitation (QR or discovery)

The invite path already uses X25519 to the unpaired node's pairing key. In v3
the inviting Admin must obtain that key from the device itself (QR code shown
on the device, or a code the user confirms), never from an unauthenticated
beacon alone. The invite payload is the same as `JOIN_OK`.

### Joiner configuration

A first-run node seeds its defaults with the minimum HLC (`seed` timestamp
ordered below every real write). Real edits and tombstones from the cluster
always win over seeded defaults. On joining, the joiner keeps no seeded value
that the cluster already decided, and a deleted seeded rule stays deleted.

## 6. Migration from v2

- A v2 node that was the persisted founder (`pairing.is_founder=1`) migrates
  automatically on first v3 start: it creates its identity, writes its own
  member record, rotates to a fresh PSK and keeps its configuration and history.
- Every other v2-paired node keeps its local history but becomes unpaired with
  reason `upgrade_rejoin_required`, and must join the migrated founder by PIN
  or invitation.
- If the founder is gone, Admin on any upgraded node offers "Rebuild cluster
  from this device", which performs the same founder migration there.

## 7. HTTP and TLS

- Core links mbedTLS 3.6 LTS through CivetWeb `USE_MBEDTLS`. Listeners:
  - `47180` plain HTTP. Requests from loopback are served normally (native
    shells). Requests from any other address receive only a redirect to
    `https://<host>:47443` with the same path; no API, media or asset is served.
  - `47443` HTTPS for browsers and for Core-to-Core requests.
- Each node generates an ECDSA P-256 key and a self-signed certificate on first
  start. The key is stored as `secret:tls.key`. The certificate SHA-256
  fingerprint is replicated as `devices.<node_id>.tls_sha256`, written only by
  that member. Core-to-Core HTTPS clients pin that fingerprint.
- Browsers see a self-signed certificate. Admin shows the fingerprint and how
  to trust it. The fingerprint and an optional operator-provided certificate
  are documented in `docs/en/deployment.md`.
- Session and panel cookies are `HttpOnly; Secure; SameSite=Strict` on HTTPS,
  and are never set over plain non-loopback HTTP.

## 8. Media authentication

Media routes: `/stream.mjpeg`, `/stream.mp4`, `/snapshot.jpg`, `/video-meta`,
`/peer-frame.jpg`, `/stream-proxy.mp4`, `/snapshot-proxy`, `/call-frame`, and the
new local proxy routes below. Each request must present one of:

1. Loopback request with `X-Doorbell-Local: <token>`. The token is random per
   Core instance and returned by the new ABI call `db_core_local_token()`.
2. An admin session, or a panel session whose grant covers the door (existing
   checks), over HTTPS.
3. A peer request over HTTPS with
   `X-Doorbell-Peer: v1.<node_id>.<unix_ms>.<mac>` where
   `mac = BLAKE2b-keyed(media_key, method ‖ path_and_query ‖ unix_ms)`,
   `media_key = BLAKE2b-keyed(psk, "doorbell-media-v3")`, the timestamp is
   within ±60 s, and `node_id` is a current member.

No media response carries `Access-Control-Allow-Origin`.

### Local proxy for native shells

Native shells never fetch another node directly. Core publishes peer media URLs
as loopback proxy URLs, and fetches the peer over pinned HTTPS with the peer
header:

```
http://127.0.0.1:<port>/media/peer/<peer_id>/stream.mjpeg
http://127.0.0.1:<port>/media/peer/<peer_id>/stream.mp4
http://127.0.0.1:<port>/media/peer/<peer_id>/snapshot.jpg
http://127.0.0.1:<port>/media/peer/<peer_id>/video-meta
```

The suffix layout is preserved, so a shell that derives the snapshot URL from
the stream URL keeps working. Every native request to a loopback media URL adds
`X-Doorbell-Local`. For the browser, the same routes are served relative
(`/media/peer/<peer_id>/…`) and authenticated by the panel or admin session.

### Limits

At most 8 concurrent long-lived media responses per node (configurable as
`media.max_streams`); more receive `503` with `Retry-After`. CivetWeb runs 32
worker threads so control APIs keep free threads.

## 9. Administrator credential

- New hashes are Argon2id `m=8192 KiB, t=3, p=1`, encoded
  `argon2id$v=19$m=8192,t=3,p=1$<salt>$<hash>`. Legacy BLAKE2b digests are
  verified once and replaced on the next successful login.
- Minimum length is 8 characters for new passwords.
- When no password is set, the first password can be set only from a native
  shell (ABI) or from Admin over HTTPS or loopback with a trusted `Origin`.
- All token, CSRF and MAC comparisons are constant time.

## 10. Native admin window

`db_core_admin_check()` succeeding opens a native admin window of 10 minutes,
renewed by use and closed by `db_core_admin_lock()` or app backgrounding. While
it is closed, configuration writes through the ABI return `admin_required`,
except the documented non-administrative writes (SOS trigger/clear, visitor
interactions, pairing join, local media settings the shell owns).

## 11. SIP between peers

- The SIP allow list is deny-by-default until it is populated from membership.
- Peer INVITEs carry `X-Doorbell-Auth: v1.<node_id>.<unix_ms>.<mac>` over
  `Call-ID ‖ From ‖ To ‖ X-Doorbell-Mode ‖ unix_ms` with a key derived from the
  PSK. A missing or invalid header is rejected with `403`; monitor auto-answer
  requires a valid header.
- SRTP (SDES) is mandatory between peers and optional toward a configured
  external SIP server.

## 12. Transport limits

- Before a handshake completes: frames over 4 KiB close the connection, at most
  16 unauthenticated connections exist, and at most 4 per remote address.
- Total mesh connections are capped at 64.
- Beacons are MACed over `id ‖ addr ‖ unix_ms`, accepted within ±120 s, and
  compared in constant time.
- MQTT rejects a declared packet length above 256 KiB and supports TLS through
  the same mbedTLS build.

## 13. ABI additions (append-only)

```c
/* Loopback media token for X-Doorbell-Local. Owned by core, valid until db_core_destroy. */
DB_API const char* db_core_local_token(db_core* c);
/* Close the native admin window opened by db_core_admin_password_verify. */
DB_API void db_core_admin_lock(db_core* c);
/* Returned by int-valued configuration writes while the native admin window is closed.
 * db_core_config_batch_json reports the same condition as "error":"admin_required". */
#define DB_RESULT_ADMIN_REQUIRED (-20)
```

`db_core_open_door` keeps `-3` for "unlock not configured" and returns `-4` when a
configured unlock command fails to execute.

`db_platform_v2` gains one optional field appended after `power_state`:

```c
int (*https_request_v3)(void* user, const char* method, const char* url,
                        const char* headers_json, const uint8_t* body, size_t body_len,
                        uint8_t** resp_body_out, size_t* resp_len_out, int* http_status_out);
```

Core uses it when `struct_size` covers it and it is non-NULL; otherwise it falls
back to `https_request`. The response body is binary-safe and released with
`release_buffer`.
