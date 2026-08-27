@echo off
rem ================================================================
rem  doorbell Windows 一括ビルド (VM 内で実行)
rem    core DLL (MSVC x64+x86) + watchdog + WPF アプリ
rem  前提: VS2022 (「.NET デスクトップ開発」+「C++ によるデスクトップ開発」)
rem  普通のコマンドプロンプトから実行可 (VsDevCmd を自動で読み込む)
rem ================================================================
setlocal enabledelayedexpansion
cd /d %~dp0..

if "%VSCMD_VER%"=="" (
  set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
  if not exist "!VSWHERE!" echo vswhere.exe が見つかりません (VS2022 未導入?) & exit /b 1
  for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -property installationPath`) do set "VSPATH=%%i"
  call "!VSPATH!\Common7\Tools\VsDevCmd.bat" -arch=x64 || exit /b 1
)

echo ==== core DLL (x64) ====
cmake -S core -B build-msvc-x64 -A x64 -DDB_BUILD_TESTS=OFF || exit /b 1
cmake --build build-msvc-x64 --config Release -j || exit /b 1

echo ==== core DLL (x86 - 旧 Toughpad 用) ====
cmake -S core -B build-msvc-x86 -A Win32 -DDB_BUILD_TESTS=OFF || exit /b 1
cmake --build build-msvc-x86 --config Release -j || exit /b 1

echo ==== DLL 配置 ====
if not exist win\DoorbellApp\lib\win-x64 mkdir win\DoorbellApp\lib\win-x64
if not exist win\DoorbellApp\lib\win-x86 mkdir win\DoorbellApp\lib\win-x86
copy /y build-msvc-x64\Release\doorbell.dll win\DoorbellApp\lib\win-x64\ || exit /b 1
copy /y build-msvc-x86\Release\doorbell.dll win\DoorbellApp\lib\win-x86\ || exit /b 1

echo ==== watchdog ====
cmake -S win\watchdog -B build-watchdog -A x64 || exit /b 1
cmake --build build-watchdog --config Release -j || exit /b 1

echo ==== WPF アプリ ====
msbuild win\DoorbellApp.sln /restore /p:Configuration=Release /m || exit /b 1

echo.
echo ==== 完了 ====
echo   アプリ:     win\DoorbellApp\bin\Release\net48\DoorbellApp.exe
echo   watchdog:  build-watchdog\Release\doorbell-watchdog.exe
echo   起動設定:  %%ProgramData%%\Doorbell\boot.json (初回起動で生成される)
endlocal
