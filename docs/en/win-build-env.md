> Japanese original: ../ja/win-build-env.md (canonical)

# Windows Build Environment (Apple Silicon Mac + local VM)

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
- ARM64 Windows can run x86/x64 apps under emulation — building and testing the x86/x64
  artifacts for the Toughpad is possible inside the VM.

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

If errors appear, paste them straight back to Claude on the Mac side.

## 5. Pre-verification on the Mac (mingw-w64)

On the Mac, after `brew install mingw-w64`:

```bash
cmake -S core -B build-win64 -DCMAKE_TOOLCHAIN_FILE=core/cmake/mingw-w64.cmake && cmake --build build-win64 -j8
```

This catches most Winsock/API porting mistakes before you even go to the VM
(final verification is still MSVC/real hardware).

## 6. Toughpad hardware verification (final)

- Win7 machines: the .NET Framework 4.8 offline installer + the TLS 1.2 enablement patch are
  prerequisites (the provisioning script configures them). Switch to the v141 build only if the
  v143 artifact does not run.
- AEC calibration, camera enumeration, and kiosk (shell replacement) can only receive final
  verification on real hardware.
