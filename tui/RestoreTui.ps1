# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Windows Restore Manager
#
[CmdletBinding()]
param(
    [string]$Catalog
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Console]::InputEncoding = [Text.Encoding]::UTF8

# Resolve paths only after param() has finished. $PSScriptRoot can be empty
# while default parameter expressions are being evaluated in Windows
# PowerShell 5.1, especially when launched through a .cmd wrapper.
$script:ScriptPath = [string]$MyInvocation.MyCommand.Path

if ([string]::IsNullOrWhiteSpace($script:ScriptPath)) {
    $script:ScriptPath = [string]$PSCommandPath
}

if ([string]::IsNullOrWhiteSpace($script:ScriptPath)) {
    throw 'Unable to determine the path of RestoreTui.ps1.'
}

$script:ScriptPath = [IO.Path]::GetFullPath($script:ScriptPath)
$script:TuiRoot = Split-Path -Parent $script:ScriptPath
$script:Root = Split-Path -Parent $script:TuiRoot
$script:Cli = Join-Path $script:Root 'RestoreCli.ps1'
$script:WindowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

if ([string]::IsNullOrWhiteSpace($Catalog)) {
    $Catalog = Join-Path $script:Root 'config\catalog.json'
}
elseif (-not [IO.Path]::IsPathRooted($Catalog)) {
    $Catalog = Join-Path (Get-Location).Path $Catalog
}

$script:Catalog = [IO.Path]::GetFullPath($Catalog)

if (-not (Test-Path -LiteralPath $script:Cli)) {
    throw "CLI backend not found: $script:Cli"
}

if (-not (Test-Path -LiteralPath $script:WindowsPowerShell)) {
    throw "Windows PowerShell 5.1 not found: $script:WindowsPowerShell"
}

# Keep the TUI attached to the console from which it was started.
# It does not self-elevate into a second transient window. Read-only commands
# work normally; mutating CLI commands report if the current console is not
# elevated. Start PowerShell as Administrator when install/remove/system
# changes are needed.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$script:IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------------------------------------------------------------------------
# Console helpers / differential renderer
# ---------------------------------------------------------------------------
$script:OriginalCursorVisible = [Console]::CursorVisible
$script:OriginalForeground = [Console]::ForegroundColor
$script:OriginalBackground = [Console]::BackgroundColor
$script:OriginalTitle = [Console]::Title
$script:OriginalTreatControlCAsInput = [Console]::TreatControlCAsInput

$script:FrameActive = $false
$script:FrameLines = New-Object System.Collections.ArrayList
$script:LastFrame = @()
$script:LastWidth = 0
$script:LastHeight = 0

function Restore-ConsoleState {
    try { [Console]::CursorVisible = $script:OriginalCursorVisible } catch {}
    try { [Console]::ForegroundColor = $script:OriginalForeground } catch {}
    try { [Console]::BackgroundColor = $script:OriginalBackground } catch {}
    try { [Console]::Title = $script:OriginalTitle } catch {}
    try { [Console]::TreatControlCAsInput = $script:OriginalTreatControlCAsInput } catch {}
    try { [Console]::ResetColor() } catch {}
}

function Get-SafeWidth {
    try {
        # Never write into the last physical column. On classic conhost and
        # some Windows Terminal hosts that can wrap to the next line and make
        # the viewport scroll, which looks like flickering.
        return [Math]::Max(1, [Console]::WindowWidth - 1)
    }
    catch {
        return 119
    }
}

function Get-SafeHeight {
    try {
        return [Math]::Max(1, [Console]::WindowHeight)
    }
    catch {
        return 35
    }
}

function Fit-Text {
    param([string]$Text, [int]$Width)

    if ($Width -le 0) { return '' }
    if ($null -eq $Text) { $Text = '' }

    $Text = $Text -replace "`r|`n", ' '

    if ($Text.Length -gt $Width) {
        if ($Width -le 3) {
            return $Text.Substring(0, $Width)
        }

        return ($Text.Substring(0, $Width - 3) + '...')
    }

    return $Text.PadRight($Width)
}

function Join-TuiColumns {
    param(
        [object[]]$Values,
        [int[]]$Widths,
        [string]$Prefix = ' '
    )

    if ($null -eq $Values) { return $Prefix }

    $parts = @()

    for ($i = 0; $i -lt $Values.Count; $i++) {
        $value = [string]$Values[$i]

        if ($i -lt $Widths.Count) {
            $width = [Math]::Max(1, [int]$Widths[$i])
            $parts += (Fit-Text $value $width)
        }
        else {
            $parts += $value
        }
    }

    return ($Prefix + ($parts -join ' '))
}

function New-FrameLine {
    param(
        [string]$Text,
        [ConsoleColor]$Foreground,
        [ConsoleColor]$Background
    )

    return [pscustomobject]@{
        Text = $Text
        Foreground = $Foreground
        Background = $Background
    }
}

function Begin-TuiFrame {
    $script:FrameActive = $true
    $script:FrameLines.Clear()
}

function Write-TuiLine {
    param(
        [string]$Text = '',
        [ConsoleColor]$Foreground = [ConsoleColor]::Gray,
        [ConsoleColor]$Background = [ConsoleColor]::Black,
        [switch]$NoNewline
    )

    if ($script:FrameActive) {
        [void]$script:FrameLines.Add(
            (New-FrameLine -Text $Text -Foreground $Foreground -Background $Background)
        )
        return
    }

    $oldFg = [Console]::ForegroundColor
    $oldBg = [Console]::BackgroundColor

    try {
        [Console]::ForegroundColor = $Foreground
        [Console]::BackgroundColor = $Background

        if ($NoNewline) {
            [Console]::Write($Text)
        }
        else {
            [Console]::WriteLine($Text)
        }
    }
    finally {
        [Console]::ForegroundColor = $oldFg
        [Console]::BackgroundColor = $oldBg
    }
}

