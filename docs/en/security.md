# Security operations

The system is designed for a trusted home LAN, not direct Internet exposure. Put remote access
behind a maintained VPN or an authenticated TLS reverse proxy and restrict node ports to the
trusted segment. See [network ports](network-ports.md).

## Secret-storage contract

- Persistent configuration, CRDT values, events, logs, URLs, diagnostics, exports, and
  `boot.json` must not contain plaintext credentials.
- Ordinary secret-bearing configuration stores only references such as
  `psk_ref: "secret:mesh.psk"`, SIP `pass_ref`, MQTT `pass_ref`, Telegram `bot_token_ref`, WebRTC
  `sip_pass_ref`, media-source `secret_ref`, and panel `token_refs`. The sealed, indivisible Web Push
  subscription exception is described below.
- Secret values are written through `db_platform_v2.secure_put` and read through `secure_get`.
  Platform stores are DPAPI on Windows, Android secure storage, and Keychain on iOS. During new
  pairing, Core stores `mesh.psk` first and only then emits
  `{ "t": "paired", "psk_ref": "secret:mesh.psk" }`; it never sends `psk_hex` to the shell.
- If secure storage fails, Core emits `pairing_persistence_error`, does not emit `paired`, and the
  client must remain not-ready. `psk_hex` and legacy plaintext password/token fields are migration
  input only; do not add plaintext fallback instructions.
- Media URLs must not contain userinfo. Bind an explicit `media_sources.<id>.secret_ref`; never
  infer a camera URL from a seed peer.

All authenticated configuration write routes recursively reject plaintext credential fields,
invalid secret references, URL userinfo, and credential-bearing URL query parameters, including
when they are nested inside container objects or arrays. Configuration exports intentionally omit
secret values. A restore therefore requires restoring or
re-entering secrets on each device through its secure-storage path.

MQTT and Telegram references replicate as fleet configuration, but their values do not. After an
initial save or rotation, provision the currently referenced value through Admin on every node
that may lead that integration. Per-node provisioning reuses the reference without changing
configuration; verify every intended candidate reports the backend ready before relying on
failover. SIP passwords are likewise entered only through the target device's own Admin; remote
rows may change non-secret account metadata but cannot write a credential into the wrong device.

Panel references and their non-secret credential generation replicate, but panel token values do
not. Rotation replaces the reference and generation atomically; panel sessions are bound to both
and are rejected on every node after that configuration arrives. Copy the one-time rotation value
through an approved channel, then use **Provision on this node** on every node that serves Web
panels. Provisioning accepts only a currently referenced panel secret, writes local secure storage,
invalidates local panel sessions, and never changes or returns fleet configuration.

A Web Push subscription contains a bearer-like endpoint plus `p256dh` and `auth` key material, so
Core normalizes and seals all three together rather than storing only a reference. The schema-v2
CRDT record uses XChaCha20-Poly1305 with a key derived from the mesh PSK; materialized config,
diagnostics, and export never expose the plaintext values. Core opens a record only in bounded
memory when subscription operations or provider delivery require it; deletion derives the record
key from the submitted exact endpoint. On startup it reseals a legacy raw record when possible and
otherwise removes it fail-closed. A removed subscription must be enrolled again from the browser.
The Web page's non-secret group and page metadata remain outside the ciphertext; a validated
`?group=<name>` is persisted locally and reused for both state polling and Push enrollment.

A cluster key rotation (section below) reseals every subscription under the new key while the
previous key is still held, so Push survives a device removal. Re-pairing into a different
cluster, or a rotation after the seven-day grace period has expired on every node, makes records
sealed by the old key unreadable. In that case open every enrolled browser/profile, re-enable Push
for each required group, and verify a real delivery before treating Push as recovered.
`configured` or backend-ready status alone does not prove that closed browsers were re-enrolled.

## Mesh identity, pairing, and cluster keys (protocol v3)

The wire protocol is specified in [security-v3](security-v3.md). In short:

- Every node has an Ed25519 identity whose seed is stored only as `secret:mesh.identity`. The
  replicated `mesh.members.<node_id>` record holds its public key. A peer is accepted only when the
  handshake proves possession of the identity key in its member record; holding the cluster key
  is not membership. Roles used for authorization (for example who may send `pairing_revoked`)
  come from the replicated `devices.<id>` record of an authenticated member.
- Each mesh connection runs an ephemeral X25519 exchange keyed with the cluster PSK, so recorded
  traffic stays confidential even if the PSK leaks later. v2 peers are refused and reported as
  `protocol_upgrade_required` in `GET /api/pairing` (`security.legacy_peers`).
- PIN join uses CPace: a captured exchange cannot be tested offline against PIN guesses, and the
  three-attempt limit bounds online guessing. The host records the joiner's member identity
  before it sends the cluster key and configuration.
- A device discovered through the unauthenticated pairing beacon is invited only with the
  eight-digit confirmation code shown on that device (`self.confirm_code`). The bulk-add window
  lists devices but never sends the key without that code. A QR invitation carries the device's
  key directly and needs no code.
- Removing a device deletes its member record, records its identity as `mesh.revoked.<id>`, and
  rotates the cluster key (`k<n>.<fingerprint>`). Members that were offline catch up through the
  previous key, which only members may use, for seven days. The removed identity may complete one
  handshake with its old key only to receive its revocation and is then disconnected. A member
  that misses the whole grace period is listed in `security.rekey_required` and must be paired
  again. `POST /api/pairing/rotate` (and `db_core_rotate_cluster_key`) rotates on demand.
