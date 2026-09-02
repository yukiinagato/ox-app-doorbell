# Optional root keepalive helper

`tools/helper/doorbell_keepalive.c` implements the fixed-purpose supervisor used by this
contract. It is opt-in provisioning for rooted/jailbroken devices, not a default application
dependency. The repository can produce a reproducible staged iOS 5 package, but no iOS 5 or
Android device has completed the helper qualification gate yet. Installing the package does not
create or load an active LaunchDaemon.

## Security boundary

- The helper opens one fixed filesystem `AF_UNIX` socket and no TCP socket. The `ios5` profile uses
  `SOCK_DGRAM`; the `android` profile uses `SOCK_STREAM` to match `RootKeepaliveClient`. It never
  invokes a shell, accepts an executable path, accepts application arguments, or reboots the OS.
- Production `--profile` values select compiled argument vectors only: iOS 5 executes
  `/usr/bin/uiopen doorbell://` as the configured app UID; Android executes
  `/system/bin/app_process /system/bin com.android.commands.am.Am startservice --user 0 -n
  jp.keihan.doorbell/.DoorbellService` with fixed `CLASSPATH=/system/framework/am.jar`. It does not
  invoke the Android `am` shell wrapper. Before launch, the fixed target must be a root-owned,
  non-writable, non-symlink ELF/Mach-O executable; scripts are rejected.
- The socket is created mode `0660`. The root-owned service configuration supplies the installed
  app's numeric UID and socket GID. A pre-existing symlink or non-socket at the socket path is a
  fatal error.
- Android checks `SO_PEERCRED` on every accepted stream and permits only root or the configured app
  UID; `KICK` and its peer PID must be the app UID. Apple datagram sockets do not expose equivalent
  per-message credentials on this compatibility path, so iOS relies on root-owned directory and
  socket permissions, then verifies every heartbeat PID belongs to the configured app UID before
  monitoring or signaling it.
- Status, safe-mode marker, and mode are written through same-directory temporary files and atomic
  rename; the helper fsyncs the file and then the parent directory where the target supports
  directory fsync (old kernels may report it unsupported). A symlink at any destination is
  rejected. The mode file must be owned by the helper UID with exact mode `0600`.

The service examples are templates. Packaging must set the exact installed UID/GID, ensure every
parent directory is root-owned and not group-writable, and install the reviewed binary and service
definition atomically.

## Modes and bounded protocol

`--mode-file` stores the configured mode across helper and OS restart. `--mode` is only the initial
default when that file does not exist. The fixed `MODE off|auto|on` command persists first and then
applies this behavior:

- `off`: retain status/control visibility but never launch or supervise the app;
- `auto`: remain armed across helper/OS restart and launch the fixed app after startup/backoff;
- `on`: arm at helper startup and launch the fixed profile when no valid heartbeat arrives.

Changing to `off` stops supervision and future launches but does not terminate an app that is
already running. Android `DISABLE` remains a transient disarm available only while configured mode
is `auto`; the persisted mode is unchanged.

### iOS 5 datagram protocol

Heartbeat datagrams are at most 2,048 bytes and must match `protocol-v1.schema.json` exactly.
Unknown, duplicate, escaped, missing, or out-of-range fields are rejected. The existing iOS client
sends `started`, `heartbeat`, `memory_pressure`, and `stopping` messages every three seconds from
the main run loop. A missing main-run-loop heartbeat therefore detects a live but frozen UI.
Helper liveness is not application readiness: the helper never handles `mesh.psk`, never receives
`psk_hex`, and never converts `pairing_persistence_error` into a paired/ready state.

The only non-JSON iOS datagrams are:

```text
STATUS
MODE off|auto|on
MAINTENANCE_BEGIN <1..3600 seconds>
MAINTENANCE_END
SAFE_MODE_CLEAR
```

There is no generic command or argument field. `MODE` and maintenance commands are accepted from
identities permitted by the root-owned socket on old Apple. `MAINTENANCE_BEGIN` creates a monotonic
lease that pauses supervision without changing the configured mode; supervision resumes when the
lease expires. `STATUS` and maintenance commands may come from root or the app UID on
credential-capable platforms. `SAFE_MODE_CLEAR` is root-only when peer credentials can be
verified. On the Apple permission-only path, stop the helper and remove the marker through the
controlled maintenance workflow instead. Replies, when the sender binds a return socket, are JSON
datagrams no longer than 512 bytes.

### Android stream protocol

The socket is exactly `/dev/socket/doorbell_keeper` in the example integration. Each connection
contains one newline-terminated ASCII command, at most 512 bytes:

```text
STATUS
MODE off|auto|on
ENABLE
DISABLE
KICK <positive elapsedRealtimeMs>
PAUSE_LEASE <1..3600 seconds>
```

