#Requires -Version 5.1
<#
.SYNOPSIS
  UI smoke suite for the Windows shell, driven through UI Automation.

.DESCRIPTION
  Runs in the interactive desktop session of the test host (started by run_remote_tests.sh
  through the DoorbellTest-RunJob task; it can also be run by hand). It starts an isolated
  instance of the app in UI test mode, walks every screen, checks key elements by
  AutomationId, takes a screenshot of each screen in light and dark, and writes result.json.

  Isolation: a throwaway data directory, its own boot.json (not paired, no seed peers, ports
  away from the defaults, HTTPS off) and DOORBELL_UI_TEST=1. The instance has no cluster key,
  so it cannot join a household cluster.

  Only assemblies that ship with Windows are used. Ids must belong to elements UI Automation
  exposes: controls, text blocks and the zoom host. Plain panels and borders have no
  automation peer and cannot be asserted on.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AppExe,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [ValidateSet('indoor_panel', 'door_station')][string]$Role = 'indoor_panel',
    [int]$ListenPort = 47972,
    [int]$HttpPort = 47980,
    [int]$StartTimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace DoorbellTest -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, int data, System.UIntPtr extra);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr window);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
[void][DoorbellTest.Native]::SetProcessDPIAware()

$AE = [System.Windows.Automation.AutomationElement]
$Tree = [System.Windows.Automation.TreeScope]
$script:Checks = New-Object System.Collections.Generic.List[object]
$script:Shots = New-Object System.Collections.Generic.List[string]
$script:Process = $null
$script:AckLines = 0
$script:BlankReported = $false

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$DataDir = Join-Path $OutDir ('data-' + $Role)
$ShotDir = Join-Path $OutDir 'screenshots'
if (Test-Path -LiteralPath $DataDir) { Remove-Item -LiteralPath $DataDir -Recurse -Force }
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
New-Item -ItemType Directory -Path $ShotDir -Force | Out-Null
$CommandFile = Join-Path $DataDir 'ui-test-command.txt'
$AckFile = Join-Path $DataDir 'ui-test-ack.txt'

function Add-Check([string]$name, [bool]$ok, [string]$detail = '') {
    $script:Checks.Add([pscustomobject]@{ name = $name; ok = $ok; detail = $detail })
    $mark = if ($ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1} {2}" -f $mark, $name, $detail)
}

function Get-AppWindows {
    # Every top-level window of the app process: the main window and any dialog over it.
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        $AE::ProcessIdProperty, $script:Process.Id)
    return @($AE::RootElement.FindAll($Tree::Children, $condition))
}

function Find-ById([string]$id, [int]$timeoutMs = 5000) {
    $condition = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $id)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    do {
        foreach ($window in @(Get-AppWindows)) {
            $found = $window.FindFirst($Tree::Subtree, $condition)
            if ($null -ne $found) { return $found }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    return $null
}

function Test-OnScreen($element) {
    if ($null -eq $element) { return $false }
    try {
        $rect = $element.Current.BoundingRectangle
        return (-not $element.Current.IsOffscreen) -and (-not $rect.IsEmpty) -and
               $rect.Width -gt 0 -and $rect.Height -gt 0
    } catch { return $false }
}

function Assert-Element([string]$screen, [string]$id, [int]$timeoutMs = 5000) {
    $element = Find-ById $id $timeoutMs
    $ok = Test-OnScreen $element
    $detail = if ($null -eq $element) { 'not found' } elseif (-not $ok) { 'found but not on screen' } else { '' }
    Add-Check ("{0}: {1}" -f $screen, $id) $ok $detail
    return $element
}

function Assert-Gone([string]$screen, [string]$id) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        if (-not (Test-OnScreen (Find-ById $id 200))) { Add-Check ("{0}: {1} is gone" -f $screen, $id) $true; return }
    } while ([DateTime]::UtcNow -lt $deadline)
    Add-Check ("{0}: {1} is gone" -f $screen, $id) $false 'still on screen'
}

function Get-Center($element) {
    $rect = $element.Current.BoundingRectangle
    return @([int]($rect.X + $rect.Width / 2), [int]($rect.Y + $rect.Height / 2))
}

# Real mouse input rather than InvokePattern: Invoke on a button that opens a modal dialog
# does not return until the dialog closes, and the suite has to drive that dialog.
function Invoke-Click($element) {
    $point = Get-Center $element
    [void][DoorbellTest.Native]::SetCursorPos($point[0], $point[1])
    Start-Sleep -Milliseconds 80
    [DoorbellTest.Native]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [DoorbellTest.Native]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
}

