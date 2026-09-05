@echo off
rem Reproducible Windows release build: core x64+x86, ABI/PJSIP gates,
rem watchdog policy tests, WPF shell and atomic SHA256-labelled bundle.
setlocal EnableExtensions EnableDelayedExpansion
cd /d %~dp0..

if "%VSCMD_VER%"=="" (
  set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
  if not exist "!VSWHERE!" (
    echo ERROR: vswhere.exe not found. Install VS2022 C++ and .NET desktop workloads.
    exit /b 1
  )
  for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -property installationPath`) do set "VSPATH=%%i"
  call "!VSPATH!\Common7\Tools\VsDevCmd.bat" -arch=x64 || exit /b 1
)

if "%DB_BUILD_ID%"=="" (
  for /f "usebackq tokens=*" %%i in (`git rev-parse --verify HEAD`) do set "DB_GIT_SHA=%%i"
  if "!DB_GIT_SHA!"=="" (
    echo ERROR: set DB_BUILD_ID or build from a Git checkout.
    exit /b 1
  )
  git diff --quiet --ignore-submodules --
  if errorlevel 1 (
    echo ERROR: dirty tree requires an explicit DB_BUILD_ID.
    exit /b 1
  )
  git diff --cached --quiet --ignore-submodules --
  if errorlevel 1 (
    echo ERROR: staged changes require an explicit DB_BUILD_ID.
    exit /b 1
  )
  set "DB_BUILD_ID=git-!DB_GIT_SHA!"
)
powershell -NoProfile -Command "if ($env:DB_BUILD_ID -notmatch '^[A-Za-z0-9._-]+$') { exit 1 }"
if errorlevel 1 (
  echo ERROR: DB_BUILD_ID may contain only letters, digits, dot, underscore and hyphen.
  exit /b 1
)

if "%SOURCE_DATE_EPOCH%"=="" (
  for /f "usebackq tokens=*" %%i in (`git show -s --format^=%%ct HEAD`) do set "SOURCE_DATE_EPOCH=%%i"
)
if "%SOURCE_DATE_EPOCH%"=="" (
  echo ERROR: set SOURCE_DATE_EPOCH for a non-Git source tree.
  exit /b 1
)
set "ZERO_AR_DATE=1"

set "DB_REQUIRE_PJSIP=ON"
set "DB_WITH_PJSIP=ON"
set "DB_PROBE_ARG="
if "%DB_ALLOW_SIP_STUB%"=="1" (
  echo WARNING: building an explicitly marked development-only SIP stub artifact.
  set "DB_REQUIRE_PJSIP=OFF"
  set "DB_WITH_PJSIP=OFF"
  set "DB_PJSIP_ROOT_X64="
  set "DB_PJSIP_ROOT_X86="
  set "DB_PROBE_ARG=--allow-stub"
) else (
  if "%DB_SIGN_CERT_SHA1%"=="" (
    echo ERROR: release build requires DB_SIGN_CERT_SHA1 for Authenticode signing.
    exit /b 1
  )
  if "%DB_PJSIP_ROOT_X64%"=="" (
    echo ERROR: release build requires DB_PJSIP_ROOT_X64.
    exit /b 1
  )
  if "%DB_PJSIP_ROOT_X86%"=="" (
    echo ERROR: release build requires DB_PJSIP_ROOT_X86.
    exit /b 1
  )
  if not exist "%DB_PJSIP_ROOT_X64%\include\pjsua-lib\pjsua.h" (
    echo ERROR: invalid DB_PJSIP_ROOT_X64.
    exit /b 1
  )
  if not exist "%DB_PJSIP_ROOT_X86%\include\pjsua-lib\pjsua.h" (
    echo ERROR: invalid DB_PJSIP_ROOT_X86.
    exit /b 1
  )
)

echo ==== core DLL x64 (build !DB_BUILD_ID!) ====
cmake -S core -B build-msvc-x64 -A x64 -DDB_BUILD_TESTS=OFF -DDB_WITH_PJSIP=!DB_WITH_PJSIP! -DDB_REQUIRE_PJSIP=!DB_REQUIRE_PJSIP! -DDB_PJSIP_ROOT="%DB_PJSIP_ROOT_X64%" -DDB_BUILD_ID_ARG="!DB_BUILD_ID!" -DCMAKE_C_FLAGS="/Brepro" -DCMAKE_CXX_FLAGS="/Brepro" -DCMAKE_SHARED_LINKER_FLAGS="/Brepro" || exit /b 1
cmake --build build-msvc-x64 --config Release -j || exit /b 1

echo ==== core DLL x86 ====
cmake -S core -B build-msvc-x86 -A Win32 -DDB_BUILD_TESTS=OFF -DDB_WITH_PJSIP=!DB_WITH_PJSIP! -DDB_REQUIRE_PJSIP=!DB_REQUIRE_PJSIP! -DDB_PJSIP_ROOT="%DB_PJSIP_ROOT_X86%" -DDB_BUILD_ID_ARG="!DB_BUILD_ID!" -DCMAKE_C_FLAGS="/Brepro" -DCMAKE_CXX_FLAGS="/Brepro" -DCMAKE_SHARED_LINKER_FLAGS="/Brepro" || exit /b 1
cmake --build build-msvc-x86 --config Release -j || exit /b 1

echo ==== x64/x86 platform-v2 and SIP backend gates ====
cmake -S win\abi-probe -B build-win-abi-x64 -A x64 -DDB_CORE_BUILD_DIR="%CD%\build-msvc-x64" || exit /b 1
cmake --build build-win-abi-x64 --config Release -j || exit /b 1
build-win-abi-x64\Release\doorbell-abi-probe.exe !DB_PROBE_ARG! || exit /b 1
cmake -S win\abi-probe -B build-win-abi-x86 -A Win32 -DDB_CORE_BUILD_DIR="%CD%\build-msvc-x86" || exit /b 1
cmake --build build-win-abi-x86 --config Release -j || exit /b 1
build-win-abi-x86\Release\doorbell-abi-probe.exe !DB_PROBE_ARG! || exit /b 1

echo ==== atomically stage native DLLs for WPF ====
if not exist win\DoorbellApp\lib\win-x64 mkdir win\DoorbellApp\lib\win-x64
if not exist win\DoorbellApp\lib\win-x86 mkdir win\DoorbellApp\lib\win-x86
copy /b /y build-msvc-x64\Release\doorbell.dll win\DoorbellApp\lib\win-x64\doorbell.dll.new >nul || exit /b 1
move /y win\DoorbellApp\lib\win-x64\doorbell.dll.new win\DoorbellApp\lib\win-x64\doorbell.dll >nul || exit /b 1
copy /b /y build-msvc-x86\Release\doorbell.dll win\DoorbellApp\lib\win-x86\doorbell.dll.new >nul || exit /b 1
move /y win\DoorbellApp\lib\win-x86\doorbell.dll.new win\DoorbellApp\lib\win-x86\doorbell.dll >nul || exit /b 1

echo ==== watchdog and deterministic recovery-policy test ====
cmake -S win\watchdog -B build-watchdog -A x64 -DBUILD_TESTING=ON || exit /b 1
cmake --build build-watchdog --config Release -j || exit /b 1
ctest --test-dir build-watchdog -C Release --output-on-failure || exit /b 1

echo ==== WPF shell ====
msbuild win\DoorbellApp.sln /restore /p:Configuration=Release /p:Deterministic=true /p:ContinuousIntegrationBuild=true /p:SourceRevisionId="!DB_BUILD_ID!" /m || exit /b 1

echo ==== atomic release bundle and SHA256 manifest ====
set "DB_DIST_PARENT=win\dist"
set "DB_DIST=!DB_DIST_PARENT!\!DB_BUILD_ID!"
set "DB_STAGE=!DB_DIST_PARENT!\.!DB_BUILD_ID!.!RANDOM!.tmp"
if exist "!DB_DIST!" (
  echo ERROR: refusing to overwrite existing artifact !DB_DIST!.
  exit /b 1
)
if not exist "!DB_DIST_PARENT!" mkdir "!DB_DIST_PARENT!" || exit /b 1
mkdir "!DB_STAGE!\app" || exit /b 1
mkdir "!DB_STAGE!\checks" || exit /b 1
xcopy win\DoorbellApp\bin\Release\net48\* "!DB_STAGE!\app\" /E /I /Q /Y >nul || exit /b 1
copy /b build-watchdog\Release\doorbell-watchdog.exe "!DB_STAGE!\" >nul || exit /b 1
copy /b build-win-abi-x64\Release\doorbell-abi-probe.exe "!DB_STAGE!\checks\doorbell-abi-probe-x64.exe" >nul || exit /b 1
copy /b build-win-abi-x86\Release\doorbell-abi-probe.exe "!DB_STAGE!\checks\doorbell-abi-probe-x86.exe" >nul || exit /b 1
set "DB_SIGNING_MODE=unsigned-development-stub"
if not "%DB_ALLOW_SIP_STUB%"=="1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File win\tools\sign-bundle.ps1 -ArtifactRoot "!DB_STAGE!" -CertificateThumbprint "%DB_SIGN_CERT_SHA1%" || exit /b 1
  set "DB_SIGNING_MODE=authenticode-sha256"
)
powershell -NoProfile -ExecutionPolicy Bypass -File win\tools\write-manifest.ps1 -ArtifactRoot "!DB_STAGE!" -BuildId "!DB_BUILD_ID!" -SourceDateEpoch "!SOURCE_DATE_EPOCH!" -SigningMode "!DB_SIGNING_MODE!" || exit /b 1
move "!DB_STAGE!" "!DB_DIST!" >nul || exit /b 1

echo ==== installer (Inno Setup) ====
rem The installer wraps the finished bundle: role/name/door first-run page, watchdog service,
rem firewall rules, optional kiosk provisioning, in-place upgrades. It is optional locally
rem (no Inno Setup -> skipped) and required on the release runners, which ship ISCC.
set "DB_ISCC="
if exist "%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" set "DB_ISCC=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
if exist "%ProgramFiles%\Inno Setup 6\ISCC.exe" set "DB_ISCC=%ProgramFiles%\Inno Setup 6\ISCC.exe"
if "!DB_ISCC!"=="" (
  if "%DB_REQUIRE_INSTALLER%"=="1" (
    echo ERROR: Inno Setup 6 was not found and DB_REQUIRE_INSTALLER=1.
    exit /b 1
  )
  echo Inno Setup 6 not found; skipping the installer.
) else (
  set "DB_APP_VERSION=0.2.0"
  for /f "tokens=3 delims=<>" %%V in ('findstr /c:"<Version>" win\DoorbellApp\DoorbellApp.csproj') do set "DB_APP_VERSION=%%V"
  "!DB_ISCC!" /Q "/DSourceDir=%CD%\!DB_DIST!" "/DBuildId=!DB_BUILD_ID!" "/DAppVersion=!DB_APP_VERSION!" "/DProvisionDir=%CD%\deploy\provision\windows" win\installer\DoorbellSetup.iss || exit /b 1
  if not "%DB_ALLOW_SIP_STUB%"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File win\tools\sign-bundle.ps1 -ArtifactRoot "!DB_DIST!\installer" -CertificateThumbprint "%DB_SIGN_CERT_SHA1%" || exit /b 1
  )
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '!DB_DIST!\installer' -Filter DoorbellSetup-*.exe | ForEach-Object { (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant() + ' *' + $_.Name | Set-Content -Encoding ascii ($_.FullName + '.sha256') }" || exit /b 1
  echo installer: !DB_DIST!\installer
)

echo.
echo ==== complete ====
echo artifact: !DB_DIST!
echo manifest: !DB_DIST!\SHA256SUMS
echo service install (elevated): !DB_DIST!\doorbell-watchdog.exe --install !DB_DIST!\app\DoorbellApp.exe
endlocal
