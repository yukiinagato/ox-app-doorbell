@echo off
rem ================================================================
rem  kiosk シェル置換 (Pro/Win7 対応の HKCU 方式)
rem  ※ 専用の kiosk ユーザー (標準ユーザー) でログインした状態で実行すること。
rem     このユーザーのシェルが explorer → doorbell-watchdog.exe に変わる。
rem     管理者ユーザーには影響しない。
rem  引数: watchdog のフルパス (省略時 C:\Doorbell\doorbell-watchdog.exe)
rem  復旧: kiosk-disable.cmd / セーフモード / 別ユーザーからレジストリ削除
rem ================================================================
setlocal
set "WD=%~1"
if "%WD%"=="" set "WD=C:\Doorbell\doorbell-watchdog.exe"
if not exist "%WD%" echo %WD% がありません & exit /b 1

reg add "HKCU\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /t REG_SZ /d "\"%WD%\"" /f

rem Ctrl+Alt+Del 画面の項目を減らす (SAS 自体は塞げない — 設計どおりの現実的緩和)
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableTaskMgr /t REG_DWORD /d 1 /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableLockWorkstation /t REG_DWORD /d 1 /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableChangePassword /t REG_DWORD /d 1 /f
rem サインアウトメニュー非表示
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoLogoff /t REG_DWORD /d 1 /f
rem 通知/エッジスワイプ抑制 (Win8+; Win7 では無視される)
reg add "HKCU\Software\Policies\Microsoft\Windows\EdgeUI" /v AllowEdgeSwipe /t REG_DWORD /d 0 /f >nul 2>&1
rem トースト通知・通知センターを kiosk ユーザーで全停止 (更新促し等の弾窗源)
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications" /v ToastEnabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\Software\Policies\Microsoft\Windows\Explorer" /v DisableNotificationCenter /t REG_DWORD /d 1 /f >nul 2>&1
rem 「Windows へようこそ」/ヒント表示の抑制 (Win10+)
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-310093Enabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SoftLandingEnabled /t REG_DWORD /d 0 /f >nul 2>&1

echo 完了。サインアウト→再ログインで kiosk になります。
echo 自動ログオン設定は管理者で: netplwiz または autologon-enable.cmd を使用。
endlocal
