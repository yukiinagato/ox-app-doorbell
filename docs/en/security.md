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

Rotating the mesh PSK deliberately makes records sealed by the previous PSK unreadable. After a
PSK rotation or re-pair, open every enrolled browser/profile, re-enable Push for each required
group, and verify a real delivery before treating Push as recovered. `configured` or backend-ready
status alone does not prove that closed browsers were re-enrolled.

## Access and transport boundaries

The mesh authenticates/encrypts peer traffic with the cluster PSK. The full v3 contract is in
[security protocol v3](security-v3.md); its HTTP and SIP parts are summarized here.

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
2. Remove the node in Admin (this rotates the mesh PSK) and confirm every remaining member reports
   the new key.
3. Rotate SIP, MQTT, Telegram, WebRTC, media-camera, admin, and panel credentials/tokens that the
   device could access.
4. Update secure stores first, then their `secret:` references if the reference name changes.
5. Verify old tokens and the removed node can no longer connect; verify release capabilities and
   runtime status on every remaining node.
6. Restore configuration separately from secrets and confirm that backups/logs contain no secret
   values.

Never commit Apple SDKs, signing material, provisioning profiles, private keys, secure-store
exports, generated binaries, or real deployment addresses and credentials.