- Production shells run strict membership. `NodeOptions::mesh_enroll_psk_holders` (trust any key
  holder) exists only for tests and embedded hosts.

Upgrading from v2: the persisted founder migrates in place on its first v3 start, keeping its
configuration and history and moving to a fresh key. Every other v2 member drops its old key,
keeps its local configuration replica, reports `reason:"upgrade_rejoin_required"`, and must join
the founder by PIN or invitation. If the founder is gone, `POST /api/pairing/rebuild` on any such
device founds the cluster again from that device's configuration.

## Access and transport boundaries

The mesh authenticates every peer by member identity and encrypts its traffic with keys derived
from the cluster PSK and a per-connection ephemeral exchange. Before a handshake completes, a node
accepts frames of at most 4 KiB, at most 16 unauthenticated connections (4 per address), and 64
connections in total. The full v3 contract is in [security protocol v3](security-v3.md); its HTTP
and SIP parts are summarized here.

- Port 47180 is plain HTTP for the device's own shell over loopback only. Any other client is
  redirected to HTTPS on 47443; while TLS is unavailable it is refused (`403 tls_required`).
- Each node creates an ECDSA P-256 key (secure-store entry `tls.key`) and a self-signed
  certificate, and publishes the certificate SHA-256 as `devices.<id>.tls_sha256`. Core-to-Core
  requests pin it. Browsers show a certificate warning until the operator trusts that certificate;
  Admin shows the fingerprint to compare.
- Media (`/stream.mjpeg`, `/stream.mp4`, `/snapshot.jpg`, `/video-meta`, `/peer-frame.jpg`,
  `/stream-proxy.mp4`, `/snapshot-proxy`, `/media/peer/<id>/...`) is never anonymous. A request
  needs one of: `X-Doorbell-Local` from loopback (the value of `db_core_local_token`), an admin
  session, a panel credential with the view grant (cookie, Bearer, or Basic password for Home
  Assistant and go2rtc), or a peer `X-Doorbell-Peer` MAC. No media response carries CORS headers.
  `GET /asset/<sha256>` stays public because assets are content-addressed theme images.
- Native shells read other nodes' cameras through their own Core at
  `http://127.0.0.1:<http_port>/media/peer/<peer_id>/...`; Core fetches the peer over pinned HTTPS.
- Cookies are `HttpOnly; SameSite=Strict`, plus `Secure` on HTTPS. Panel launch credentials are
  fragment-delivered; query credentials are rejected.
- Administrator digests are Argon2id (`m=8192 KiB, t=3, p=1`); a legacy BLAKE2b digest is replaced
  on the next successful login. New passwords need at least 8 characters. The first password can
  be set only by the device itself (native ABI, or a loopback client without `Origin`) or by an
  Admin page on this node over HTTPS/loopback.
- Native configuration writes require the native admin window (`DB_RESULT_ADMIN_REQUIRED`), opened
  for ten minutes by a successful password verification and closed by `db_core_admin_lock`.
- A handler still running at its five-second deadline answers `202` with `"outcome":"unknown"`;
  clients re-read state instead of retrying a mutation.
- Direct SIP INVITEs from members carry a single-use `X-Doorbell-Auth` MAC. INVITEs from the
  configured registrar (Asterisk) need no header and keep the registrar's auto-answer behavior.
  Everything else is refused with 403. SRTP is negotiated between PJSIP peers (`sip.srtp:
  "mandatory"` refuses plain RTP); toward a PBX it is optional.

Direct MiniSIP on legacy iOS is LAN-only UDP/PCMU without SRTP; it signs and checks INVITEs through
`db_core_sip_peer_auth` and `db_core_sip_inbound_check`. Clusters that include it must keep
`sip.srtp` at `optional`. Browser WebRTC
requires a secure browser context and a separately hardened Asterisk deployment. A jailbroken iOS
device belongs on an isolated trusted LAN; disable unnecessary services and use unique host access
credentials established by the operator. No default credential is documented or accepted here.

The optional root helper exposes only its fixed filesystem Unix socket. It has no TCP, shell,
arbitrary argv, or reboot operation. Android checks stream `SO_PEERCRED` and heartbeat PID
ownership; legacy Apple relies on root-owned socket permissions plus heartbeat PID ownership.
Mode, status, and safe-mode marker files are symlink-checked and atomically replaced. Keep their
parent directories root-owned, and never infer helper availability from configured `helper_mode`.

## Rotation and incident checklist

1. Remove the affected node from service and preserve bounded diagnostics if investigation is
   required.
2. Remove the device in Admin: its membership is deleted and the cluster key rotates
   automatically. Check `security.rekey_required` and re-pair any member listed there.
3. Rotate SIP, MQTT, Telegram, WebRTC, media-camera, admin, and panel credentials/tokens that the
   device could access.
4. Update secure stores first, then their `secret:` references if the reference name changes.
5. Verify old tokens and the removed node can no longer connect; verify release capabilities and
   runtime status on every remaining node.
6. Restore configuration separately from secrets and confirm that backups/logs contain no secret
   values.

Never commit Apple SDKs, signing material, provisioning profiles, private keys, secure-store
exports, generated binaries, or real deployment addresses and credentials.