function Clear-PhysicalLine {
    param(
        [int]$Row,
        [int]$Width
    )

    try {
        if ($Row -lt 0 -or $Row -ge [Console]::BufferHeight) { return }

        [Console]::SetCursorPosition(0, $Row)
        [Console]::ForegroundColor = [ConsoleColor]::Gray
        [Console]::BackgroundColor = [ConsoleColor]::Black
        [Console]::Write((' ' * $Width))
    }
    catch {}
}

function Flush-TuiFrame {
    $script:FrameActive = $false

    $width = Get-SafeWidth
    $height = Get-SafeHeight
    $maxRows = [Math]::Max(1, $height - 1)

    # A resize invalidates the old coordinate map. One physical clear on a
    # resize is acceptable; normal navigation never clears the whole screen.
    if ($script:LastWidth -ne 0 -and
        ($script:LastWidth -ne $width -or $script:LastHeight -ne $height)) {
        try { [Console]::Clear() } catch {}
        $script:LastFrame = @()
    }

    $newFrame = @()

    $count = [Math]::Min($script:FrameLines.Count, $maxRows)

    for ($i = 0; $i -lt $count; $i++) {
        $source = $script:FrameLines[$i]
        $line = New-FrameLine `
            -Text (Fit-Text ([string]$source.Text) $width) `
            -Foreground $source.Foreground `
            -Background $source.Background

        $newFrame += $line

        $changed = $true

        if ($i -lt $script:LastFrame.Count) {
            $old = $script:LastFrame[$i]
            $changed = (
                $old.Text -ne $line.Text -or
                $old.Foreground -ne $line.Foreground -or
                $old.Background -ne $line.Background
            )
        }

        if (-not $changed) { continue }

        try {
            [Console]::SetCursorPosition(0, $i)
            [Console]::ForegroundColor = $line.Foreground
            [Console]::BackgroundColor = $line.Background
            [Console]::Write($line.Text)
        }
        catch {}
    }

    # Remove stale rows from the previous frame without clearing the viewport.
    if ($script:LastFrame.Count -gt $newFrame.Count) {
        $upper = [Math]::Min($script:LastFrame.Count, $maxRows)
        for ($i = $newFrame.Count; $i -lt $upper; $i++) {
            Clear-PhysicalLine -Row $i -Width $width
        }
    }

    $script:LastFrame = @($newFrame)
    $script:LastWidth = $width
    $script:LastHeight = $height

    try {
        [Console]::CursorVisible = $false
        $cursorRow = [Math]::Min($newFrame.Count, [Math]::Max(0, $height - 1))
        [Console]::SetCursorPosition(0, $cursorRow)
    }
    catch {}

    try { [Console]::ResetColor() } catch {}
}

function Reset-TuiSurface {
    $script:FrameActive = $false
    $script:FrameLines.Clear()
    $script:LastFrame = @()
    $script:LastWidth = 0
    $script:LastHeight = 0

    try {
        [Console]::CursorVisible = $false
        [Console]::ResetColor()
        [Console]::Clear()
        [Console]::SetCursorPosition(0, 0)
    }
    catch {
        try { Clear-Host } catch {}
    }
}

# Kept as a compatibility name for prompt/preview screens. It is intentionally
# NOT used by the normal render loop or operation spinner.
function Clear-Tui {
    Reset-TuiSurface
}

function Read-TuiPrompt {
    param(
        [string]$Prompt,
        [string]$Default = ''
    )

    Reset-TuiSurface

    try {
        [Console]::CursorVisible = $true
        [Console]::ForegroundColor = [ConsoleColor]::White
        [Console]::BackgroundColor = [ConsoleColor]::Black
    }
    catch {}

    if ($Default) {
        $value = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = $Default
        }
    }
    else {
        $value = Read-Host $Prompt
    }

    try { [Console]::CursorVisible = $false } catch {}
    $script:LastFrame = @()

    return $value
}

function Confirm-Tui {
    param([string]$Prompt)

    $value = Read-TuiPrompt "$Prompt (y/N)"
    return $value -match '^(?i:y|yes)$'
}

function Show-TuiMessage {
    param(
        [string]$Title,
        [string[]]$Lines,
        [ConsoleColor]$Color = [ConsoleColor]::White
    )

    Reset-TuiSurface
    Begin-TuiFrame

    $width = Get-SafeWidth

    Write-TuiLine (Fit-Text " Windows Restore Manager TUI 3.2.7 - $Title " $width) Black Cyan
    Write-TuiLine ''

    foreach ($line in $Lines) {
        Write-TuiLine (Fit-Text $line $width) $Color
    }

    Write-TuiLine ''
    Write-TuiLine 'Press any key to continue...' DarkGray

    Flush-TuiFrame

    [void][Console]::ReadKey($true)
    $script:LastFrame = @()
}

# ---------------------------------------------------------------------------
# Process / CLI transport
# ---------------------------------------------------------------------------
function ConvertTo-WindowsArgument {
    param([string]$Value)

    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0

    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $slashes++
            continue
        }

        if ($ch -eq '"') {
            [void]$sb.Append((('\' * ($slashes * 2 + 1)) -join ''))
            [void]$sb.Append('"')
            $slashes = 0
            continue
        }

        if ($slashes -gt 0) {
            [void]$sb.Append((('\' * $slashes) -join ''))
            $slashes = 0
        }
        [void]$sb.Append($ch)
    }

    if ($slashes -gt 0) {
        [void]$sb.Append((('\' * ($slashes * 2)) -join ''))
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function New-CliProcessInfo {
    param([string[]]$Arguments)

    $allArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $script:Cli
    ) + $Arguments + @(
        '-Catalog', $script:Catalog,
        '-Json'
    )

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $script:WindowsPowerShell
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.Arguments = (($allArgs | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' ')
    return $psi
}

function Stop-ProcessTree {
    param([int]$Id)
    try {
        & taskkill.exe /PID $Id /T /F *> $null
    }
    catch {}
}

function Draw-OperationScreen {
    param(
        [string]$Title,
        [string]$Detail,
        [int]$Frame,
        [TimeSpan]$Elapsed
    )

    $spinner = @('|','/','-','\')[$Frame % 4]
    $width = Get-SafeWidth

    Begin-TuiFrame

    Write-TuiLine (Fit-Text ' Windows Restore Manager TUI 3.2.7 - operation ' $width) Black Cyan
    Write-TuiLine ''
    Write-TuiLine (Fit-Text ("  {0} {1}" -f $spinner, $Title) $width) Cyan
    Write-TuiLine ''

    if ($Detail) {
        Write-TuiLine (Fit-Text ("  " + $Detail) $width) Gray
    }
    else {
        Write-TuiLine ''
    }

    Write-TuiLine (Fit-Text ("  Elapsed: {0:hh\:mm\:ss}" -f $Elapsed) $width) DarkGray
    Write-TuiLine ''
    Write-TuiLine (Fit-Text '  ESC = cancel operation' $width) Yellow

    Flush-TuiFrame
}

function Invoke-CliTui {
    param(
        [string[]]$Arguments,
        [string]$Title = 'Working',
        [string]$Detail = ''
    )

    Clear-TuiNavigationBacklog

    $psi = New-CliProcessInfo $Arguments
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi

    if (-not $process.Start()) {
        throw 'Failed to start CLI backend.'
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $frame = 0
    $cancelled = $false

    try {
        while (-not $process.HasExited) {
            Draw-OperationScreen -Title $Title -Detail $Detail -Frame $frame -Elapsed $sw.Elapsed
            $frame++

            $until = [DateTime]::UtcNow.AddMilliseconds(120)
            while ([DateTime]::UtcNow -lt $until -and -not $process.HasExited) {
                $key = Get-TuiInputKey

                if ($null -ne $key -and $key.Key -eq [ConsoleKey]::Escape) {
                    $cancelled = $true
                    Stop-ProcessTree $process.Id
                    break
                }

                Start-Sleep -Milliseconds 20
            }

            if ($cancelled) { break }
        }

        if (-not $process.HasExited) {
            try { $process.WaitForExit(3000) | Out-Null } catch {}
        }
        else {
            $process.WaitForExit()
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        if ($cancelled) {
            return [pscustomobject]@{
                Cancelled = $true
                Response = $null
                Stderr = $stderr
            }
        }

        if ([string]::IsNullOrWhiteSpace($stdout)) {
            throw "CLI returned no JSON. Exit code: $($process.ExitCode)`n$stderr"
        }

        try {
            $response = $stdout | ConvertFrom-Json
        }
        catch {
            # Defensive fallback if an old host writes a banner to stdout.
            $start = $stdout.IndexOf('{')
            $end = $stdout.LastIndexOf('}')
            if ($start -ge 0 -and $end -gt $start) {
                $candidate = $stdout.Substring($start, $end - $start + 1)
                try { $response = $candidate | ConvertFrom-Json }
                catch { throw "CLI returned invalid JSON.`nSTDOUT:`n$stdout`nSTDERR:`n$stderr" }
            }
            else {
                throw "CLI returned invalid JSON.`nSTDOUT:`n$stdout`nSTDERR:`n$stderr"
            }
        }

        if (-not $response.ok) {
            throw [string]$response.error
        }

        return [pscustomobject]@{
            Cancelled = $false
            Response = $response
            Stderr = $stderr
        }
    }
    finally {
        $sw.Stop()
        $process.Dispose()
    }
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:Tabs = @('Applications','System','Profiles','Settings')
$script:TabIndex = 0
$script:Cursor = 0
$script:Offset = 0
$script:Search = ''
$script:Group = 'All'
$script:Scope = 'Auto'
$script:StatusMessage = if ($script:IsAdmin) {
    'Elevated: User-scope WinGet apps cannot be uninstalled. Use normal PowerShell for app management.'
}
else {
    'Ready'
}
$script:SelectedApps = @{}
$script:SelectedSystem = @{}
$script:Apps = @()
$script:SystemItems = @()
$script:Settings = @()
$script:Profiles = @()
$script:ProfilePlanCache = @{}

