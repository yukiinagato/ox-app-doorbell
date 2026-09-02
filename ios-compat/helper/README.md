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
- The process-presence probe reads the kernel process table only (`KERN_PROC_ALL` on Apple,
  `/proc/<pid>/comm` on Linux) and matches two compiled-in names, `SpringBoard` and `Doorbell`,
  owned by the configured app UID. It never derives a name from configuration, the environment, or
  the socket, and it never signals or executes anything it finds.
- `--control` is a one-shot client mode of the same binary. It sends exactly one of four compiled
  payloads (`MAINTENANCE_BEGIN <n>`, `MAINTENANCE_END`, `STATUS`, `SAFE_MODE_CLEAR`) to the fixed
  socket and exits; no caller string reaches the socket and the daemon side never starts. It exists
  because iOS 5 ships no UNIX-datagram command-line tool, so an upgrade script has no other way to
  take a maintenance lease before it kills the app.

The service examples are templates. Packaging must set the exact installed UID/GID, ensure every
parent directory is root-owned and not group-writable, and install the reviewed binary and service
definition atomically.

## Modes and bounded protocol

Precedence, highest first: the root kill switch file, then the persisted mode, then the maintenance
lease, then heartbeat-driven supervision.

`--mode-file` stores the configured mode across helper and OS restart. `--mode` is only the initial
default when that file does not exist. The fixed `MODE off|auto|on` command persists first and then
applies this behavior:

- `off`: retain status/control visibility but never launch or supervise the app;
- `auto`: remain armed across helper/OS restart and launch the fixed app after startup/backoff;
- `on`: arm at helper startup and launch the fixed profile when no valid heartbeat arrives.

Changing to `off` stops supervision and future launches but does not terminate an app that is
already running. Android `DISABLE` remains a transient disarm available only while configured mode
is `auto`; the persisted mode is unchanged.

### Root kill switch

While the root-owned regular file named by `--disable-file`
(`/var/db/doorbell-keepalive.disable` in the shipped template) exists, the helper reports mode
`off` and state `disabled_by_file`, never launches, and never charges a failure. It is checked on
every supervision tick, outranks every socket command, and does **not** rewrite the persisted
administrator mode: `configured_mode` in the status file still shows what `MODE` last stored, and
removing the file restores it. A symlink or a file owned by anyone but the helper UID is ignored.
`/var/db` is root-only, so the app UID cannot engage or release it.

```sh
ios-compat/scripts/install_helper_ios5.sh --disable-file   # engage
ios-compat/scripts/install_helper_ios5.sh --enable-file    # release
```

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

### Cold boot and the SpringBoard gate

launchd starts the daemon at `RunAtLoad`, which on an iPad 1 is minutes before SpringBoard exists.
`uiopen doorbell://` fails silently in that window, so the `ios5` profile:

1. holds the first launch for a bounded boot grace (20 seconds, state `boot_grace`);
2. then requires a `SpringBoard` process owned by the app UID before any `execv`; while it is
   absent the state is `waiting_springboard` and **no failure is charged and no backoff armed**;
3. inspects the launcher child's exit status. A nonzero or signalled `uiopen` is the distinct
   reason `launcher_failed` rather than an indistinguishable 30-second `startup_timeout`.

Without this the daemon burned all three failure slots on every cold boot and reached safe mode
before the device finished booting.

### A running app that has not started its heartbeat

The app PID used to be learned from heartbeats alone, so an unprovisioned app sitting in bootstrap
setup was relaunched on every startup timeout forever. Both sides are fixed: the app now announces
`started` from the bootstrap-setup branch as well, and the helper falls back to process presence.
When no heartbeat has arrived but a `Doorbell` process owned by the app UID exists, the state is
`launch_pending_no_heartbeat` — the helper neither relaunches nor charges a failure.

### Who starts the app after a reboot

The app declares the `voip` background mode, so iOS 5 itself relaunches it after a reboot — in
the background, never activated. On iPad 1 the helper therefore usually finds the process already
present at boot and never runs its own launcher; the activation nudge below is what brings that
process to the front. The helper's launcher is the fallback for a process that is genuinely absent.

