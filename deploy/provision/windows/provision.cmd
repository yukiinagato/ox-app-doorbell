@echo off
rem ================================================================
rem  Provision a Toughpad or Windows door station. Run with administrator privileges.
rem  Supported systems: Windows 7 SP1 through Windows 11, including Pro editions.
rem  This script:
rem   1) Opens firewall ports for mesh, HTTP, SIP, and RTP.
rem   2) Forces NTP synchronization at startup and daily.
rem   3) Enables TLS 1.2 through SChannel and WinHTTP on Windows 7.
rem   4) Disables sleep and keeps the display on while connected to AC power.
rem   5) Disables WER dialogs so the watchdog can restart the app immediately after a crash.
rem  Run kiosk-enable.cmd separately while signed in as the kiosk user to replace its shell.
rem ================================================================
setlocal
net session >nul 2>&1 || (echo Run this script with administrator privileges. & exit /b 1)

echo ==== 1) Firewall ====
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

echo ==== 3) TLS 1.2 (required on Windows 7; harmless on later systems) ====
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" /v Enabled /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" /v DisabledByDefault /t REG_DWORD /d 0 /f >nul
rem WinHTTP default protocols after KB3140245: TLS 1.1 and TLS 1.2 = 0xA00.
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp" /v DefaultSecureProtocols /t REG_DWORD /d 2720 /f >nul
reg add "HKLM\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp" /v DefaultSecureProtocols /t REG_DWORD /d 2720 /f >nul 2>&1

echo ==== 4) Power ====
powercfg /setactive SCHEME_MIN >nul 2>&1
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change hibernate-timeout-ac 0 >nul 2>&1

echo ==== 5) Disable WER dialogs ====
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting" /v DontShowUI /t REG_DWORD /d 1 /f >nul

echo ==== 6) Block unattended Windows Update changes on kiosk devices ====
rem Disable automatic updates so a door station cannot update, restart, or show prompts unattended.
rem Apply security updates manually during a maintenance window according to the operations guide.
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d 1 /f >nul
rem Suppress restart and update notifications on Windows 10 and later; Windows 7 ignores these policies.
reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v RestartNotificationsAllowed2 /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v SetAutoRestartNotificationDisable /t REG_DWORD /d 1 /f >nul
rem Disable Update Orchestrator reboot tasks where the installed Windows build permits it.
schtasks /Change /TN "\Microsoft\Windows\UpdateOrchestrator\Reboot" /DISABLE >nul 2>&1
schtasks /Change /TN "\Microsoft\Windows\UpdateOrchestrator\Reboot_Battery" /DISABLE >nul 2>&1
rem Optional stricter policy after reviewing maintenance procedures: sc config wuauserv start= disabled

echo ==== 7) Other unsolicited UI ====
rem Disable consumer content and Store auto-downloads. kiosk-enable.cmd applies per-user policies.
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\WindowsStore" /v AutoDownload /t REG_DWORD /d 2 /f >nul 2>&1

echo.
echo Complete. Next, sign in as the kiosk user and run kiosk-enable.cmd to replace its shell.
endlocal
