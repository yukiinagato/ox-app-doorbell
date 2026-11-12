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

.PARAMETER Port
  TCP port sshd listens on. Leave it at 22 unless another program already uses 22 on this PC.
  Any other value is written as "Port" into %ProgramData%\ssh\sshd_config (recorded, and
  reverted by -Uninstall) and must be passed to run_remote_tests.sh with --port.

.PARAMETER Uninstall
  Reverts everything recorded in setup-state.json.
#>
[CmdletBinding()]
param(
    [string]$PublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIFMXGYzf6RfmbjrjRYNtC1NKxfYM02tlsYeEISOoHph doorbell-win-test',
    [string]$WorkDir = 'C:\DoorbellTest',
    [string]$InteractiveUser = '',
    [ValidateRange(1, 65535)][int]$Port = 22,
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
$SshDataDir = Join-Path $env:ProgramData 'ssh'
$SshdConfig = Join-Path $SshDataDir 'sshd_config'
$OpenSshDir = Join-Path $env:SystemRoot 'System32\OpenSSH'
$script:Changes = New-Object System.Collections.Generic.List[string]
$script:Problems = New-Object System.Collections.Generic.List[string]

function Note([string]$text) { Write-Host ('  = ' + $text) }
function Changed([string]$text) { $script:Changes.Add($text); Write-Host ('  + ' + $text) -ForegroundColor Green }

function Problem([string]$text) { $script:Problems.Add($text); Write-Host ('  ! ' + $text) -ForegroundColor Red }

# Runs a console program and prints what it says, indented; returns its exit code.
function Invoke-Tool([string]$exe, [string[]]$arguments) {
    if (-not (Test-Path -LiteralPath $exe)) { Write-Host "      (not found: $exe)"; return -1 }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $exe @arguments 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    foreach ($line in @($output)) { Write-Host ('      ' + [string]$line) }
    return $code
}

# Processes other than sshd that already listen on the port.
function Get-ForeignListeners([int]$port) {
    $found = @()
    $listeners = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    foreach ($listener in $listeners) {
        $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        $name = '(unknown)'
        if ($null -ne $process) { $name = $process.ProcessName }
        if ($name -ne 'sshd') { $found += ("{0} (pid {1}, address {2})" -f $name, $listener.OwningProcess, $listener.LocalAddress) }
    }
    return @($found | Select-Object -Unique)
}

function Show-SshdDiagnostics {
    Write-Host '    Last OpenSSH/Operational events:'
    $events = @(Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 10 -ErrorAction SilentlyContinue)
    if ($events.Count -eq 0) { Write-Host '      (none)' }
    foreach ($event in $events) {
        Write-Host ("      {0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f $event.TimeCreated, $event.LevelDisplayName, (([string]$event.Message) -replace '\s+', ' '))
    }
    Write-Host '    Last Service Control Manager events about sshd:'
    $scm = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager' } -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { ([string]$_.Message) -match 'sshd|OpenSSH' } | Select-Object -First 5)
    if ($scm.Count -eq 0) { Write-Host '      (none)' }
    foreach ($event in $scm) {
        Write-Host ("      {0:yyyy-MM-dd HH:mm:ss} id {1}: {2}" -f $event.TimeCreated, $event.Id, (([string]$event.Message) -replace '\s+', ' '))
    }
}

# Windows finishes installing a capability such as OpenSSH Server only after a restart when
# this key exists; until then the sshd service times out on start.
function Test-RebootPending {
    return (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
}

function Read-ConfigLines([string]$path) {
    return @([System.IO.File]::ReadAllLines($path))
}

function Write-ConfigLines([string]$path, [string[]]$lines) {
    # No byte-order mark: sshd refuses a config file that starts with one.
    [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

# The uncommented "Port" value in sshd_config, or '' when the file sets none.
function Get-ConfiguredPort([string[]]$lines) {
    foreach ($line in $lines) {
        if ($line -match '^\s*Port\s+(\d+)\s*$') { return $Matches[1] }
    }
    return ''
}

function Set-ConfiguredPort([string]$path, [string]$value) {
    $lines = @(Read-ConfigLines $path)
    $kept = @($lines | Where-Object { $_ -notmatch '^\s*Port\s+\d+\s*$' })
    if ($value -ne '') { $kept = @("Port $value") + $kept }
    Write-ConfigLines $path $kept
}

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

# The profile folder of an account given as DOMAIN\name or name, or $null.
function Get-UserProfilePath([string]$account) {
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($account)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
        $userProfile = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$sid'" -ErrorAction Stop
        if ($null -ne $userProfile -and (Test-Path -LiteralPath $userProfile.LocalPath)) { return $userProfile.LocalPath }
    } catch { }
    return $null
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
        port                 = [int](Get-StateValue $previous 'port' 22)
        port_changed         = [bool](Get-StateValue $previous 'port_changed' $false)
        port_previous        = [string](Get-StateValue $previous 'port_previous' '')
        sshd_config_created  = [bool](Get-StateValue $previous 'sshd_config_created' $false)
        host_keys_generated  = [bool](Get-StateValue $previous 'host_keys_generated' $false)
        user_keys_file       = [string](Get-StateValue $previous 'user_keys_file' '')
        user_keys_file_created = [bool](Get-StateValue $previous 'user_keys_file_created' $false)
        user_key_added       = [string](Get-StateValue $previous 'user_key_added' '')
    }

    Write-Host 'Doorbell test host setup'

    # ---- working directory first: the state file lives there -------------------------------
    if ([string]::IsNullOrWhiteSpace($InteractiveUser)) {
        $InteractiveUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
    }
    if ([string]::IsNullOrWhiteSpace($InteractiveUser)) {
        # A Remote Desktop logon is not a console logon; the account running this script is
        # then the interactive user whose desktop the UI tests will use.
        $InteractiveUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Write-Host "No console logon found; using the account running this script: $InteractiveUser"
    }
    if ([string]::IsNullOrWhiteSpace($InteractiveUser)) {
        throw 'Could not determine the interactive user. Pass -InteractiveUser.'
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
    # A failure here is reported with its evidence and the script goes on: the key, the
    # default shell and the task do not depend on the service, and a second run after the
    # cause is fixed then only has the service left to do.
    $sshdExe = Join-Path $OpenSshDir 'sshd.exe'
    $keygenExe = Join-Path $OpenSshDir 'ssh-keygen.exe'
    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    $configChanged = $false
    if ($null -eq $service) {
        Problem 'The sshd service does not exist although the OpenSSH Server capability is installed. A restart of Windows may be pending.'
    } else {
        if (-not $state.sshd_recorded) {
            $state.sshd_previous_start = [string]$service.StartType
            $state.sshd_was_running = ($service.Status -eq 'Running')
            $state.sshd_recorded = $true
        }
        if ($service.StartType -ne 'Automatic') {
            Set-Service -Name sshd -StartupType Automatic
            Changed "sshd start type: $($service.StartType) -> Automatic"
        } else { Note 'sshd already starts automatically' }
        Save-State $state

        # Port: only written when it is not the default, or when an earlier run changed it.
        if ($Port -ne 22 -or $state.port_changed) {
            if (-not (Test-Path -LiteralPath $SshDataDir)) { New-Item -ItemType Directory -Path $SshDataDir | Out-Null }
            if (-not (Test-Path -LiteralPath $SshdConfig)) {
                $template = Join-Path $OpenSshDir 'sshd_config_default'
                if (Test-Path -LiteralPath $template) {
                    Copy-Item -LiteralPath $template -Destination $SshdConfig
                    $state.sshd_config_created = $true
                    Changed "Created $SshdConfig from the default template"
                } else {
                    Problem "$SshdConfig does not exist and there is no default template to copy; the port was not set"
                }
            }
            if (Test-Path -LiteralPath $SshdConfig) {
                $current = Get-ConfiguredPort (Read-ConfigLines $SshdConfig)
                if (-not $state.port_changed) { $state.port_previous = $current }
                if ($current -ne [string]$Port) {
                    Set-ConfiguredPort $SshdConfig ([string]$Port)
                    $state.port_changed = $true
                    $configChanged = $true
                    $shown = $current
                    if ($shown -eq '') { $shown = '22 (default)' }
                    Changed "sshd_config Port: $shown -> $Port"
                } else { Note "sshd_config already sets Port $Port" }
            }
        }
        $state.port = $Port
        Save-State $state

        $foreign = @(Get-ForeignListeners $Port)
        if ($foreign.Count -gt 0) {
            Problem ("TCP port $Port is already in use by: " + ($foreign -join '; ') + ". sshd cannot listen there. Run this script again with -Port <free port>, for example -Port 2222.")
        }

        $hostKeys = @(Get-ChildItem -LiteralPath $SshDataDir -Filter 'ssh_host_*_key' -ErrorAction SilentlyContinue)
        if ($hostKeys.Count -eq 0) {
            Write-Host '    No SSH host keys yet; running ssh-keygen -A:'
            $code = Invoke-Tool $keygenExe @('-A')
            $hostKeys = @(Get-ChildItem -LiteralPath $SshDataDir -Filter 'ssh_host_*_key' -ErrorAction SilentlyContinue)
            if ($code -eq 0 -and $hostKeys.Count -gt 0) {
                $state.host_keys_generated = $true
                Changed "Generated SSH host keys in $SshDataDir"
            } else {
                Problem "ssh-keygen -A did not create host keys (exit code $code)"
            }
            Save-State $state
        } else { Note 'SSH host keys exist' }

        Write-Host '    Configuration check (sshd.exe -t):'
        $check = Invoke-Tool $sshdExe @('-t')
        if ($check -eq 0) { Note 'sshd accepts its configuration' }
        else { Problem "sshd.exe -t reported a configuration problem (exit code $check); see its output above" }

        $service = Get-Service -Name sshd
        try {
            if ($service.Status -ne 'Running') {
                Start-Service -Name sshd
                Changed 'Started the sshd service'
            } elseif ($configChanged) {
                Restart-Service -Name sshd -Force
                Changed 'Restarted the sshd service for the new port'
            } else { Note 'sshd is already running' }
        } catch {
            Problem ("The sshd service did not start: " + $_.Exception.Message)
            if (Test-RebootPending) {
                Problem 'Windows has a restart pending (the OpenSSH Server install is not finished until then). RESTART THIS PC, then run this script again; nothing else needs fixing.'
            }
            Show-SshdDiagnostics
        }
        Save-State $state
    }

    # ---- 3. firewall ----------------------------------------------------------------------
    if ($null -eq (Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $FirewallRule -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $Port -Profile Private -RemoteAddress LocalSubnet `
            -Description 'Doorbell UI tests: SSH from the local subnet. Added by setup_test_host.ps1.' | Out-Null
        $state.firewall_rule_added = $true
        Changed "Added firewall rule '$FirewallRule' (TCP $Port in, Private profile, local subnet)"
    } else {
        $rulePort = [string](Get-NetFirewallRule -DisplayName $FirewallRule | Get-NetFirewallPortFilter).LocalPort
        if ($rulePort -ne [string]$Port) {
            Set-NetFirewallRule -DisplayName $FirewallRule -LocalPort $Port
            Changed "Firewall rule '$FirewallRule' port: $rulePort -> $Port"
        } else { Note "Firewall rule '$FirewallRule' already exists" }
    }
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
    # The in-box OpenSSH 7.7 only reads that file through the "Match Group administrators"
    # block of its default sshd_config. A config without the block (an older or edited one)
    # reads the user's own authorized_keys instead, so the key goes there as well.
    $usesAdminFile = (Test-Path -LiteralPath $SshdConfig) -and
        (@(Read-ConfigLines $SshdConfig | Where-Object { $_ -match '^\s*AuthorizedKeysFile\s+.*administrators_authorized_keys' }).Count -gt 0)
    if ((Test-Path -LiteralPath $SshdConfig) -and -not $usesAdminFile) {
        $profilePath = Get-UserProfilePath $InteractiveUser
        if ($null -eq $profilePath) {
            Problem "sshd_config does not use administrators_authorized_keys and the profile folder of $InteractiveUser was not found; add the key to that user's .ssh\authorized_keys by hand"
        } else {
            $userSsh = Join-Path $profilePath '.ssh'
            $userKeys = Join-Path $userSsh 'authorized_keys'
            if (-not (Test-Path -LiteralPath $userSsh)) { New-Item -ItemType Directory -Path $userSsh | Out-Null }
            $existing = @()
            if (Test-Path -LiteralPath $userKeys) { $existing = @(Get-Content -LiteralPath $userKeys) }
            if (@($existing | Where-Object { (Get-KeyBody $_) -eq $wanted }).Count -eq 0) {
                if (-not (Test-Path -LiteralPath $userKeys)) { $state.user_keys_file_created = $true }
                Add-Content -LiteralPath $userKeys -Value $PublicKey.Trim() -Encoding ascii
                $state.user_keys_file = $userKeys
                $state.user_key_added = $wanted
                Changed "Added the test key to $userKeys (this sshd_config does not use administrators_authorized_keys)"
            } else { Note "The test key is already in $userKeys" }
            # StrictModes: only the user, Administrators and SYSTEM may reach the file.
            & icacls.exe $userKeys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' /grant "${InteractiveUser}:F" | Out-Null
            if ($LASTEXITCODE -ne 0) { Problem "icacls failed on $userKeys" }
        }
        Save-State $state
    } elseif (-not (Test-Path -LiteralPath $SshdConfig)) {
        Note "sshd_config does not exist yet (sshd creates it on its first start); run this script again after sshd has started once so the key location can be checked"
    }

    # The driver always starts powershell.exe explicitly, so it also works on an OpenSSH that
    # ignores this value; the setting only makes an interactive ssh session land in PowerShell.
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
    $portText = ''
    if ($Port -ne 22) { $portText = " --port $Port" }
    Write-Host "    win/scripts/run_remote_tests.sh $hostText $userText$portText"
    Write-Host 'Keep this user logged on with the screen unlocked while tests run.'
    Write-Host "To undo everything: .\setup_test_host.ps1 -Uninstall"
    if ($script:Problems.Count -gt 0) {
        Write-Host ''
        Write-Host ("SETUP IS NOT COMPLETE: {0} problem(s). The steps that could be done were done." -f $script:Problems.Count) -ForegroundColor Red
        foreach ($problem in $script:Problems) { Write-Host ('  ! ' + $problem) -ForegroundColor Red }
        Write-Host 'Fix the cause, then run this script again; it only does what is still missing.'
        exit 1
    }
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
    $userKeys = [string](Get-StateValue $state 'user_keys_file' '')
    $userAdded = [string](Get-StateValue $state 'user_key_added' '')
    if ($userAdded -ne '' -and $userKeys -ne '' -and (Test-Path -LiteralPath $userKeys)) {
        $keptUser = @(Get-Content -LiteralPath $userKeys | Where-Object { (Get-KeyBody $_) -ne $userAdded })
        if ((Get-StateValue $state 'user_keys_file_created' $false) -and $keptUser.Count -eq 0) {
            Remove-Item -LiteralPath $userKeys
            Changed "Removed $userKeys (this script created it and no other key is in it)"
        } else {
            Set-Content -LiteralPath $userKeys -Value $keptUser -Encoding ascii
            Changed "Removed the test key from $userKeys"
        }
    }
    if ((Get-StateValue $state 'firewall_rule_added' $false) -and
        $null -ne (Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue)) {
        Remove-NetFirewallRule -DisplayName $FirewallRule
        Changed "Removed firewall rule '$FirewallRule'"
    }
    if ((Get-StateValue $state 'port_changed' $false) -and (Test-Path -LiteralPath $SshdConfig)) {
        if (Get-StateValue $state 'sshd_config_created' $false) {
            Remove-Item -LiteralPath $SshdConfig
            Changed "Removed $SshdConfig (this script created it)"
        } else {
            $before = [string](Get-StateValue $state 'port_previous' '')
            Set-ConfiguredPort $SshdConfig $before
            if ($before -eq '') { Changed 'Removed the Port line from sshd_config (there was none before)' }
            else { Changed "sshd_config Port restored to $before" }
        }
        $running = Get-Service -Name sshd -ErrorAction SilentlyContinue
        if ($null -ne $running -and $running.Status -eq 'Running' -and (Get-StateValue $state 'sshd_was_running' $false)) {
            Write-Host '  (restarting sshd ends any SSH session that is running this script)'
            Restart-Service -Name sshd -Force
        }
    }
    if ((Get-StateValue $state 'host_keys_generated' $false) -and (Get-StateValue $state 'capability_installed' $false)) {
        $keys = @(Get-ChildItem -LiteralPath $SshDataDir -Filter 'ssh_host_*' -ErrorAction SilentlyContinue)
        foreach ($key in $keys) { Remove-Item -LiteralPath $key.FullName -Force }
        if ($keys.Count -gt 0) { Changed "Removed the SSH host keys this script generated in $SshDataDir" }
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