### Activation nudge (iOS 5 `uiopen` starts the app in the background)

Observed on iPad 1 / iOS 5.1.1: a process started by the helper's `uiopen` comes up with Core
running and listening, but SpringBoard never activates it — no heartbeat arrives and the screen
stays on the launcher, or on the post-boot lock screen. A second `uiopen` against the running
process activates it. While a present app stays silent (`launch_pending_no_heartbeat` with
`app_process_present` true and SpringBoard up), the helper therefore re-runs the fixed launcher
every `--activate-interval-ms` (default 15000; `0` disables). A nudge is not a launch: it charges
no failure, arms no backoff, counts against no cap, runs with `DOORBELL_ACTIVATE=1`, and stops on
the first heartbeat. After a boot the first nudge after the operator unlocks the device brings the
app to the front. Status reports the running total as `activation_nudges`.

### Expected exits

An exit the system asked for is not a crash. A `stopping` heartbeat marks the next process
disappearance as `clean_exit`, and a process that dies under a maintenance lease is
`maintenance_exit`. Neither consumes a failure slot or lengthens the backoff ladder; both relaunch
after a fixed short delay when the mode still arms supervision. `MODE off` and the kill switch stop
supervision before any exit accounting runs at all.

### Absolute safe-mode cap

Safe mode alone still relaunches. After `DB_SAFE_MODE_LAUNCH_CAP` (10) launches performed while
safe mode is latched, the helper stops launching entirely, logs the cap once, and reports state
`launch_inhibited` while continuing to serve `STATUS` and every control command. Only clearing safe
mode resets it; a mode change does not bypass it.

Clearing safe mode: `SAFE_MODE_CLEAR` is root-only and therefore available only where peer
credentials can be verified (Linux/Android). On the Apple datagram path, removing the root-owned
marker file is the equivalent and supported clear — `/var/db` is writable only by root, and the
running helper notices the removal on its next tick, resets the failure window, backoff, and launch
cap, and reports `safe_mode_cleared`:

```sh
ios-compat/scripts/install_helper_ios5.sh --clear-safe-mode
```

### Bounded diagnostics

`--log-max-bytes` (default 262144, `0` disables) caps the launchd-redirected log. When stderr is a
regular file and exceeds the cap, the helper truncates it in place and writes one
`log truncated` line. Where stderr is a pipe the cap is a no-op and the caller's own bounds apply.

### Status fields

Status includes mode, supervision state, arming, safe mode, app PID, heartbeat age, restart count,
next restart, remaining maintenance lease, peer-credential enforcement, and a bounded reason, plus
`configured_mode`, `disabled_by_file`, `launch_inhibited`, `ui_ready`, and `app_process_present`.
It contains no heartbeat payload or credential. `mode` reflects what supervision is actually doing
(`off` while the kill switch is engaged); `configured_mode` reflects what `MODE` persisted.

## Build and host tests

Run without root on macOS or Linux:

```sh
tools/helper/test_keepalive_helper.sh
tools/helper/build_keepalive_helper.sh \
  --output build/helper/doorbell-keepalive
```

The tests compile a testing-only fixed launcher profile and cover both transports, strict parsing,
mode transitions and restart persistence, mode-file symlink rejection, socket permissions,
maintenance leases, atomic status, arbitrary-launcher rejection, backoff, and safe mode, plus the
cold-boot SpringBoard gate, the boot grace, launcher-exit reporting, the no-heartbeat presence
fallback, the kill switch, the safe-mode launch cap and its clear, expected-exit accounting, the
log bound, and the `--control` vocabulary. The production binary does not contain the testing
profile, its executable-path option, or the process-table test seam: the seam is a
`DB_KEEPALIVE_TESTING`-only `--test-process-file` argument, never an environment variable, and the
production build has no way to override the compiled process names.

Both suites also run from `ios-compat/scripts/test_host.sh` and from the `keepalive-helper` job in
`.github/workflows/build.yml`.

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

