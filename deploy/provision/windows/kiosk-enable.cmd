@echo off
rem ================================================================
rem  Replace the kiosk user's shell through HKCU (supports Pro and Windows 7).
rem  Run this while signed in as the dedicated standard kiosk user.
rem  This changes only that user's shell from Explorer to doorbell-watchdog.exe.
rem  Administrator accounts are not affected.
rem  Argument: full watchdog path (default: C:\Doorbell\doorbell-watchdog.exe).
rem  Recovery: kiosk-disable.cmd, Safe Mode, or registry removal from another account.
rem ================================================================
setlocal
set "WD=%~1"
if "%WD%"=="" set "WD=C:\Doorbell\doorbell-watchdog.exe"
if not exist "%WD%" echo %WD% was not found. & exit /b 1

reg add "HKCU\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /t REG_SZ /d "\"%WD%\"" /f

rem Reduce Ctrl+Alt+Delete options. Windows does not allow the secure attention sequence itself to be blocked.
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableTaskMgr /t REG_DWORD /d 1 /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableLockWorkstation /t REG_DWORD /d 1 /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableChangePassword /t REG_DWORD /d 1 /f
rem Hide the sign-out menu.
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoLogoff /t REG_DWORD /d 1 /f
rem Disable edge swipe notifications on Windows 8 and later; Windows 7 ignores this policy.
reg add "HKCU\Software\Policies\Microsoft\Windows\EdgeUI" /v AllowEdgeSwipe /t REG_DWORD /d 0 /f >nul 2>&1
rem Disable toast notifications and Action Center for the kiosk user.
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications" /v ToastEnabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\Software\Policies\Microsoft\Windows\Explorer" /v DisableNotificationCenter /t REG_DWORD /d 1 /f >nul 2>&1
rem Disable welcome screens and tips on Windows 10 and later.
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-310093Enabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SoftLandingEnabled /t REG_DWORD /d 0 /f >nul 2>&1

echo Complete. Sign out and sign in again to enter kiosk mode.
echo To configure automatic sign-in as an administrator, use netplwiz or autologon-enable.cmd.
endlocal
