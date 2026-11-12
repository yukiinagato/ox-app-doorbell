#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-time preparation of a LAN Windows PC as a Doorbell UI test host.

.DESCRIPTION
  Run once, by hand, from an elevated PowerShell on the test PC. Afterwards
  win/scripts/run_remote_tests.sh drives everything from the Mac over SSH.

  What it changes, and nothing else:
    1. Installs the built-in OpenSSH Server capability if it is missing.
    2. Sets the sshd service to start automatically and starts it.
    3. Adds one inbound firewall rule for TCP 22, Private profile, local subnet only.
    4. Adds one public key to %ProgramData%\ssh\administrators_authorized_keys and gives that
       file the access list sshd requires (Administrators and SYSTEM only).
    5. Makes Windows PowerShell the default shell for SSH sessions.
    6. Creates the working directory (default C:\DoorbellTest), readable and writable only by
       Administrators, SYSTEM and the interactive test user.
    7. Registers an on-demand scheduled task that runs a job script from the working directory
       in the logged-on user's desktop session. SSH sessions run in session 0 and cannot show
       a window, so GUI tests are started through this task.

  It changes no password, no account, no execution policy and no other security setting.
  Every change is recorded in <WorkDir>\setup-state.json so -Uninstall reverts exactly what
  this script did and leaves alone what was already there.

  Note for the owner: each test run also adds two temporary firewall rules that block UDP
  47171 (cluster discovery) for the test copy of DoorbellApp.exe, so the test instance never
  appears on the household's Add-device list. The Mac driver creates them at the start of a
  run and removes them at the end, also when the run fails. They are named
  "DoorbellTest block discovery (in)" and "DoorbellTest block discovery (out)".

.PARAMETER PublicKey
  The SSH public key the Mac driver uses.

.PARAMETER WorkDir
  Working directory for test runs.

.PARAMETER InteractiveUser
  The account whose desktop session shows the app under test. Defaults to the user logged on
  at the console. It must be a member of Administrators for the key above to apply to it.

.PARAMETER Uninstall
  Reverts everything recorded in setup-state.json.
