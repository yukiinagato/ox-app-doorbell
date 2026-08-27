@echo off
rem ================================================================
rem  Toughpad / Windows 門口機 装機スクリプト (管理者権限で実行)
rem  対象: Win7 SP1 〜 Win11 (Pro 含む)
rem  やること:
rem   1) ファイアウォール開放 (mesh/httpd/SIP/RTP)
rem   2) NTP 強制同期 (時計狂い対策 — 起動時 + 毎日)
rem   3) Win7: TLS1.2 有効化 (SChannel + WinHTTP)
rem   4) 電源: スリープ無効・画面常時点灯
rem   5) WER ダイアログ無効 (クラッシュ時に watchdog が即再起動できるように)
rem  kiosk シェル置換は別スクリプト kiosk-enable.cmd (kiosk ユーザーでログインして実行)
rem ================================================================
setlocal
net session >nul 2>&1 || (echo 管理者権限で実行してください & exit /b 1)

echo ==== 1) ファイアウォール ====
netsh advfirewall firewall delete rule name="Doorbell mesh" >nul 2>&1
netsh advfirewall firewall add rule name="Doorbell mesh" dir=in action=allow protocol=TCP localport=47172
netsh advfirewall firewall add rule name="Doorbell mesh" dir=in action=allow protocol=UDP localport=47171-47172
netsh advfirewall firewall delete rule name="Doorbell httpd" >nul 2>&1
netsh advfirewall firewall add rule name="Doorbell httpd" dir=in action=allow protocol=TCP localport=47180
netsh advfirewall firewall delete rule name="Doorbell RTP" >nul 2>&1
netsh advfirewall firewall add rule name="Doorbell RTP" dir=in action=allow protocol=UDP localport=4000-4099
netsh advfirewall firewall delete rule name="Doorbell mDNS" >nul 2>&1
netsh advfirewall firewall add rule name="Doorbell mDNS" dir=in action=allow protocol=UDP localport=5353

echo ==== 2) NTP ====
sc config w32time start= auto >nul
net start w32time >nul 2>&1
w32tm /config /manualpeerlist:"ntp.nict.jp,0x9 time.windows.com,0x9" /syncfromflags:manual /update
w32tm /resync /nowait
schtasks /create /f /tn "Doorbell\NtpResync" /sc onstart /delay 0001:00 /ru SYSTEM ^
  /tr "w32tm /resync /nowait" >nul

echo ==== 3) TLS1.2 (Win7 では必須, 他 OS では無害) ====
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" /v Enabled /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" /v DisabledByDefault /t REG_DWORD /d 0 /f >nul
rem WinHTTP 既定プロトコル (KB3140245 適用後に有効): TLS1.1+1.2 = 0xA00
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp" /v DefaultSecureProtocols /t REG_DWORD /d 2720 /f >nul
reg add "HKLM\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp" /v DefaultSecureProtocols /t REG_DWORD /d 2720 /f >nul 2>&1

echo ==== 4) 電源 ====
powercfg /setactive SCHEME_MIN >nul 2>&1
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change hibernate-timeout-ac 0 >nul 2>&1

echo ==== 5) WER 無効 ====
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting" /v DontShowUI /t REG_DWORD /d 1 /f >nul

echo.
echo 完了。次: kiosk ユーザーでログインし kiosk-enable.cmd を実行 (シェル置換)。
endlocal
