# Windows Build Environment (Apple Silicon Mac + local VM)

This is a setup recipe, not evidence that the current revision passed a Windows VM or Toughpad
validation run. Record the exact VM, toolchain, artifacts, and results before marking a build
verified; real-hardware commissioning remains separate.

Policy: iterate locally in a VM; (optionally) produce release artifacts on GitHub Actions.
Docker is not an option — Docker on macOS only runs Linux containers, and the WPF/.NET Framework
build chain exists only on Windows.

## 1. Set up a VM (Windows 11 ARM64)

| Software | Cost | Notes |
|---|---|---|
| UTM | Free | Import an ARM64 Win11 ISO/VHDX. Easy |
| VMware Fusion | Free for personal use | Stable. Has shared folders |
| Parallels | Paid | Best experience. Microsoft-endorsed Win11 ARM provisioning flow |

- Install Windows 11 ARM64 (via Microsoft's official Insider/ISO channel, or Parallels' automatic download).
- ARM64 Windows can run many x86/x64 tools under emulation, but the repository does not contain a
  completed validation record for this VM route. Treat it as a candidate build environment.

## 2. What to install in the VM

1. **Visual Studio 2022 Community** — workloads:
   - ".NET desktop development" (WPF / .NET Framework 4.8 SDK + targeting pack)
   - "Desktop development with C++" (MSVC v143, CMake, Windows 10 SDK)
   - Individual components: "MSVC v141 - VS 2017 C++ x64/x86 build tools"
     (an insurance policy for the real Win7 hardware. Slow under emulation on ARM64, but works)
2. **Git**, (optionally) **Claude Code** — so you can hand off work inside the VM too.
3. **Inno Setup 6** (installer creation, late Phase 1).

## 3. Sharing the repository

- Recommended: mount the Mac-side `~/Documents/project/app-doorbell` via VM shared folders
  (VMware/Parallels). Alternatively sync via git (exchanging per-commit).
- Build in a build directory on the VM's local disk (builds on a shared filesystem are slow):
  `win/build.cmd` sets this up accordingly.

## 4. Building (inside the VM)

```bat
win\build.cmd            :: core DLL (x86+x64, MSVC) + WPF app + run tests
```

Capture errors and the exact toolchain versions in the release record.

## 5. Pre-verification on the Mac (mingw-w64)

On the Mac, after `brew install mingw-w64`:

```bash
cmake -S core -B build-win64 -DCMAKE_TOOLCHAIN_FILE=core/cmake/mingw-w64.cmake && cmake --build build-win64 -j8
```

This catches most Winsock/API porting mistakes before you even go to the VM
(final verification is still MSVC/real hardware).

## 6. Toughpad hardware verification (final)