# Rests the pointer on an element without pressing, so a screenshot shows its hover state.
function Invoke-Hover($element) {
    $point = Get-Center $element
    [void][DoorbellTest.Native]::SetCursorPos($point[0] - 3, $point[1])
    Start-Sleep -Milliseconds 80
    [void][DoorbellTest.Native]::SetCursorPos($point[0], $point[1])
    Start-Sleep -Milliseconds 400
}

function Invoke-Wheel($element, [int]$notches) {
    $point = Get-Center $element
    [void][DoorbellTest.Native]::SetCursorPos($point[0], $point[1])
    Start-Sleep -Milliseconds 80
    $step = if ($notches -ge 0) { 120 } else { -120 }
    for ($i = 0; $i -lt [Math]::Abs($notches); $i++) {
        [DoorbellTest.Native]::mouse_event(0x0800, 0, 0, $step, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 60
    }
    Start-Sleep -Milliseconds 300
}

function Click-Id([string]$screen, [string]$id) {
    $element = Find-ById $id
    if (-not (Test-OnScreen $element)) {
        Add-Check ("{0}: click {1}" -f $screen, $id) $false 'not on screen'
        return $false
    }
    Invoke-Click $element
    return $true
}

function Get-AckLines {
    if (-not (Test-Path -LiteralPath $AckFile)) { return @() }
    try { return @(Get-Content -LiteralPath $AckFile) } catch { return @() }
}

# Sends one test-mode command and returns the app's answer ("ok", "ok 1.44", "error: ...").
function Send-Command([string]$command, [int]$timeoutMs = 8000) {
    Set-Content -LiteralPath $CommandFile -Value $command -Encoding ascii
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    do {
        $lines = @(Get-AckLines)
        if ($lines.Count -gt $script:AckLines) {
            $line = $lines[$lines.Count - 1]
            $script:AckLines = $lines.Count
            $parts = $line -split ' ', 3
            if ($parts.Count -ge 3) { return $parts[2] }
            return $line
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return 'error: no answer'
}

function Assert-Command([string]$command) {
    $answer = Send-Command $command
    Add-Check ("command: {0}" -f $command) ($answer -like 'ok*') $answer
    Start-Sleep -Milliseconds 500
    return $answer
}

function Save-Shot([string]$name) {
    try {
        $windows = @(Get-AppWindows)
        if ($windows.Count -eq 0) { throw 'no window' }
        # The union of the app's windows, so a dialog is captured together with what is under it.
        $left = [double]::MaxValue; $top = [double]::MaxValue; $right = 0.0; $bottom = 0.0
        foreach ($window in $windows) {
            $rect = $window.Current.BoundingRectangle
            if ($rect.IsEmpty) { continue }
            $left = [Math]::Min($left, $rect.Left); $top = [Math]::Min($top, $rect.Top)
            $right = [Math]::Max($right, $rect.Right); $bottom = [Math]::Max($bottom, $rect.Bottom)
        }
        $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $x = [int][Math]::Max($left, $screen.Left); $y = [int][Math]::Max($top, $screen.Top)
        $width = [int]([Math]::Min($right, $screen.Right) - $x)
        $height = [int]([Math]::Min($bottom, $screen.Bottom) - $y)
        if ($width -le 0 -or $height -le 0) { throw 'empty bounds' }
        $bitmap = New-Object System.Drawing.Bitmap($width, $height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($x, $y, 0, 0, $bitmap.Size)
        $file = Join-Path $ShotDir ("{0}-{1}.png" -f $Role, $name)
        $bitmap.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose(); $bitmap.Dispose()
        $script:Shots.Add((Split-Path -Leaf $file))
        if (-not $script:BlankReported -and (Test-BlankCapture $file)) {
            $script:BlankReported = $true
            Add-Check 'desktop: the screen is being drawn' $false ("the capture " + (Split-Path -Leaf $file) + " is one flat colour; is the Remote Desktop session disconnected or the screen locked?")
        }
    } catch {
        Add-Check ("screenshot: {0}" -f $name) $false $_.Exception.Message
    }
}

function Set-Look([string]$appearance) {
    [void](Assert-Command ("appearance " + $appearance))
    Start-Sleep -Milliseconds 700
}

function Focus-App {
    $handle = $script:Process.MainWindowHandle
    if ($handle -ne [IntPtr]::Zero) { [void][DoorbellTest.Native]::SetForegroundWindow($handle) }
    Start-Sleep -Milliseconds 300
}

# ---- screens ------------------------------------------------------------------------------

function Test-Calls([string]$look) {
    [void](Assert-Command 'incoming')
    foreach ($id in @('IncomingTitle', 'AnswerButton', 'QuickReplyToggle', 'IgnoreButton',
                      'IncomingZoom')) { [void](Assert-Element 'incoming' $id) }
    # Unlock is shown only where a door has an unlock action; this isolated instance has none.
    Add-Check 'incoming: no Unlock without an unlock action' (-not (Test-OnScreen (Find-ById 'OpenDoorButton' 300)))
    # The fixed order of the primary actions: Answer, Reply, Ignore (left to right or top down).
    $answer = Find-ById 'AnswerButton'; $reply = Find-ById 'QuickReplyToggle'; $ignore = Find-ById 'IgnoreButton'
    if ((Test-OnScreen $answer) -and (Test-OnScreen $reply) -and (Test-OnScreen $ignore)) {
        $a = Get-Center $answer; $r = Get-Center $reply; $i = Get-Center $ignore
        $ordered = (($a[0] -lt $r[0]) -and ($r[0] -lt $i[0])) -or (($a[1] -lt $r[1]) -and ($r[1] -lt $i[1]))
        Add-Check 'incoming: Answer, Reply, Ignore order' $ordered ("{0},{1} {2},{3} {4},{5}" -f $a[0], $a[1], $r[0], $r[1], $i[0], $i[1])
    }
    Save-Shot ("incoming-" + $look)
    # The outlined destructive action under the pointer: its label must stay readable.
    if (Test-OnScreen $ignore) {
        Invoke-Hover $ignore
        Save-Shot ("incoming-hover-ignore-" + $look)
        Invoke-Hover (Find-ById 'IncomingTitle')
    }

    # Zoom with the mouse wheel over the picture: in, clamped at 4x, and back out to fitted.
    $zoom = Find-ById 'IncomingZoom'
    if (Test-OnScreen $zoom) {
        $before = Send-Command 'zoom-scale'
        Invoke-Wheel $zoom 3
        $after = Send-Command 'zoom-scale'
        Add-Check 'zoom: wheel zooms in' (($before -eq 'ok 1') -and ($after -like 'ok *') -and
            ([double]($after -replace '^ok ', '') -gt 1.0)) ("{0} -> {1}" -f $before, $after)
        Save-Shot ("incoming-zoomed-" + $look)
        Invoke-Wheel $zoom 20
        $max = Send-Command 'zoom-scale'
        Add-Check 'zoom: clamped at 4x' ($max -eq 'ok 4') $max
        Invoke-Wheel $zoom -40
        $fitted = Send-Command 'zoom-scale'
        Add-Check 'zoom: wheel returns to fitted' ($fitted -eq 'ok 1') $fitted
        # Zooming must not have triggered a call action: the screen is still the ringing call.
        [void](Assert-Element 'incoming after zoom' 'AnswerButton')
    }

    # The stage with a picture in it: fitted at 1x, then zoomed. A 4:3 and a rotated 9:16
    # test card; zoomed, the picture must grow past its fitted rectangle up to the stage edges.
    if (Test-OnScreen $zoom) {
        foreach ($card in @('640x480', '720x1280')) {
            [void](Assert-Command ("picture " + $card))
            Start-Sleep -Milliseconds 300
            Save-Shot ("incoming-picture-{0}-{1}" -f $card, $look)
            Invoke-Wheel $zoom 4
            Save-Shot ("incoming-picture-{0}-zoomed-{1}" -f $card, $look)
            Invoke-Wheel $zoom -40
        }
        $stage = $zoom.Current.BoundingRectangle
        $window = (@(Get-AppWindows))[0].Current.BoundingRectangle
        Add-Check 'stage: takes the space the layout leaves' (($stage.Width -ge $window.Width * 0.5) -and ($stage.Height -ge $window.Height * 0.5)) ("{0}x{1} of {2}x{3}" -f [int]$stage.Width, [int]$stage.Height, [int]$window.Width, [int]$window.Height)
    }

    if (Click-Id 'incoming' 'QuickReplyToggle') {
        [void](Assert-Element 'quick replies' 'QuickReplySheetTitle')
        Save-Shot ("quick-replies-" + $look)
        [void](Click-Id 'quick replies' 'QuickReplySheetClose')
    }
    [void](Assert-Command 'home')

    [void](Assert-Command 'monitor')
    foreach ($id in @('IncomingTitle', 'MonitorButton', 'IgnoreButton')) { [void](Assert-Element 'monitor' $id) }
    Save-Shot ("monitor-" + $look)
    [void](Assert-Command 'home')

    [void](Assert-Command 'incall')
    foreach ($id in @('InCallTitle', 'EndCallButton', 'InCallZoom')) { [void](Assert-Element 'in call' $id) }
    Save-Shot ("in-call-" + $look)
    $callZoom = Find-ById 'InCallZoom'
    if (Test-OnScreen $callZoom) {
        [void](Assert-Command 'picture 1280x720')
        Start-Sleep -Milliseconds 300
        Save-Shot ("in-call-picture-" + $look)
        Invoke-Wheel $callZoom 4
        Save-Shot ("in-call-picture-zoomed-" + $look)
        Invoke-Wheel $callZoom -40
    }
    [void](Assert-Command 'home')
}

# SOS: a compact trigger, then a confirmation card. The suite opens the card and cancels it;
# it never slides or presses Send, so no countdown starts and Core is never told.
function Test-Sos([string]$look) {
    $trigger = Assert-Element 'sos' 'SosButton'
    if (-not (Test-OnScreen $trigger)) { return }
    $rect = $trigger.Current.BoundingRectangle
    Add-Check 'sos: trigger is compact and touch sized' (($rect.Height -ge 44) -and ($rect.Height -le 64) -and ($rect.Width -le 200)) ("{0}x{1}" -f [int]$rect.Width, [int]$rect.Height)
    Add-Check 'sos: the slide is not on the home surface' (-not (Test-OnScreen (Find-ById 'SosSlide' 300)))
    Invoke-Click $trigger
    foreach ($id in @('SosConfirmTitle', 'SosConfirmBody', 'SosSlide', 'SosConfirmSend', 'SosConfirmCancel')) {
        [void](Assert-Element 'sos confirm' $id)
    }
    Add-Check 'sos confirm: opening it starts no countdown' (-not (Test-OnScreen (Find-ById 'SosCountdownCancel' 500)))
    $send = Find-ById 'SosConfirmSend'
    if ($null -ne $send) {
        Add-Check 'sos confirm: Send SOS does not have the focus' (-not $send.Current.HasKeyboardFocus)
    }
    Save-Shot ("sos-confirm-" + $look)
    [void](Click-Id 'sos confirm' 'SosConfirmCancel')
    if (Test-OnScreen (Find-ById 'SosConfirmTitle' 1500)) {
        # Say what the pointer is over when the press did not close the card.
        $pos = [System.Windows.Forms.Cursor]::Position
        $under = $null
        try { $under = [System.Windows.Automation.AutomationElement]::FromPoint((New-Object System.Windows.Point($pos.X, $pos.Y))) } catch { }
        $what = if ($null -eq $under) { 'nothing' } else { "{0} '{1}' ({2})" -f $under.Current.AutomationId, $under.Current.Name, $under.Current.ClassName }
        Add-Check 'sos confirm: Cancel closes on the first press' $false ("pointer at {0},{1} over {2}" -f $pos.X, $pos.Y, $what)
        Save-Shot ("sos-cancel-stuck-" + $look)
        [void](Click-Id 'sos confirm' 'SosConfirmCancel')
    }
    Assert-Gone 'sos confirm' 'SosConfirmTitle'
    Add-Check 'sos confirm: cancel starts no countdown' (-not (Test-OnScreen (Find-ById 'SosCountdownCancel' 500)))
}

# Role change: open the form from This device and cancel it. The suite never applies it (that
# would restart the app), so it only checks that the form and its fields are there.
function Test-RoleForm([string]$look) {
    if (-not (Click-Id 'settings' 'SettingsCategory_device')) { return }
    if (-not (Click-Id 'role form' 'SettingsAction_change_role')) { return }
    foreach ($id in @('RoleFormRole', 'RoleFormCancel', 'RoleFormApply')) { [void](Assert-Element 'role form' $id) }
    $apply = Find-ById 'RoleFormApply'
    if ($null -ne $apply) {
        Add-Check 'role form: Change role does not have the focus' (-not $apply.Current.HasKeyboardFocus)
    }
    Save-Shot ("role-form-" + $look)
    [void](Click-Id 'role form' 'RoleFormCancel')
    Assert-Gone 'role form' 'RoleFormRole'
    Add-Check 'role form: cancel keeps the app running' (-not $script:Process.HasExited)
}

# Advanced > App log: read-only, so the suite opens it, checks it shows something, and closes.
function Test-LogViewer([string]$look) {
    if (-not (Click-Id 'settings' 'SettingsCategory_advanced')) { return }
    if (-not (Click-Id 'log viewer' 'SettingsAction_view_log')) { return }
    $text = Assert-Element 'log viewer' 'LogViewerText'
    Save-Shot ("log-viewer-" + $look)
    [void](Click-Id 'log viewer' 'LogViewerClose')
    Assert-Gone 'log viewer' 'LogViewerText'
}

# An unpaired instance offers onboarding again whenever its banner is tapped; a pass always
# starts from the home screen.
function Close-Onboarding {
    if (Test-OnScreen (Find-ById 'PairingOverlay' 300)) { [void](Send-Command 'skip-pairing') }
    Start-Sleep -Milliseconds 300
}

# True when the capture is one flat colour: the desktop is not being drawn (for example a
# Remote Desktop session that was disconnected), so no screenshot would mean anything.
function Test-BlankCapture([string]$file) {
    try {
        $bitmap = New-Object System.Drawing.Bitmap($file)
        try {
            $first = $bitmap.GetPixel(0, 0).ToArgb()
            for ($x = 1; $x -lt 24; $x++) {
                for ($y = 1; $y -lt 16; $y++) {
                    $px = [int](($bitmap.Width - 1) * $x / 24)
                    $py = [int](($bitmap.Height - 1) * $y / 16)
                    if ($bitmap.GetPixel($px, $py).ToArgb() -ne $first) { return $false }
                }
            }
            return $true
        } finally { $bitmap.Dispose() }
    } catch { return $false }
}

# An element that is on screen but drawn in one flat colour cannot be seen: its fill and its
# label have ended up the same colour as what is behind it.
function Assert-Drawn([string]$screen, [string]$id) {
    $element = Find-ById $id 3000
    if (-not (Test-OnScreen $element)) {
        Add-Check ("{0}: {1} is drawn" -f $screen, $id) $false 'not on screen'
        return
    }
    $rect = $element.Current.BoundingRectangle
    $bitmap = New-Object System.Drawing.Bitmap([int]$rect.Width, [int]$rect.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen([int]$rect.X, [int]$rect.Y, 0, 0, $bitmap.Size)
        $first = $bitmap.GetPixel(2, 2).ToArgb()
        $different = 0
        for ($x = 2; $x -lt $bitmap.Width - 2; $x += 3) {
            for ($y = 2; $y -lt $bitmap.Height - 2; $y += 3) {
                if ($bitmap.GetPixel($x, $y).ToArgb() -ne $first) { $different++ }
            }
        }
        Add-Check ("{0}: {1} is drawn" -f $screen, $id) ($different -gt 20) ("{0} pixels differ from its corner" -f $different)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

function Test-IndoorPanel {
    # A fresh, unpaired instance opens on pairing onboarding.
    $pairing = Find-ById 'PairingOverlay' 8000
    if (Test-OnScreen $pairing) {
        Add-Check 'pairing: onboarding shown on an unpaired device' $true
        Set-Look 'dark'
        Save-Shot 'pairing-onboarding-dark'
        Set-Look 'light'
        Save-Shot 'pairing-onboarding-light'
        [void](Assert-Command 'skip-pairing')
    } else {
        Add-Check 'pairing: onboarding shown on an unpaired device' $false 'PairingOverlay not on screen'
    }
    [void](Assert-Element 'pairing' 'PairBannerText')

    foreach ($look in @('light', 'dark')) {
        Set-Look $look
        Close-Onboarding
        foreach ($id in @('HomeNav', 'NavHome', 'NavHistory', 'AdminEntryButton', 'DashClock', 'DashDate',
                          'NoticeGlobalButton', 'DoorsSectionTitle', 'NavHistoryLabel', 'AdminUrlText')) {
            [void](Assert-Element 'dashboard' $id)
        }
        Save-Shot ("dashboard-" + $look)

        Test-Sos $look

        if (Click-Id 'dashboard' 'NavHistory') {
            foreach ($id in @('HistoryTitle', 'HistoryFilterAll', 'HistoryFilterMissed',
                              'HistoryList', 'HistoryMarkSeenButton')) { [void](Assert-Element 'history' $id) }
            [void](Click-Id 'history' 'HistoryFilterMissed')
            Save-Shot ("history-" + $look)
            [void](Click-Id 'history' 'NavHome')
            Assert-Gone 'history' 'HistoryTitle'
        }

        Test-Calls $look

        # Settings is behind the admin password: the entry opens the password dialog.
        if (Click-Id 'dashboard' 'AdminEntryButton') {
            [void](Assert-Element 'admin dialog' 'PasswordEntry')
            [void](Assert-Element 'admin dialog' 'OkPadBtn')
            Save-Shot ("admin-dialog-" + $look)
            [void](Click-Id 'admin dialog' 'CancelBtn')
            Assert-Gone 'admin dialog' 'PasswordEntry'
            # Cancelling the password must not open settings.
            Add-Check 'admin dialog: cancel does not open settings' (-not (Test-OnScreen (Find-ById 'SettingsNavigation' 1000)))
        }

        if (Click-Id 'dashboard' 'NoticeGlobalButton') {
            foreach ($id in @('BodyBox', 'PublishButton', 'CancelButton')) { [void](Assert-Element 'notice dialog' $id) }
            Save-Shot ("notice-dialog-" + $look)
            [void](Click-Id 'notice dialog' 'CancelButton')
            Assert-Gone 'notice dialog' 'BodyBox'
        }

        # Native settings, opened through the test hook (it skips the password this instance
        # has not set). Every category is selected once.
        [void](Assert-Command 'settings')
        $navigation = Assert-Element 'settings' 'SettingsNavigation' 8000
        if (Test-OnScreen $navigation) {
            foreach ($id in @('SettingsTitle', 'SettingsSearch', 'SettingsClose')) { [void](Assert-Element 'settings' $id) }
            $all = $navigation.FindAll($Tree::Subtree, [System.Windows.Automation.Condition]::TrueCondition)
            $categories = @($all | Where-Object { $_.Current.AutomationId -like 'SettingsCategory_*' -and (Test-OnScreen $_) })
            Add-Check 'settings: categories listed' ($categories.Count -ge 3) ("{0} categories" -f $categories.Count)
            foreach ($category in $categories) {
                $id = $category.Current.AutomationId
                Invoke-Click $category
                Add-Check ("settings: {0} opens" -f $id) (Test-OnScreen (Find-ById 'SettingsTitle' 2000))
                Save-Shot ("settings-{0}-{1}" -f ($id -replace '^SettingsCategory_', ''), $look)
            }
            Test-RoleForm $look
            Test-LogViewer $look
            [void](Click-Id 'settings' 'SettingsClose')
            Assert-Gone 'settings' 'SettingsNavigation'
        }
        [void](Assert-Element 'dashboard after settings' 'DashClock')
    }
}

function Test-DoorStation {
    $pairing = Find-ById 'PairingOverlay' 8000
    if (Test-OnScreen $pairing) { [void](Assert-Command 'skip-pairing') }
    foreach ($look in @('light', 'dark')) {
        Set-Look $look
        Close-Onboarding
        foreach ($id in @('CallButton', 'ClockText', 'TouchHint')) { [void](Assert-Element 'visitor' $id) }
        # A door station shows no route to settings or to the dashboard.
        foreach ($id in @('AdminEntryButton', 'HomeNav', 'NoticeGlobalButton')) {
            Add-Check ("visitor: no {0}" -f $id) (-not (Test-OnScreen (Find-ById $id 300)))
        }
        # The purpose buttons and the call button can be seen in both appearances.
        foreach ($id in @('Purpose_p_visit', 'Purpose_p_delivery', 'CallButton')) { Assert-Drawn 'visitor' $id }
        $call = Find-ById 'CallButton'
        if (Test-OnScreen $call) {
            $rect = $call.Current.BoundingRectangle
            Add-Check 'visitor: Call button is at least 72 px tall' ($rect.Height -ge 72) ("{0} px" -f [int]$rect.Height)
        }
        Save-Shot ("visitor-" + $look)
        # A door station reaches settings only through the hidden corner and the admin
        # password; the test hook stands in for that to check the role form opens here too.
        [void](Assert-Command 'settings')
        if (Test-OnScreen (Assert-Element 'door station settings' 'SettingsNavigation' 8000)) {
            Test-RoleForm $look
            [void](Assert-Element 'role form (door station)' 'SettingsAction_change_role')
            [void](Click-Id 'door station settings' 'SettingsClose')
            Assert-Gone 'door station settings' 'SettingsNavigation'
        }
        [void](Assert-Command 'incall')
        foreach ($id in @('InCallTitle', 'EndCallButton')) { [void](Assert-Element 'visitor in call' $id) }
        Save-Shot ("visitor-in-call-" + $look)
        [void](Assert-Command 'home')
    }
}

# ---- run ----------------------------------------------------------------------------------

$started = Get-Date
try {
    if (-not (Test-Path -LiteralPath $AppExe)) { throw "App not found: $AppExe" }
    $boot = [ordered]@{
        name = 'uitest-' + $Role; role = $Role; ui_lang = 'en'; kiosk = $false; setup_complete = $true
        door = $(if ($Role -eq 'door_station') { 'door-uitest1' } else { '' })
        listen_port = $ListenPort; http_port = $HttpPort; https_port = 0
    }
    ($boot | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $DataDir 'boot.json') -Encoding ascii

    $env:DOORBELL_UI_TEST = '1'
    $script:Process = Start-Process -FilePath $AppExe -PassThru `
        -ArgumentList @('--ui-test', '--data-dir', ('"' + $DataDir + '"')) `
        -WorkingDirectory (Split-Path -Parent $AppExe)

    $deadline = [DateTime]::UtcNow.AddSeconds($StartTimeoutSeconds)
    $ready = $false
    while ([DateTime]::UtcNow -lt $deadline -and -not $script:Process.HasExited) {
        $script:Process.Refresh()
        if ($script:Process.MainWindowHandle -ne [IntPtr]::Zero -and @(Get-AckLines).Count -gt 0) { $ready = $true; break }
        Start-Sleep -Milliseconds 300
    }
    $script:AckLines = @(Get-AckLines).Count
    $exitText = if ($script:Process.HasExited) { 'exited with code ' + $script:Process.ExitCode } else { '' }
    Add-Check 'app: main window and test hooks are up' $ready $exitText
    if ($ready) {
        Start-Sleep -Seconds 2
        Focus-App
        if ($Role -eq 'door_station') { Test-DoorStation } else { Test-IndoorPanel }
        Add-Check 'app: still running after the walk' (-not $script:Process.HasExited)
        [void](Send-Command 'quit' 3000)
        if (-not $script:Process.WaitForExit(15000)) {
            Add-Check 'app: exits on request' $false 'still running; killed'
            $script:Process.Kill()
        } else {
            Add-Check 'app: exits on request' $true ("exit code {0}" -f $script:Process.ExitCode)
        }
    }
} catch {
    Add-Check 'suite: ran to the end' $false ($_ | Out-String)
} finally {
    if ($null -ne $script:Process -and -not $script:Process.HasExited) {
        try { $script:Process.Kill() } catch { }
    }
}

# The dispatcher's unhandled-exception handler writes crash.log; a clean run has none.
$crash = Join-Path $DataDir 'crash.log'
$crashText = ''
if (Test-Path -LiteralPath $crash) { $crashText = (Get-Content -LiteralPath $crash -Raw) }
Add-Check 'log: no unhandled exception (crash.log)' ($crashText.Length -eq 0) ($crashText -split "`n" | Select-Object -First 3 | Out-String).Trim()
foreach ($name in @('crash.log', 'doorbell.log', 'video.log', 'ui-test-ack.txt')) {
    $source = Join-Path $DataDir $name
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $OutDir ("{0}-{1}" -f $Role, $name)) -Force }
}

$failed = @($script:Checks | Where-Object { -not $_.ok })
$result = [ordered]@{
    schema = 1
    role = $Role
    app = $AppExe
    started = $started.ToUniversalTime().ToString('o')
    seconds = [int]((Get-Date) - $started).TotalSeconds
    passed = ($failed.Count -eq 0)
    total = $script:Checks.Count
    failed = $failed.Count
    checks = $script:Checks
    screenshots = $script:Shots
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutDir ("result-{0}.json" -f $Role)) -Encoding UTF8
Write-Host ("{0}: {1} checks, {2} failed" -f $Role, $script:Checks.Count, $failed.Count)
if ($failed.Count -eq 0) { exit 0 } else { exit 1 }
