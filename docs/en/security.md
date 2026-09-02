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

The mesh authenticates/encrypts peer traffic with the cluster PSK. HTTP traffic on port 47180 is
not automatically Internet-grade: Admin and panel routes use their respective sessions, but the
LAN interoperability endpoints `/stream.mjpeg`, `/stream.mp4`, `/snapshot.jpg`, `/video-meta`, and
an exact `GET /asset/<64-lowercase-hex-sha256>` and `/peer-frame.jpg` are intentionally readable without a session for
native clients, HA, and go2rtc. Other `/asset` methods, malformed hashes, and suffix paths remain
authenticated or rejected. Keep
47180 on the trusted media LAN or put the entire port behind an authenticated TLS proxy; a panel
cookie is not video authorization. Panel launch credentials are fragment-delivered and exchanged
for an HttpOnly cookie; query credentials are rejected. Rotate access when a recipient or device
is removed.

Direct MiniSIP on legacy iOS is LAN-only UDP/PCMU and does not provide TLS or SRTP. Browser WebRTC
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
2. Rotate the mesh PSK and re-pair remaining nodes.
3. Rotate SIP, MQTT, Telegram, WebRTC, media-camera, admin, and panel credentials/tokens that the
   device could access.
4. Update secure stores first, then their `secret:` references if the reference name changes.
5. Verify old tokens and the removed node can no longer connect; verify release capabilities and
   runtime status on every remaining node.
6. Restore configuration separately from secrets and confirm that backups/logs contain no secret
   values.

Never commit Apple SDKs, signing material, provisioning profiles, private keys, secure-store
exports, generated binaries, or real deployment addresses and credentials.