function Refresh-Profiles {
    $items = @()
    $default = Join-Path $script:Root 'config\install.conf'
    if (Test-Path -LiteralPath $default) {
        $items += [pscustomobject]@{ Name='install.conf'; Path=$default; Kind='Default' }
    }
    $profileDir = Join-Path $script:Root 'config\profiles'
    if (Test-Path -LiteralPath $profileDir) {
        foreach ($file in (Get-ChildItem -LiteralPath $profileDir -Filter '*.conf' -File | Sort-Object Name)) {
            $items += [pscustomobject]@{ Name=$file.Name; Path=$file.FullName; Kind='Profile' }
        }
    }
    $script:Profiles = @($items)
}

function Refresh-Apps {
    $result = Invoke-CliTui @('apps','list') 'Scanning applications' 'WinGet / Chocolatey / portable inventory'
    if ($result.Cancelled) {
        $script:StatusMessage = 'Application scan cancelled.'
        return
    }
    $script:Apps = @($result.Response.data)
    $script:StatusMessage = "Applications refreshed: $($script:Apps.Count) catalog entries."
}

function Refresh-System {
    $result = Invoke-CliTui @('system','list') 'Scanning Windows components' 'OpenSSH / WSL / Hyper-V / optional features'
    if ($result.Cancelled) {
        $script:StatusMessage = 'System scan cancelled.'
        return
    }
    $script:SystemItems = @($result.Response.data)
    $script:StatusMessage = 'Windows component state refreshed.'
}

