@echo off
rem kiosk 解除 (kiosk ユーザーで実行、または別ユーザーから HKU\<SID> を編集)
reg delete "HKCU\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /f 2>nul
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableTaskMgr /f 2>nul
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableLockWorkstation /f 2>nul
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableChangePassword /f 2>nul
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoLogoff /f 2>nul
echo 解除しました。再ログインで explorer に戻ります。
