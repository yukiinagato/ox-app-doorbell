@echo off
rem Disable kiosk mode as the kiosk user, or edit HKU\<SID> from another account.
reg delete "HKCU\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /f 2>nul
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableTaskMgr /f 2>nul
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableLockWorkstation /f 2>nul
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableChangePassword /f 2>nul
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoLogoff /f 2>nul
echo Kiosk mode is disabled. Sign in again to restore Explorer.
