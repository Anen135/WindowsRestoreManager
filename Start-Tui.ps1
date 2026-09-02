# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Windows Restore Manager
#
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$launcherPath = [string]$MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($launcherPath)) {
    $launcherPath = [string]$PSCommandPath
}
if ([string]::IsNullOrWhiteSpace($launcherPath)) {
    throw 'Unable to determine the launcher path.'
}

$root = Split-Path -Parent ([IO.Path]::GetFullPath($launcherPath))
$entry = Join-Path $root 'tui\RestoreTui.ps1'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry

if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host "TUI exited with code $LASTEXITCODE." -ForegroundColor Red
}