function Refresh-Settings {
    $result = Invoke-CliTui @('settings','list') 'Reading Windows settings' ''
    if ($result.Cancelled) {
        $script:StatusMessage = 'Settings scan cancelled.'
        return
    }
    $script:Settings = @($result.Response.data)
    $script:StatusMessage = 'System settings refreshed.'
}

function Refresh-CurrentTab {
    switch ($script:Tabs[$script:TabIndex]) {
        'Applications' { Refresh-Apps }
        'System' { Refresh-System }
        'Profiles' { Refresh-Profiles; $script:StatusMessage='Profiles refreshed.' }
        'Settings' { Refresh-Settings }
    }
    $script:Cursor = 0
    $script:Offset = 0
}

function Get-AppGroups {
    return @('All') + @($script:Apps | ForEach-Object { [string]$_.group } | Sort-Object -Unique)
}

function Get-VisibleApps {
    $items = @($script:Apps)
    if ($script:Group -ne 'All') {
        $items = @($items | Where-Object { $_.group -eq $script:Group })
    }
    if (-not [string]::IsNullOrWhiteSpace($script:Search)) {
        $q = $script:Search.ToLowerInvariant()
        $items = @($items | Where-Object {
            ([string]$_.name).ToLowerInvariant().Contains($q) -or
            ([string]$_.key).ToLowerInvariant().Contains($q) -or
            ([string]$_.group).ToLowerInvariant().Contains($q) -or
            ([string]$_.sources).ToLowerInvariant().Contains($q) -or
            ([string]$_.location).ToLowerInvariant().Contains($q)
        })
    }
    return @($items)
}

function Get-CurrentItems {
    switch ($script:Tabs[$script:TabIndex]) {
        'Applications' { return @(Get-VisibleApps) }
        'System' { return @($script:SystemItems) }
        'Profiles' { return @($script:Profiles) }
        'Settings' { return @($script:Settings) }
    }
    return @()
}

