# Local test devices

## iPad Air 1

Designated by the user as a Doorbell test device on 2026-09-22. This device is
distinct from the existing iPad 1 and iPad mini 3.

| Field | Verified value |
| --- | --- |
| Model / architecture | iPad Air 1 cellular, `iPad4,2`, arm64 |
| Device name / OS | `iPad (2)`, iOS 12.5.8 (16H88) |
| USB UDID | `b05d91834431516e147fbc99c8f0bdc34ec38c32` |
| Wi-Fi IPv4 / SSH port | `10.10.38.199:44` |
| Wi-Fi MAC | `78:3a:84:a9:13:f3` |
| SSH account / authentication | `root`, dedicated Ed25519 key; LAN passwords disabled |
| Mac SSH alias | `doorbell-ipad-air1` |
| Installed application at registration | Doorbell 0.1.36, build 37, `jp.ox.doorbell` |

### Connect from this Mac

```sh
ssh doorbell-ipad-air1
ssh doorbell-ipad-air1 'uname -m; ifconfig en0'
scp -O artifact.tar.gz doorbell-ipad-air1:/private/var/tmp/
```

The alias is in `/Users/ox/.ssh/config`. Its private key is
`/Users/ox/.ssh/doorbell_ipad_air1_ed25519`; the pinned server identity is in
`/Users/ox/.ssh/known_hosts_doorbell`, under `doorbell-ipad-air1`. Never copy
private keys or passwords into project files, logs, or memory. Other computers
need their own authorized key; this alias does not grant remote/cloud agents
access by itself.

LAN access was verified from `10.10.38.24` directly to `10.10.38.199:44`, with
key authentication and strict host verification. The host key was obtained
through the already verified USB connection. The saved launchd configuration
was unloaded/reloaded and LAN login was retested. The LAN service advertises
only public-key authentication.

### Service and recovery

The existing checkra1n Dropbear binary is `/binpack/usr/sbin/dropbear`. A separate
socket-activated service, `jp.ox.doorbell.test-ssh-lan`, binds only to the listed
Wi-Fi IPv4 address. Its configuration is
`/var/root/doorbell-test-device/jp.ox.doorbell.test-ssh-lan.plist`; authorized keys
are in `/var/root/.ssh/authorized_keys`. The original loopback port 44 remains
available through USB.

The IP is a DHCP address, not a router reservation. If it changes, use USB to
read `ifconfig en0`, update `Sockets.LANListener.SockNodeName` in the service
plist and `HostName` in the Mac alias, then reload the service. Verify LAN login
again; USB success alone is insufficient.

```sh
iproxy -u b05d91834431516e147fbc99c8f0bdc34ec38c32 2248:44
```

In another terminal:

```sh
ssh doorbell-ipad-air1-usb 'ifconfig en0'
ssh doorbell-ipad-air1-usb 'launchctl load /var/root/doorbell-test-device/jp.ox.doorbell.test-ssh-lan.plist'
```

The USB alias uses the same key and pinned host identity. Use `launchctl unload`
with the same plist before loading an already registered service after a change.
No OS reboot was performed. A full reboot loses the active checkra1n environment;
after re-jailbreaking, load this plist through USB again. Its persistent file in
`/var/root` is not automatically loaded from the system LaunchDaemons directory.

### Application maintenance

At registration, the app bundle is
`/private/var/containers/Bundle/Application/64FD671A-D11A-464E-8D6B-C2A35A9F31F0/Doorbell.app`.
Resolve the current path with `uicache -l jp.ox.doorbell` before an update.
The reported app home is `/var/mobile`. To launch the app:

```sh
ssh doorbell-ipad-air1 '/binpack/usr/local/bin/lsdtrip.arm64 launch jp.ox.doorbell'
```

This minimal jailbreak has a read-only root filesystem. The deployed bundle
uses a platform-application signing entitlement and LaunchServices registration;
the bundled `uicache -p` refuses paths outside `/Applications`. Do not substitute
the iPad mini 3 install path. Keep signing profiles separate and verify the
device's version/build after deployment. Launch/process existence alone does
not qualify UI, pairing, SIP, or media behavior.

Follow the user's existing test-device policy: do not back up test-device app
bundles, data, or files. Prefer app-only restart during routine maintenance.