The installer reaches the device over USB through `iproxy <local> 22`. This project's forwarded
port is **2223**; override it with `DB_IOS_SSH_LOCAL_PORT`. Pass an IP address instead to use
Wi-Fi. `--status` reads the atomic status file and reports the active definition and kill switch;
`launchctl list` output is advisory only, because it is not reliable from an SSH session.

`launchctl load` run over SSH on iOS 5 frequently answers `Socket is not connected`: that session
has no launchd bootstrap port. The installer still attempts the load, then polls for the socket and
status file, and **never reports success without them**. If the load did not take effect it prints
the reboot instruction and exits 40; the definition is loaded at the next boot, after which
`--status` is the confirmation.

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

Upgrading the app while the helper is active does not need a disable. `ios-kiosk/scripts/
install_via_ssh.sh` and `ios-compat/scripts/install_deb.sh` take a 300-second maintenance lease
through `--control begin` before they kill Doorbell and release it with `--control end`
afterwards. Both calls are no-ops when the socket or binary is absent, which is the default.

Rollback order:

1. engage the kill switch (`--disable-file`) for an immediate, reversible stop, or change the
   provisioned mode to `off`, and confirm the app's local fallback;
2. unload and stop the root service;
3. use `install_helper_ios5.sh --disable` to remove the fixed active definition, socket, status,
   mode, safe-mode marker, and kill switch while retaining the staged package for inspection;
4. remove the staged package only after the active definition is absent, and retain only bounded
   diagnostic status needed for review.

## Device qualification checklist

The helper stays **hardware-unqualified** until every item below is recorded on the exact device
and root environment. Nothing here is satisfied by host tests. Run over `iproxy 2223` unless the
device is reachable on Wi-Fi.

| # | Check | Pass condition |
|---|---|---|
| 1 | Cold boot ×3 | Each boot reaches `healthy` with `restart_count_5m` 0 and `safe_mode` false; the log shows `waiting_springboard`/`boot_grace` and then one `launch`, never three failures. |
| 2 | Unprovisioned boot | With bootstrap setup open, status settles at `launch_pending_no_heartbeat` or `healthy` with `app_process_present` true; the app is never relaunched under the setup screen. |
| 3 | Kill | `killall Doorbell` relaunches once with `process_exited` and the 2-second delay. |
| 4 | Hang | A frozen main run loop yields `heartbeat_timeout`, one `SIGTERM`, then `SIGKILL` after 5 s, then one relaunch. |
| 5 | Crash loop | Three failures inside five minutes set `safe_mode`, write the marker, and pass `DOORBELL_SAFE_MODE=1`; the 2/5/10/30/60-second ladder appears in the log. |
| 6 | Launch cap | Continue the crash loop past ten safe-mode launches: state becomes `launch_inhibited`, launching stops, `STATUS` still answers, and `--clear-safe-mode` restores launching. |
| 7 | Maintenance lease | `--control begin` pauses supervision; the app can be killed with no failure charged (`maintenance_exit`); the lease expires on its own and supervision resumes. |
| 8 | Permission rejection | A datagram from a non-app, non-root UID is ignored; the socket is `0660 root:mobile`; `SAFE_MODE_CLEAR` is refused on this path. |
| 9 | Mode wiring | `MODE off\|auto\|on` persists across a helper restart and a reboot; the app's runtime `recovery` section agrees with the helper status. |
| 10 | Kill switch | `--disable-file` forces `mode` `off` and `state` `disabled_by_file` within one tick while `configured_mode` is unchanged; `--enable-file` resumes without a failure. |
| 11 | Upgrade under the helper | A full and a fast `install_via_ssh.sh` run complete with no relaunch mid-swap and `restart_count_5m` unchanged. |
| 12 | Power loss | Cut power during runtime and during a launch; after boot the mode file, marker, and status are valid or absent, never truncated. |
| 13 | Soak | 24 h minimum: no leak, no unbounded log (`/var/log/doorbell-keepalive.log` stays under the cap), no spurious relaunch. |
| 14 | Rollback | `--disable` removes the active definition and runtime state; the app keeps working on its local watchdog; the staged package survives. |

Only after all fourteen are recorded may the hardware-unqualified status be changed.