#>
[CmdletBinding()]
param(
    [string]$PublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIFMXGYzf6RfmbjrjRYNtC1NKxfYM02tlsYeEISOoHph doorbell-win-test',
    [string]$WorkDir = 'C:\DoorbellTest',
    [string]$InteractiveUser = '',
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName = 'DoorbellTest-RunJob'
$FirewallRule = 'DoorbellTest SSH (LAN)'
$TemporaryRules = @('DoorbellTest block discovery (in)', 'DoorbellTest block discovery (out)')
$KeysFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
$ShellKey = 'HKLM:\SOFTWARE\OpenSSH'
$StateFile = Join-Path $WorkDir 'setup-state.json'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:Changes = New-Object System.Collections.Generic.List[string]

function Note([string]$text) { Write-Host ('  = ' + $text) }
function Changed([string]$text) { $script:Changes.Add($text); Write-Host ('  + ' + $text) -ForegroundColor Green }

function Read-State {
    if (Test-Path -LiteralPath $StateFile) {
        return (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json)
    }
    return $null
}

function Get-StateValue($state, [string]$name, $default) {
    if ($null -ne $state -and ($state.PSObject.Properties.Name -contains $name)) { return $state.$name }
    return $default
}

function Save-State([hashtable]$state) {
    $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Set-KeysFileAcl {
    # sshd ignores the file unless only Administrators and SYSTEM can reach it. SIDs are used
    # so this works on every display language.
    & icacls.exe $KeysFile /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $KeysFile" }
}

function Get-KeyLines {
    if (Test-Path -LiteralPath $KeysFile) { return @(Get-Content -LiteralPath $KeysFile) }
    return @()
}

function Get-KeyBody([string]$line) {
    $parts = @($line.Trim() -split '\s+')
    if ($parts.Count -ge 2) { return $parts[0] + ' ' + $parts[1] }
    return $line.Trim()
}

function Install-TestHost {
    $previous = Read-State
    $state = @{
        schema               = 1
        work_dir             = $WorkDir
        capability_installed = [bool](Get-StateValue $previous 'capability_installed' $false)
        sshd_previous_start  = [string](Get-StateValue $previous 'sshd_previous_start' '')
        sshd_was_running     = [bool](Get-StateValue $previous 'sshd_was_running' $false)
        sshd_recorded        = [bool](Get-StateValue $previous 'sshd_recorded' $false)
        firewall_rule_added  = [bool](Get-StateValue $previous 'firewall_rule_added' $false)
        keys_file_created    = [bool](Get-StateValue $previous 'keys_file_created' $false)
        key_added            = [string](Get-StateValue $previous 'key_added' '')
        shell_recorded       = [bool](Get-StateValue $previous 'shell_recorded' $false)
        shell_previous       = [string](Get-StateValue $previous 'shell_previous' '')
        shell_key_created    = [bool](Get-StateValue $previous 'shell_key_created' $false)
        work_dir_created     = [bool](Get-StateValue $previous 'work_dir_created' $false)
        task_registered      = [bool](Get-StateValue $previous 'task_registered' $false)
        interactive_user     = [string](Get-StateValue $previous 'interactive_user' '')
    }

    Write-Host 'Doorbell test host setup'

    # ---- working directory first: the state file lives there -------------------------------
    if ([string]::IsNullOrWhiteSpace($InteractiveUser)) {
        $InteractiveUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
    }
    if ([string]::IsNullOrWhiteSpace($InteractiveUser)) {
        throw 'Nobody is logged on at the console. Log on as the test user or pass -InteractiveUser.'
    }
    $state.interactive_user = $InteractiveUser
    if (-not (Test-Path -LiteralPath $WorkDir)) {
        New-Item -ItemType Directory -Path $WorkDir | Out-Null
        $state.work_dir_created = $true
        Changed "Created $WorkDir"
    } else { Note "$WorkDir already exists" }
    foreach ($sub in @('runs', 'jobs')) {
        $path = Join-Path $WorkDir $sub
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
    }
    # Whoever can write here can run code in the test user's session, so only that user,
    # Administrators and SYSTEM may.
    & icacls.exe $WorkDir /inheritance:r /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-18:(OI)(CI)F' /grant "${InteractiveUser}:(OI)(CI)M" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $WorkDir" }
    Note "Access to $WorkDir limited to Administrators, SYSTEM and $InteractiveUser"
    Save-State $state

    # ---- 1. OpenSSH Server ----------------------------------------------------------------
    $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($null -eq $capability) { throw 'This Windows edition does not offer the OpenSSH.Server capability.' }
    if ($capability.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name $capability.Name | Out-Null
        $state.capability_installed = $true
        Changed "Installed Windows capability $($capability.Name)"
    } else { Note 'OpenSSH Server is already installed' }
    Save-State $state

    # ---- 2. sshd service ------------------------------------------------------------------
    $service = Get-Service -Name sshd
    if (-not $state.sshd_recorded) {
        $state.sshd_previous_start = [string]$service.StartType
        $state.sshd_was_running = ($service.Status -eq 'Running')
        $state.sshd_recorded = $true
    }
    if ($service.StartType -ne 'Automatic') {
        Set-Service -Name sshd -StartupType Automatic
        Changed "sshd start type: $($service.StartType) -> Automatic"
    } else { Note 'sshd already starts automatically' }
    if ((Get-Service -Name sshd).Status -ne 'Running') {
        Start-Service -Name sshd
        Changed 'Started the sshd service'
    } else { Note 'sshd is already running' }
    Save-State $state

    # ---- 3. firewall ----------------------------------------------------------------------
    if ($null -eq (Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $FirewallRule -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort 22 -Profile Private -RemoteAddress LocalSubnet `
            -Description 'Doorbell UI tests: SSH from the local subnet. Added by setup_test_host.ps1.' | Out-Null
        $state.firewall_rule_added = $true
        Changed "Added firewall rule '$FirewallRule' (TCP 22 in, Private profile, local subnet)"
    } else { Note "Firewall rule '$FirewallRule' already exists" }
    $builtIn = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if ($null -ne $builtIn) {
        Note "Windows' own rule 'OpenSSH-Server-In-TCP' exists (enabled: $($builtIn.Enabled), profile: $($builtIn.Profile)); left as it is"
    }
    $public = @(Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' })
    if ($public.Count -gt 0) {
        Write-Warning ("The network '" + $public[0].Name + "' is set to Public, where the rule above does not apply. " +
                       'Set it to Private in Windows Settings if the Mac cannot connect; this script does not change it.')
    }
    Save-State $state

    # ---- 4. public key --------------------------------------------------------------------
    $sshDir = Split-Path -Parent $KeysFile
    if (-not (Test-Path -LiteralPath $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
    $wanted = Get-KeyBody $PublicKey
    $present = @(Get-KeyLines | Where-Object { (Get-KeyBody $_) -eq $wanted })
    if ($present.Count -eq 0) {
        if (-not (Test-Path -LiteralPath $KeysFile)) { $state.keys_file_created = $true }
        Add-Content -LiteralPath $KeysFile -Value $PublicKey.Trim() -Encoding ascii
        $state.key_added = $wanted
        Changed "Added the test key to $KeysFile"
    } else { Note 'The test key is already authorized' }
    Set-KeysFileAcl
    Note "$KeysFile is readable by Administrators and SYSTEM only (required by sshd)"
    Save-State $state

    # ---- 5. default shell -----------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $ShellKey)) {
        New-Item -Path $ShellKey -Force | Out-Null
        $state.shell_key_created = $true
    }
    $current = (Get-ItemProperty -Path $ShellKey -Name DefaultShell -ErrorAction SilentlyContinue)
    $currentShell = if ($null -ne $current) { [string]$current.DefaultShell } else { '' }
    if (-not $state.shell_recorded) {
        $state.shell_previous = $currentShell
        $state.shell_recorded = $true
    }
    if ($currentShell -ne $PowerShellExe) {
        New-ItemProperty -Path $ShellKey -Name DefaultShell -Value $PowerShellExe -PropertyType String -Force | Out-Null
        Changed "SSH default shell: '$currentShell' -> $PowerShellExe"
    } else { Note 'PowerShell is already the SSH default shell' }
    Save-State $state

    # ---- 7. interactive job task ----------------------------------------------------------
    $runner = Join-Path $WorkDir 'run-job.ps1'
    $runnerBody = @'
# Runs in the test user's desktop session, started by the DoorbellTest-RunJob scheduled task.
# It executes the one job script the Mac driver placed here and records how it ended.
$ErrorActionPreference = 'Continue'
$work = Split-Path -Parent $MyInvocation.MyCommand.Path
$job = Join-Path $work 'jobs\job.ps1'
$log = Join-Path $work 'jobs\job.log'
$exit = Join-Path $work 'jobs\job.exit'
Remove-Item -LiteralPath $exit -ErrorAction SilentlyContinue
$code = 1
try {
    if (Test-Path -LiteralPath $job) {
        & $job *> $log
        $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    } else {
        'no job script' | Set-Content -LiteralPath $log
    }
} catch {
    $_ | Out-String | Add-Content -LiteralPath $log
    $code = 1
}
Set-Content -LiteralPath $exit -Value $code -Encoding ascii
'@
    Set-Content -LiteralPath $runner -Value $runnerBody -Encoding UTF8
    $action = New-ScheduledTaskAction -Execute $PowerShellExe `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $runner + '"')
    $principal = New-ScheduledTaskPrincipal -UserId $InteractiveUser -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings `
        -Description 'Doorbell UI tests: runs C:\DoorbellTest\jobs\job.ps1 in the desktop session on demand.' -Force | Out-Null
    $state.task_registered = $true
    if ($null -eq $existing) { Changed "Registered scheduled task '$TaskName' (on demand, as $InteractiveUser, not elevated)" }
    else { Note "Scheduled task '$TaskName' refreshed" }
    Save-State $state

    Write-Host ''
    if ($script:Changes.Count -eq 0) { Write-Host 'Nothing needed changing.' }
    else { Write-Host ("Changed {0} thing(s), listed above with '+'." -f $script:Changes.Count) }
    Write-Host ''
    Write-Host 'During each test run the Mac driver adds, and afterwards removes, two firewall rules that'
    Write-Host 'block UDP 47171 for the test copy of DoorbellApp.exe:'
    foreach ($rule in $TemporaryRules) { Write-Host "    $rule" }
    Write-Host ''
    Write-Host 'From the Mac:'
    $address = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1 -ExpandProperty IPAddress)
    $hostText = if ($address.Count -gt 0) { $address[0] } else { '<this PC>' }
    $userText = ($InteractiveUser -split '\\')[-1]
    Write-Host "    win/scripts/run_remote_tests.sh $hostText $userText"
    Write-Host 'Keep this user logged on with the screen unlocked while tests run.'
    Write-Host "To undo everything: .\setup_test_host.ps1 -Uninstall"
}

function Uninstall-TestHost {
    Write-Host 'Doorbell test host removal'
    $state = Read-State
    if ($null -eq $state) {
        Write-Host "  No ${StateFile}: this script made no recorded change here. Nothing removed."
        return
    }

    foreach ($rule in $TemporaryRules) {
        if ($null -ne (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
            Remove-NetFirewallRule -DisplayName $rule
            Changed "Removed leftover temporary firewall rule '$rule'"
        }
    }
    if ((Get-StateValue $state 'task_registered' $false) -and
        $null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Changed "Removed scheduled task '$TaskName'"
    }
    if ((Get-StateValue $state 'shell_recorded' $false) -and (Test-Path -LiteralPath $ShellKey)) {
        $before = [string](Get-StateValue $state 'shell_previous' '')
        if ($before -eq '') {
            Remove-ItemProperty -Path $ShellKey -Name DefaultShell -ErrorAction SilentlyContinue
            Changed 'Removed the SSH default shell setting (there was none before)'
        } else {
            New-ItemProperty -Path $ShellKey -Name DefaultShell -Value $before -PropertyType String -Force | Out-Null
            Changed "SSH default shell restored to $before"
        }
        if (Get-StateValue $state 'shell_key_created' $false) {
            # Only when it is empty again: -Recurse is deliberately not used.
            try { Remove-Item -LiteralPath $ShellKey -ErrorAction Stop } catch { }
        }
    }
    $added = [string](Get-StateValue $state 'key_added' '')
    if ($added -ne '' -and (Test-Path -LiteralPath $KeysFile)) {
        $kept = @(Get-KeyLines | Where-Object { (Get-KeyBody $_) -ne $added })
        if ((Get-StateValue $state 'keys_file_created' $false) -and $kept.Count -eq 0) {
            Remove-Item -LiteralPath $KeysFile
            Changed "Removed $KeysFile (this script created it and no other key is in it)"
        } else {
            Set-Content -LiteralPath $KeysFile -Value $kept -Encoding ascii
            Set-KeysFileAcl
            Changed "Removed the test key from $KeysFile"
        }
    }
    if ((Get-StateValue $state 'firewall_rule_added' $false) -and
        $null -ne (Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue)) {
        Remove-NetFirewallRule -DisplayName $FirewallRule
        Changed "Removed firewall rule '$FirewallRule'"
    }
    if (Get-StateValue $state 'sshd_recorded' $false) {
        $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
        if ($null -ne $service) {
            if (-not (Get-StateValue $state 'sshd_was_running' $false) -and $service.Status -eq 'Running') {
                Write-Host '  (stopping sshd ends any SSH session that is running this script)'
                Stop-Service -Name sshd -Force
                Changed 'Stopped the sshd service (it was not running before)'
            }
            $before = [string](Get-StateValue $state 'sshd_previous_start' '')
            if ($before -ne '' -and $before -ne [string]$service.StartType) {
                Set-Service -Name sshd -StartupType $before
                Changed "sshd start type restored to $before"
            }
        }
    }
    if (Get-StateValue $state 'capability_installed' $false) {
        $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
        if ($null -ne $capability -and $capability.State -eq 'Installed') {
            Remove-WindowsCapability -Online -Name $capability.Name | Out-Null
            Changed "Removed Windows capability $($capability.Name) (this script installed it)"
        }
    }
    $dir = [string](Get-StateValue $state 'work_dir' $WorkDir)
    if (Test-Path -LiteralPath $dir) {
        if (Get-StateValue $state 'work_dir_created' $false) {
            Remove-Item -LiteralPath $dir -Recurse -Force
            Changed "Removed $dir and the test runs in it"
        } else {
            foreach ($name in @('setup-state.json', 'run-job.ps1')) {
                Remove-Item -LiteralPath (Join-Path $dir $name) -ErrorAction SilentlyContinue
            }
            Note "$dir existed before setup; only this script's files were removed from it"
        }
    }
    Write-Host ''
    Write-Host ("Reverted {0} thing(s)." -f $script:Changes.Count)
}

if ($Uninstall) { Uninstall-TestHost } else { Install-TestHost }