- Supported floor: Windows 7 SP1. Windows XP is not a target (.NET Framework 4.8, the
  installer's MinVersion 6.1sp1, and Vista+ APIs in the watchdog).
- Win7 machines: the .NET Framework 4.8 offline installer and KB3140245 (WinHTTP TLS 1.2) are
  prerequisites. Setup stops without .NET 4.8 and warns without KB3140245; until it is
  installed, HTTPS integrations fail and `logs\doorbell.log` says why. Switch to the v141
  build only if the v143 artifact does not run.
- AEC calibration, camera enumeration, and kiosk (shell replacement) can only receive final
  verification on real hardware.

## 7. Checks for the 2026-11 review fixes

None of these were run on Windows when the fixes were written; run them in the VM before
marking the Windows lane verified.

```bat
:: Contract tests and the watchdog policy (also run on any host with Python 3 and a C++17 compiler)
python win\tests\test_windows_contracts.py
cmake -S win\watchdog -B build-watchdog -A x64 -DBUILD_TESTING=ON
cmake --build build-watchdog --config Release -j
ctest --test-dir build-watchdog -C Release --output-on-failure

:: Full bundle; a release additionally needs DB_SIGN_CERT_SHA1 and DB_UPDATE_PUBLISHER (the CN)
set DB_ALLOW_SIP_STUB=1
win\build.cmd
```

Then, on the installed device (elevated prompt for the first three):

1. `icacls "%ProgramData%\Doorbell"` shows Users `(RX)` only, `...\service` has no Users write,
   `...\data` has Users `(M)`, and `...\data\secure` lists `Doorbell Operators`.
2. As a standard user, creating a file in `%ProgramData%\Doorbell\service` fails.
3. `sc qc DoorbellWatchdog` still starts the app; `watchdog.log` lives in `...\service`.
4. Kill `DoorbellApp.exe` three times within five minutes: safe mode starts. Use Leave Cluster
   (factory reset) three times: safe mode does not start.
5. Fast user switch to another account: the app moves to the new console session.
6. Freeze the UI thread (debugger break on the dispatcher): the watchdog restarts the app after
   about 20 seconds.
7. Start a second `DoorbellApp.exe`: it exits with code 5 and the first keeps running.
8. Unplug and re-plug the door-station camera: video returns without restarting the app.
9. Close an incoming-call screen repeatedly: `netstat -ano` shows no lingering loopback media
   connections.
10. In-app update with an unsigned or differently signed installer is refused with
    `web_admin.update_untrusted`.


## 8. Automated UI tests on a LAN Windows PC

The UI smoke suite runs on a real Windows PC on the LAN and is driven from the Mac over SSH.
The PC needs one manual step, once.

**One-time step on the PC.** Log on as the account that will show the app (it must be an
administrator), copy `win/scripts/setup_test_host.ps1` to the PC, and run it from an elevated
PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup_test_host.ps1
```

It installs the built-in OpenSSH Server, starts `sshd` automatically, adds one firewall rule
(TCP 22, Private profile, local subnet only), authorizes the test key in
`%ProgramData%\ssh\administrators_authorized_keys`, makes PowerShell the SSH default shell,
creates `C:\DoorbellTest`, and registers the on-demand scheduled task `DoorbellTest-RunJob`,
which runs a job in the logged-on desktop session (an SSH session cannot show a window). It
prints every change, is safe to run again, changes no password or other security setting, and
`-Uninstall` reverts exactly what it did. The matching private key on the Mac is
`~/.ssh/doorbell_win_test_ed25519`.

If `sshd` cannot start, the script says why it thinks so (another program on the port, missing
host keys, the output of `sshd.exe -t`, the last OpenSSH and Service Control Manager events),
still does the steps that do not need the service, and exits non-zero; run it again after fixing
the cause. When port 22 is taken, run it with `-Port <free port>` (it writes `Port` into
`%ProgramData%\ssh\sshd_config`, reverted by `-Uninstall`) and pass `--port <n>` to
`run_remote_tests.sh`.

**Every run, from the Mac.** Keep the test account logged on with the screen unlocked, then:

```sh
win/scripts/run_remote_tests.sh <host> [user]              # newest green CI build of this branch
win/scripts/run_remote_tests.sh <host> [user] --run <id>   # a specific Actions run
win/scripts/run_remote_tests.sh <host> [user] --zip <file> # a local bundle
```

The driver downloads the `doorbell-win-test-bundle` artifact of the `windows-contract` CI job
(an unsigned SIP-stub build), copies it to the PC, runs `win/scripts/ui_smoke.ps1` once as an
indoor panel and once as a door station, and copies back `result-<role>.json`, the app logs
and a screenshot of every screen in light and dark under
`build-redesign-win/remote-tests/<time>/`. It exits non-zero when any check fails.

The app under test never touches a household cluster or the PC's installed data. It starts in
UI test mode, which needs `--ui-test`, `--data-dir <throwaway directory>` and
`DOORBELL_UI_TEST=1` together and refuses the installed data directory; its `boot.json` is
unpaired, has no seed peers, uses ports 47972/47980 and disables HTTPS. Core has no switch
for the discovery beacon, so for the length of each run the driver adds two firewall rules
that block UDP 47171 for the test copy of `DoorbellApp.exe`
(`DoorbellTest block discovery (in)` and `(out)`) and removes them when the run ends, also
on failure.

The suite uses the UI Automation assemblies that ship with Windows; nothing is installed on
the PC. It finds elements by AutomationId (the XAML `x:Name`), so renaming a named control
means updating `ui_smoke.ps1`. Host-side tests for the pieces that need no Windows:
`win/scripts/test_ui_test_mode.sh` and `win/scripts/test_zoom_pan_math.sh`.
