# Optional rooted-Android keepalive helper

Android 4.4 has no native lock-task mode. The neutral helper at
`tools/helper/doorbell_keepalive.c` can be separately provisioned on a rooted device whose
commissioned image has no dependable kiosk facility. It is implemented and host-tested, but the
repository has no completed Android hardware/SELinux qualification or installable helper package.

The helper has no TCP listener, shell, arbitrary executable/argv input, or OS reboot operation. Its
`android` launcher profile is compiled as this exact command:

```text
CLASSPATH=/system/framework/am.jar
/system/bin/app_process /system/bin com.android.commands.am.Am startservice --user 0 -n jp.ox.doorbell/.DoorbellService
```

`--mode-file` persists `off|auto|on`; command-line `--mode` is only its first-run default. `MODE
off|auto|on` atomically persists transitions. Both persisted `auto` and `on` are armed at helper
startup and launch the fixed app after startup/backoff; `off` never launches. Changing to `off`
does not terminate an app that is already running. In `auto`, `ENABLE`/`DISABLE` may transiently
arm or disarm supervision without changing the persisted mode. Configured mode is distinct from
measured socket availability and effective runtime mode.

The helper owns the `AF_UNIX/SOCK_STREAM` socket `/dev/socket/doorbell_keeper` mode `0660`. Every
accepted stream is checked with `SO_PEERCRED`; only root or the installed app UID is accepted, and
`KICK` additionally requires the peer PID to belong to that app UID.

The exact newline-terminated commands are `STATUS`, `MODE off|auto|on`, `ENABLE`, `DISABLE`, `KICK
<positive elapsedRealtimeMs>`, and `PAUSE_LEASE <1..3600>`. There is no shell or generic command.
Every reply is a JSON line under 512 bytes with `enabled`, `running`, `version`, `safe_mode`, and
`error`. A maintenance lease pauses supervision until monotonic expiry. The helper uses
2/5/10/30/60-second restart backoff; three failures in five minutes create atomic safe-mode
marker/status and set `DOORBELL_SAFE_MODE=1` for the fixed launcher. It never reboots the device.

Build and test on a host with:

```sh
tools/helper/test_keepalive_helper.sh
tools/helper/build_keepalive_helper.sh \
  --output build/helper/doorbell-keepalive
```

`tools/helper/examples/android/doorbell-keepalive.rc.example` is an init template, not a portable
installer. A target integration must replace its sample UID/GID, define the root-owned data/socket
directories and SELinux domain, compile with the pinned target NDK, and refuse an unknown root or
SELinux environment. Verify boot-complete ordering, heartbeat/hang recovery, maintenance expiry,
crash-loop safe mode, socket peer rejection, rollback, and long-duration stability on the exact ROM
before advertising the helper capability.