function Clamp-Cursor {
    param([array]$Items, [int]$PageSize)
    if ($Items.Count -le 0) {
        $script:Cursor = 0; $script:Offset = 0; return
    }
    if ($script:Cursor -lt 0) { $script:Cursor = 0 }
    if ($script:Cursor -ge $Items.Count) { $script:Cursor = $Items.Count - 1 }
    if ($script:Cursor -lt $script:Offset) { $script:Offset = $script:Cursor }
    if ($script:Cursor -ge ($script:Offset + $PageSize)) { $script:Offset = $script:Cursor - $PageSize + 1 }
    if ($script:Offset -lt 0) { $script:Offset = 0 }
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
function Draw-Header {
    $width = Get-SafeWidth
    $tabText = @()
    for ($i=0; $i -lt $script:Tabs.Count; $i++) {
        if ($i -eq $script:TabIndex) { $tabText += "[$($script:Tabs[$i])]" }
        else { $tabText += " $($script:Tabs[$i]) " }
    }
    $adminText = if ($script:IsAdmin) { 'Admin' } else { 'Standard' }
    Write-TuiLine (Fit-Text " Windows Restore Manager TUI 3.2.7 | $adminText | RestoreCli.ps1 " $width) Black Cyan
    Write-TuiLine (Fit-Text (" " + ($tabText -join '  ')) $width) White DarkBlue
}

function Draw-Apps {
    $width = Get-SafeWidth
    $height = Get-SafeHeight
    $items = @(Get-VisibleApps)
    $pageSize = [Math]::Max(1, $height - 9)
    Clamp-Cursor $items $pageSize

    $scopeSearch = "Group: $($script:Group) | Search: $(if ($script:Search) { $script:Search } else { '-' }) | Scope: $($script:Scope) | Selected: $($script:SelectedApps.Count)"
    Write-TuiLine (Fit-Text (" " + $scopeSearch) $width) DarkGray

    $groupW = [Math]::Min(18, [Math]::Max(10, [int]($width * .14)))
    $nameW = [Math]::Min(28, [Math]::Max(18, [int]($width * .20)))
    $statusW = 13
    $viaW = 12
    $scopeW = 9
    $pathW = $width - ($groupW + $nameW + $statusW + $viaW + $scopeW + 12)
    if ($pathW -lt 12) { $pathW = 12 }

    $header = Join-TuiColumns `
        -Values @('', 'GROUP', 'APPLICATION', 'STATUS', 'VIA', 'SCOPE', 'LOCATION') `
        -Widths @(3, $groupW, $nameW, $statusW, $viaW, $scopeW, $pathW)
    Write-TuiLine (Fit-Text $header $width) Black Gray

    for ($row=0; $row -lt $pageSize; $row++) {
        $index = $script:Offset + $row
        if ($index -ge $items.Count) { Write-TuiLine (Fit-Text '' $width); continue }
        $item = $items[$index]
        $selected = $script:SelectedApps.ContainsKey(([string]$item.key).ToLowerInvariant())
        $mark = if ($selected) { '[x]' } else { '[ ]' }
        $status = [string]$item.status
        $line = Join-TuiColumns `
            -Values @(
                $mark,
                [string]$item.group,
                [string]$item.name,
                $status,
                [string]$item.installedVia,
                [string]$item.scope,
                [string]$item.location
            ) `
            -Widths @(3, $groupW, $nameW, $statusW, $viaW, $scopeW, $pathW)

        $fg = if ($status -eq 'Installed') { [ConsoleColor]::Green } else { [ConsoleColor]::Gray }
        if ($index -eq $script:Cursor) {
            Write-TuiLine (Fit-Text $line $width) Black Cyan
        } else {
            Write-TuiLine (Fit-Text $line $width) $fg Black
        }
    }

    Write-TuiLine (Fit-Text " $($script:Cursor + 1)/$($items.Count)  [Space] select  [I] install  [U] uninstall  [G] upgrade  [M] missing  [C] clear  [/] search  [F] group  [O] scope" $width) DarkCyan
}

function Draw-System {
    $width = Get-SafeWidth
    $height = Get-SafeHeight
    $items = @($script:SystemItems)
    $pageSize = [Math]::Max(1, $height - 8)
    Clamp-Cursor $items $pageSize
    Write-TuiLine (Fit-Text " Selected: $($script:SelectedSystem.Count)" $width) DarkGray
    Write-TuiLine (Fit-Text '     KEY          COMPONENT                         STATUS          DESCRIPTION' $width) Black Gray
    for ($row=0; $row -lt $pageSize; $row++) {
        $index=$script:Offset+$row
        if ($index -ge $items.Count) { Write-TuiLine (Fit-Text '' $width); continue }
        $item=$items[$index]
        $selected=$script:SelectedSystem.ContainsKey(([string]$item.key).ToLowerInvariant())
        $mark=if($selected){'[x]'}else{'[ ]'}
        $line=" $mark $(Fit-Text $item.key 12) $(Fit-Text $item.name 32) $(Fit-Text $item.status 15) $(Fit-Text $item.description ([Math]::Max(1,$width-70)))"
        if ($index -eq $script:Cursor) { Write-TuiLine (Fit-Text $line $width) Black Cyan }
        else { Write-TuiLine (Fit-Text $line $width) Gray Black }
    }
    Write-TuiLine (Fit-Text ' [Space] select  [E] enable  [D] disable  [C] clear  [R] refresh' $width) DarkCyan
}

function Draw-Profiles {
    $width=Get-SafeWidth; $height=Get-SafeHeight
    $items=@($script:Profiles); $pageSize=[Math]::Max(1,$height-8)
    Clamp-Cursor $items $pageSize
    Write-TuiLine (Fit-Text ' Profiles are declarative install/uninstall/system plans.' $width) DarkGray
    Write-TuiLine (Fit-Text '     TYPE        PROFILE                         PATH' $width) Black Gray
    for($row=0;$row -lt $pageSize;$row++){
        $index=$script:Offset+$row
        if($index -ge $items.Count){Write-TuiLine (Fit-Text '' $width);continue}
        $item=$items[$index]
        $line="     $(Fit-Text $item.Kind 10) $(Fit-Text $item.Name 30) $(Fit-Text $item.Path ([Math]::Max(1,$width-50)))"
        if($index -eq $script:Cursor){Write-TuiLine (Fit-Text $line $width) Black Cyan}else{Write-TuiLine (Fit-Text $line $width) Gray Black}
    }
    Write-TuiLine (Fit-Text ' [Enter] plan  [X] execute profile  [R] refresh' $width) DarkCyan
}

function Draw-Settings {
    $width=Get-SafeWidth; $height=Get-SafeHeight
    $items=@($script:Settings); $pageSize=[Math]::Max(1,$height-8)
    Clamp-Cursor $items $pageSize
    Write-TuiLine (Fit-Text ' Named settings only; config cannot execute arbitrary PowerShell.' $width) DarkGray
    Write-TuiLine (Fit-Text '     SETTING                         VALUE               DESCRIPTION' $width) Black Gray
    for($row=0;$row -lt $pageSize;$row++){
        $index=$script:Offset+$row
        if($index -ge $items.Count){Write-TuiLine (Fit-Text '' $width);continue}
        $item=$items[$index]
        $line="     $(Fit-Text $item.key 30) $(Fit-Text $item.value 20) $(Fit-Text $item.description ([Math]::Max(1,$width-58)))"
        if($index -eq $script:Cursor){Write-TuiLine (Fit-Text $line $width) Black Cyan}else{Write-TuiLine (Fit-Text $line $width) Gray Black}
    }
    Write-TuiLine (Fit-Text ' [Enter] edit selected setting  [R] refresh' $width) DarkCyan
}

function Draw-Footer {
    $width = Get-SafeWidth
    Write-TuiLine (Fit-Text (" " + $script:StatusMessage) $width) Yellow DarkBlue
    Write-TuiLine (Fit-Text ' [Tab] next view  [Shift+Tab] previous  [Arrows/PgUp/PgDn] navigate  [R] refresh  [Q] quit' $width) DarkGray
}

function Draw-Tui {
    Begin-TuiFrame
    Draw-Header

    switch ($script:Tabs[$script:TabIndex]) {
        'Applications' { Draw-Apps }
        'System' { Draw-System }
        'Profiles' { Draw-Profiles }
        'Settings' { Draw-Settings }
    }

    Draw-Footer
    Flush-TuiFrame
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
function Toggle-CurrentSelection {
    $items=@(Get-CurrentItems)
    if($items.Count -eq 0){return}
    $item=$items[$script:Cursor]
    switch($script:Tabs[$script:TabIndex]){
        'Applications' {
            $k=([string]$item.key).ToLowerInvariant()
            if($script:SelectedApps.ContainsKey($k)){$script:SelectedApps.Remove($k)}else{$script:SelectedApps[$k]=$true}
        }
        'System' {
            $k=([string]$item.key).ToLowerInvariant()
            if($script:SelectedSystem.ContainsKey($k)){$script:SelectedSystem.Remove($k)}else{$script:SelectedSystem[$k]=$true}
        }
    }
}

function Get-SelectedAppKeys {
    return @($script:SelectedApps.Keys | ForEach-Object { [string]$_ })
}

function Get-SelectedSystemKeys {
    return @($script:SelectedSystem.Keys | ForEach-Object { [string]$_ })
}

function Install-SelectedApps {
    $keys=@(Get-SelectedAppKeys)
    if($keys.Count -eq 0){$script:StatusMessage='No applications selected.';return}
    $current=@(Get-VisibleApps)
    $missing=@($script:Apps | Where-Object { $script:SelectedApps.ContainsKey(([string]$_.key).ToLowerInvariant()) -and $_.status -ne 'Installed' } | ForEach-Object {[string]$_.key})
    $skipped=$keys.Count-$missing.Count
    if($missing.Count -eq 0){$script:StatusMessage='All selected applications are already installed.';return}
    $prompt="Install $($missing.Count) application(s) using scope $($script:Scope)?"
    if($skipped -gt 0){$prompt+=" $skipped installed item(s) will be skipped."}
    if(-not (Confirm-Tui $prompt)){$script:StatusMessage='Install cancelled.';return}
    $args=@('apps','install',($missing -join ','),'-Scope',$script:Scope,'-Yes')
    $result=Invoke-CliTui $args 'Installing applications' ($missing -join ', ')
    if($result.Cancelled){$script:StatusMessage='Install cancelled by user.';return}
    $script:StatusMessage='Install operation completed.'
    Refresh-Apps
}

function Uninstall-SelectedApps {
    $selectedKeys = @(Get-SelectedAppKeys)

    if ($selectedKeys.Count -eq 0) {
        $script:StatusMessage = 'No applications selected.'
        return
    }

    $installedKeys = @(
        $script:Apps |
            Where-Object {
                $key = ([string]$_.key).ToLowerInvariant()
                $script:SelectedApps.ContainsKey($key) -and $_.status -eq 'Installed'
            } |
            ForEach-Object { [string]$_.key }
    )

    $skippedCount = $selectedKeys.Count - $installedKeys.Count

    if ($installedKeys.Count -eq 0) {
        $script:StatusMessage = 'Selected applications are not installed.'
        return
    }

    $prompt = "Uninstall $($installedKeys.Count) installed application(s)?"
    if ($skippedCount -gt 0) {
        $prompt += " $skippedCount non-installed selection(s) will be skipped."
    }

    if (-not (Confirm-Tui $prompt)) {
        $script:StatusMessage = 'Uninstall cancelled.'
        return
    }

    $result = Invoke-CliTui `
        @('apps','uninstall',($installedKeys -join ','),'-Yes') `
        'Uninstalling applications' `
        ($installedKeys -join ', ')

    if ($result.Cancelled) {
        $script:StatusMessage = 'Uninstall cancelled by user.'
        return
    }

    $items = @($result.Response.data)
    $removed = @($items | Where-Object { $_.ok -and -not $_.skipped })
    $alreadyMissing = @($items | Where-Object { $_.ok -and $_.skipped })
    $failed = @($items | Where-Object { -not $_.ok })

    $script:SelectedApps = @{}
    Refresh-Apps

    if ($failed.Count -gt 0) {
        $failedText = ($failed | ForEach-Object {
            if ($_.reason) {
                "$($_.key): $($_.reason)"
            }
            else {
                [string]$_.key
            }
        }) -join '; '

        $script:StatusMessage = "Removed: $($removed.Count). Failed: $($failed.Count). $failedText"
        Show-TuiMessage `
            -Title 'Uninstall failed' `
            -Lines @(
                "Removed: $($removed.Count)"
                "Failed: $($failed.Count)"
                ''
                $failedText
                ''
                'See logs\restore-*.log for WinGet/Chocolatey output.'
            ) `
            -Color Yellow
        return
    }

    $script:StatusMessage = "Removed: $($removed.Count). Already absent: $($alreadyMissing.Count)."
}

function Upgrade-SelectedApps {
    $keys=@(Get-SelectedAppKeys)
    if($keys.Count -eq 0){$script:StatusMessage='No applications selected.';return}
    if(-not (Confirm-Tui "Upgrade $($keys.Count) selected application(s)?")){$script:StatusMessage='Upgrade cancelled.';return}
    $result=Invoke-CliTui @('apps','upgrade',($keys -join ','),'-Yes') 'Upgrading applications' ($keys -join ', ')
    if($result.Cancelled){$script:StatusMessage='Upgrade cancelled by user.';return}
    $script:StatusMessage='Upgrade operation completed.'
    Refresh-Apps
}

function Select-MissingApps {
    foreach($item in $script:Apps){
        if($item.status -ne 'Installed'){$script:SelectedApps[([string]$item.key).ToLowerInvariant()]=$true}
    }
    $script:StatusMessage="Selected missing applications: $($script:SelectedApps.Count)."
}

function Cycle-AppGroup {
    $groups=@(Get-AppGroups)
    $index=[Array]::IndexOf($groups,$script:Group)
    $index=($index+1)%$groups.Count
    $script:Group=$groups[$index]
    $script:Cursor=0;$script:Offset=0
}

function Cycle-Scope {
    $scopes=@('Auto','User','Machine')
    $index=[Array]::IndexOf($scopes,$script:Scope)
    $script:Scope=$scopes[($index+1)%$scopes.Count]
}

function Set-AppSearch {
    Clear-Tui; Draw-Header
    $value=Read-TuiPrompt 'Search (empty clears)' $script:Search
    $script:Search=$value
    $script:Cursor=0;$script:Offset=0
}

function Change-SystemComponents {
    param([bool]$Enable)
    $keys=@(Get-SelectedSystemKeys)
    if($keys.Count -eq 0){$script:StatusMessage='No Windows components selected.';return}
    $verb=if($Enable){'Enable'}else{'Disable'}
    if(-not (Confirm-Tui "$verb $($keys.Count) Windows component(s)?")){$script:StatusMessage="$verb cancelled.";return}
    $action=if($Enable){'enable'}else{'disable'}
    $result=Invoke-CliTui @('system',$action,($keys -join ','),'-Yes') "$verb Windows components" ($keys -join ', ')
    if($result.Cancelled){$script:StatusMessage="$verb cancelled by user.";return}
    $script:SelectedSystem=@{}
    Refresh-System
}

function Show-ProfilePlan {
    $items=@($script:Profiles);if($items.Count -eq 0){return}
    $item=$items[$script:Cursor]
    $result=Invoke-CliTui @('profile','plan','-Config',[string]$item.Path) 'Reading profile plan' $item.Name
    if($result.Cancelled){return}
    $text=[string]$result.Response.data.text
    $lines=@($text -split "`r?`n")
    Clear-Tui
    $width=Get-SafeWidth;$height=Get-SafeHeight
    Write-TuiLine (Fit-Text " Profile plan: $($item.Name) " $width) Black Cyan
    $max=[Math]::Max(1,$height-4)
    for($i=0;$i -lt [Math]::Min($lines.Count,$max);$i++){Write-TuiLine (Fit-Text $lines[$i] $width) Gray}
    if($lines.Count -gt $max){Write-TuiLine (Fit-Text "... plan truncated in preview ($($lines.Count) lines)" $width) Yellow}
    Write-TuiLine 'Press any key to return...' DarkGray
    [void][Console]::ReadKey($true)
}

function Execute-CurrentProfile {
    $items=@($script:Profiles);if($items.Count -eq 0){return}
    $item=$items[$script:Cursor]
    if(-not (Confirm-Tui "Execute profile '$($item.Name)'?")){$script:StatusMessage='Profile execution cancelled.';return}
    $result=Invoke-CliTui @('profile','run','-Config',[string]$item.Path,'-Yes') 'Executing profile' $item.Name
    if($result.Cancelled){$script:StatusMessage='Profile execution cancelled by user.';return}
    $script:StatusMessage="Profile completed: $($item.Name)."
}

function Edit-CurrentSetting {
    $items=@($script:Settings);if($items.Count -eq 0){return}
    $item=$items[$script:Cursor]
    Clear-Tui;Draw-Header
    $value=Read-TuiPrompt "New value for $($item.key)" ([string]$item.value)
    if([string]::IsNullOrWhiteSpace($value)){$script:StatusMessage='Setting change cancelled.';return}
    if(-not (Confirm-Tui "Set $($item.key)=$value?")){$script:StatusMessage='Setting change cancelled.';return}
    $result=Invoke-CliTui @('settings','set','-Key',[string]$item.key,'-Value',$value,'-Yes') 'Applying Windows setting' "$($item.key)=$value"
    if($result.Cancelled){$script:StatusMessage='Setting operation cancelled by user.';return}
    Refresh-Settings
}

# ---------------------------------------------------------------------------
# Input queue
# ---------------------------------------------------------------------------
$script:PendingInputKey = $null

function Test-TuiNavigationKey {
    param([ConsoleKeyInfo]$KeyInfo)

    return $KeyInfo.Key -in @(
        [ConsoleKey]::UpArrow,
        [ConsoleKey]::DownArrow,
        [ConsoleKey]::PageUp,
        [ConsoleKey]::PageDown,
        [ConsoleKey]::Home,
        [ConsoleKey]::End
    )
}

function Get-TuiInputKey {
    # Never block the renderer waiting for input. The main loop calls this on
    # every tick and receives $null when the console input queue is empty.
    if ($null -ne $script:PendingInputKey) {
        $key = $script:PendingInputKey
        $script:PendingInputKey = $null
        return $key
    }

    if (-not [Console]::KeyAvailable) {
        return $null
    }

    $key = [Console]::ReadKey($true)

    if (-not (Test-TuiNavigationKey $key)) {
        return $key
    }

    # Windows Console autorepeat can enqueue many identical arrow events while
    # the key is held. If rendering is slower than the repeat rate, those
    # events survive after key-up and the cursor keeps moving. Collapse only
    # already queued *identical navigation* events. Preserve the first different
    # key in PendingInputKey so normal commands are never swallowed.
    while ([Console]::KeyAvailable) {
        $next = [Console]::ReadKey($true)

        if ((Test-TuiNavigationKey $next) -and
            $next.Key -eq $key.Key -and
            $next.Modifiers -eq $key.Modifiers) {
            continue
        }

        $script:PendingInputKey = $next
        break
    }

    return $key
}

function Clear-TuiNavigationBacklog {
    # Used when entering/leaving modal screens or operations. Drain only
    # navigation autorepeat. Preserve the first non-navigation key.
    while ([Console]::KeyAvailable) {
        $next = [Console]::ReadKey($true)

        if (Test-TuiNavigationKey $next) {
            continue
        }

        $script:PendingInputKey = $next
        break
    }
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
try {
    [Console]::Title = 'Windows Restore Manager TUI 3.2.7 TUI'
    [Console]::TreatControlCAsInput = $true
    [Console]::CursorVisible = $false
    Refresh-Profiles
    Refresh-Apps

    $running=$true
    $needsRender=$true
    $lastWidth=Get-SafeWidth
    $lastHeight=Get-SafeHeight

    while($running){
        $currentWidth=Get-SafeWidth
        $currentHeight=Get-SafeHeight

        if($currentWidth -ne $lastWidth -or $currentHeight -ne $lastHeight){
            $lastWidth=$currentWidth
            $lastHeight=$currentHeight
            $needsRender=$true
        }

        if($needsRender){
            Draw-Tui
            $needsRender=$false
        }

        $key=Get-TuiInputKey
        if($null -eq $key){
            Start-Sleep -Milliseconds 8
            continue
        }

        $items=@(Get-CurrentItems)
        $height=Get-SafeHeight
        $page=[Math]::Max(1,$height-9)

        switch($key.Key){
            'Q' { $running=$false }
            'Tab' {
                if(($key.Modifiers -band [ConsoleModifiers]::Shift) -ne 0){
                    $script:TabIndex=($script:TabIndex-1+$script:Tabs.Count)%$script:Tabs.Count
                }else{
                    $script:TabIndex=($script:TabIndex+1)%$script:Tabs.Count
                }
                $script:Cursor=0;$script:Offset=0
                if($script:Tabs[$script:TabIndex] -eq 'System' -and $script:SystemItems.Count -eq 0){Refresh-System}
                if($script:Tabs[$script:TabIndex] -eq 'Settings' -and $script:Settings.Count -eq 0){Refresh-Settings}
                if($script:Tabs[$script:TabIndex] -eq 'Profiles'){Refresh-Profiles}
            }
            'UpArrow' { if($script:Cursor -gt 0){$script:Cursor--} }
            'DownArrow' { if($script:Cursor -lt ($items.Count-1)){$script:Cursor++} }
            'PageUp' { $script:Cursor=[Math]::Max(0,$script:Cursor-$page) }
            'PageDown' { $script:Cursor=[Math]::Min([Math]::Max(0,$items.Count-1),$script:Cursor+$page) }
            'Home' { $script:Cursor=0 }
            'End' { if($items.Count -gt 0){$script:Cursor=$items.Count-1} }
            'Spacebar' { Toggle-CurrentSelection }
            'R' { Refresh-CurrentTab }
            'Enter' {
                switch($script:Tabs[$script:TabIndex]){
                    'Applications' { Toggle-CurrentSelection }
                    'System' { Toggle-CurrentSelection }
                    'Profiles' { Show-ProfilePlan }
                    'Settings' { Edit-CurrentSetting }
                }
            }
            'I' { if($script:Tabs[$script:TabIndex] -eq 'Applications'){Install-SelectedApps} }
            'U' { if($script:Tabs[$script:TabIndex] -eq 'Applications'){Uninstall-SelectedApps} }
            'G' { if($script:Tabs[$script:TabIndex] -eq 'Applications'){Upgrade-SelectedApps} }
            'M' { if($script:Tabs[$script:TabIndex] -eq 'Applications'){Select-MissingApps} }
            'C' {
                if($script:Tabs[$script:TabIndex] -eq 'Applications'){$script:SelectedApps=@{};$script:StatusMessage='Application selection cleared.'}
                elseif($script:Tabs[$script:TabIndex] -eq 'System'){$script:SelectedSystem=@{};$script:StatusMessage='System selection cleared.'}
            }
            'F' { if($script:Tabs[$script:TabIndex] -eq 'Applications'){Cycle-AppGroup} }
            'O' { if($script:Tabs[$script:TabIndex] -eq 'Applications'){Cycle-Scope} }
            'Divide' { if($script:Tabs[$script:TabIndex] -eq 'Applications'){Set-AppSearch} }
            'Oem2' { if($script:Tabs[$script:TabIndex] -eq 'Applications'){Set-AppSearch} }
            'E' { if($script:Tabs[$script:TabIndex] -eq 'System'){Change-SystemComponents $true} }
            'D' { if($script:Tabs[$script:TabIndex] -eq 'System'){Change-SystemComponents $false} }
            'X' { if($script:Tabs[$script:TabIndex] -eq 'Profiles'){Execute-CurrentProfile} }
        }

        $needsRender=$true
    }
}
catch {
    $errorMessage = [string]$_.Exception.Message
    $stack = [string]$_.ScriptStackTrace
    $crashDir = Join-Path $script:Root 'logs'
    $crashFile = Join-Path $crashDir ("tui-crash-{0:yyyy-MM-dd_HH-mm-ss}.log" -f (Get-Date))

    try {
        if (-not (Test-Path -LiteralPath $crashDir)) {
            New-Item -ItemType Directory -Path $crashDir -Force | Out-Null
        }

        @(
            "Windows Restore Manager TUI 3.2.7"
            "Time: $((Get-Date).ToString('o'))"
            "PowerShell: $($PSVersionTable.PSVersion)"
            "Host: $($Host.Name)"
            "Script: $script:ScriptPath"
            "CLI: $script:Cli"
            "Catalog: $script:Catalog"
            ""
            "ERROR:"
            $errorMessage
            ""
            "STACK:"
            $stack
        ) | Set-Content -LiteralPath $crashFile -Encoding UTF8
    }
    catch {}

    Restore-ConsoleState
    Reset-TuiSurface

    Write-Host ''
    Write-Host 'Windows Restore Manager TUI crashed.' -ForegroundColor Red
    Write-Host ''
    Write-Host $errorMessage -ForegroundColor Yellow

    if (-not [string]::IsNullOrWhiteSpace($stack)) {
        Write-Host ''
        Write-Host $stack -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host "Crash log: $crashFile" -ForegroundColor Cyan
    Write-Host ''

    try { [Console]::CursorVisible = $true } catch {}
    [void](Read-Host 'Press Enter to exit')

    exit 1
}
finally {
    Restore-ConsoleState
}