`ENABLE`/`DISABLE` arm or disarm only when the persisted mode permits it: `off` rejects `ENABLE`,
`on` rejects `DISABLE`, and `auto` permits both. A valid app-UID `ENABLE` also records its peer PID;
`KICK` refreshes the heartbeat only when `SO_PEERCRED` and PID ownership both match the configured
app UID. `PAUSE_LEASE` pauses fixed supervision until monotonic expiry. Every reply is one JSON line
under 512 bytes with exactly the compatibility fields `enabled`, `running`, `version`, `safe_mode`,
and `error`; current Android clients may ignore `safe_mode`.

## Supervision and safe mode

The default heartbeat timeout is 15 seconds and the post-launch heartbeat timeout is 30 seconds.
The helper never launches two instances concurrently. For a heartbeat hang it first sends
`SIGTERM` only to the UID-validated app PID, waits five seconds, and then uses `SIGKILL` if the same
PID is still alive.

Restart delays are exactly 2, 5, 10, 30, and 60 seconds, with 60 seconds retained for later
failures. Three detected failures in five minutes enter safe mode. Safe mode is visible in the
atomic status file, persists in the marker file, and adds `DOORBELL_SAFE_MODE=1` to the fixed
launcher environment. It does not reboot the OS or broaden the launcher arguments.

Status includes mode, supervision state, arming, safe mode, app PID, heartbeat age, restart count,
next restart, remaining maintenance lease, peer-credential enforcement, and a bounded reason. It
contains no heartbeat payload or credential.

## Build and host tests

Run without root on macOS or Linux:

```sh
tools/helper/test_keepalive_helper.sh
tools/helper/build_keepalive_helper.sh \
  --output build/helper/doorbell-keepalive
```

The tests compile a testing-only fixed launcher profile and cover both transports, strict parsing,
mode transitions and restart persistence, mode-file symlink rejection, socket permissions,
maintenance leases, atomic status, arbitrary-launcher rejection, backoff, and safe mode. The
production binary does not contain the testing profile or its executable-path option.

For the licensed iOS 5 toolchain, use the same source with the historical SDK rather than copying
an SDK or binary into the repository:

```sh
DB_ALLOW_DIRTY=1 DB_BUILD_ID=<reviewed-build-id> \
  ios-compat/scripts/build_helper_ios5.sh
```

The script verifies armv7, the iOS 5.1 deployment target, jailbreak signing, and forbidden
post-iOS-5 imports. It writes the binary, reproducible staged DEB, and source/toolchain/hash
manifest under `build/ios-compat/artifacts/ios5-armv7-keepalive/`. A dirty-tree build requires the
explicit build ID shown above and is not release evidence.

The Android binary can be built from the same source with the pinned tier NDK compiler. The
example init definition is `tools/helper/examples/android/doorbell-keepalive.rc.example`; it must
be integrated with an explicit SELinux domain and the installed app UID for the commissioned ROM.

## Installation and rollback

`jp.keihan.doorbell.keepalive.plist.example` is a root-owned iOS LaunchDaemon template. The DEB
stages the verified helper as `/usr/local/libexec/doorbell-keepalive` mode `0755` and the inactive
template under `/usr/local/share/doorbell/`; it deliberately does not write
`/Library/LaunchDaemons`. Use a commissioned, non-default SSH password:

```sh
SSHPASS='<commissioned-root-password>' \
  ios-compat/scripts/install_helper_ios5.sh --stage
SSHPASS='<commissioned-root-password>' \
  ios-compat/scripts/install_helper_ios5.sh --status
```

Enabling remains a separate controlled qualification action. The installer verifies the exact
mobile UID/GID, fixed launcher and helper paths, ownership-sensitive files, and refuses to replace
a different active definition:

```sh
DB_CONFIRM_ROOT_HELPER=YES SSHPASS='<commissioned-root-password>' \
  ios-compat/scripts/install_helper_ios5.sh --enable
```

Do not enable it merely because jailbreak access exists. Disable it before upgrading or removing
the staged package:

```sh
SSHPASS='<commissioned-root-password>' \
  ios-compat/scripts/install_helper_ios5.sh --disable
```

Rollback order:

1. change the provisioned mode to `off` and confirm the app's local fallback;
2. unload and stop the root service;
3. use `install_helper_ios5.sh --disable` to remove the fixed active definition, socket, status,
   mode, and safe-mode marker while retaining the staged package for inspection;
4. remove the staged package only after the active definition is absent, and retain only bounded
   diagnostic status needed for review.

Hardware release evidence still requires cold boot, hang/crash, crash-loop, maintenance expiry,
UID/permission rejection, rollback, power-loss, and long-duration tests on the exact iOS/Android
device and root environment.
