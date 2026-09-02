# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Windows Restore Manager
#
[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Command = 'help',
    [Parameter(Position=1)][string]$Action = '',
    [Parameter(Position=2)][string]$Target = '',

    [string]$Catalog,
    [string]$Config,
    [ValidateSet('Auto','User','Machine')][string]$Scope = 'Auto',
    [string]$Source,
    [string]$Key,
    [string]$Value,
    [switch]$Json,
    [switch]$Reinstall,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$script:CliScriptPath = [string]$MyInvocation.MyCommand.Path

if ([string]::IsNullOrWhiteSpace($script:CliScriptPath)) {
    $script:CliScriptPath = [string]$PSCommandPath
}

if ([string]::IsNullOrWhiteSpace($script:CliScriptPath)) {
    throw 'Unable to determine the path of RestoreCli.ps1.'
}

$script:CliScriptPath = [IO.Path]::GetFullPath($script:CliScriptPath)
$script:CliRoot = Split-Path -Parent $script:CliScriptPath

if ([string]::IsNullOrWhiteSpace($Catalog)) {
    $Catalog = Join-Path $script:CliRoot 'config\catalog.json'
}
elseif (-not [IO.Path]::IsPathRooted($Catalog)) {
    $Catalog = Join-Path (Get-Location).Path $Catalog
}

$Catalog = [IO.Path]::GetFullPath($Catalog)

# -Json is a strict machine-readable stdout contract. Suppress PowerShell
# auxiliary streams that could otherwise corrupt the JSON document.
if ($Json) {
    $WarningPreference = 'SilentlyContinue'
    $VerbosePreference = 'SilentlyContinue'
    $InformationPreference = 'SilentlyContinue'
    $ProgressPreference = 'SilentlyContinue'
}

$modulePath = Join-Path $script:CliRoot 'modules\RestoreManager.Core\RestoreManager.Core.psd1'

function Write-JsonResponse {
    param(
        [bool]$Ok,
        [string]$Operation,
        $Data,
        [string[]]$Warnings = @(),
        [string]$ErrorMessage
    )

    $response = [ordered]@{
        schemaVersion = 1
        ok = $Ok
        operation = $Operation
        timestamp = (Get-Date).ToString('o')
        data = $Data
        warnings = @($Warnings)
        error = $ErrorMessage
    }

    $response | ConvertTo-Json -Depth 12
}

function Write-Human {
    param($Data)

    if ($null -eq $Data) { return }

    if ($Data -is [string]) {
        Write-Host $Data
        return
    }

    if ($Data -is [System.Collections.IDictionary]) {
        $Data.GetEnumerator() | Format-Table -AutoSize | Out-Host
        return
    }

    $items = @($Data)
    if ($items.Count -eq 0) { return }

    $items | Format-Table -AutoSize | Out-Host
}

function Split-Targets {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    return @(
        $Text -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
}

function Require-Administrator {
    param([string]$Operation)

    if (Test-RestoreAdministrator) {
        return
    }

    throw "Administrator privileges are required for '$Operation'. Start PowerShell as Administrator, or use the WPF GUI launcher which elevates itself."
}

function Confirm-Operation {
    param(
        [string]$Prompt
    )

    if ($Yes) { return $true }
    if ($Json) {
        throw "Confirmation required. Repeat the command with -Yes."
    }

    $answer = Read-Host "$Prompt [y/N]"
    return $answer -match '^(?i:y|yes)$'
}

function Show-Help {
@'
Windows Restore Manager CLI 3.1.1

Syntax:
  .\RestoreCli.ps1 <command> <action> [target] [options]

Commands:

  doctor
      Environment/backend diagnostics.

  catalog list
      List catalog applications.

  catalog validate
      Validate catalog structure.

  apps list
      Scan all catalog applications.

  apps status <key[,key...]>
      Scan specific catalog applications.

  apps install <key[,key...]> [-Scope Auto|User|Machine] [-Source winget|choco] [-Reinstall] [-Yes]
      Install selected applications. Already-installed applications are skipped
      unless -Reinstall is specified.

  apps uninstall <key[,key...]> [-Source winget|choco] [-Yes]
      Uninstall selected applications.

  apps upgrade <key[,key...]> [-Source winget|choco] [-Yes]
      Upgrade selected applications.

  profile plan -Config .\install.conf
      Parse a profile and return its execution plan.

  profile run -Config .\install.conf [-Scope Auto|User|Machine] [-Reinstall] [-Yes]
      Execute a profile.

  system list
      List OpenSSH, WSL, Hyper-V, VMP, Telnet states.

  system enable <key[,key...]> [-Yes]
  system disable <key[,key...]> [-Yes]

  settings list
      List supported named Windows settings and their current values.

  settings set -Key <name> -Value <value> [-Yes]
      Set an allow-listed Windows setting.

Global:
  -Json        Stable machine-readable response envelope.
  -Catalog     Alternative catalog.json path.
  -Yes         Skip interactive confirmation for mutating operations.

Examples:
  .\RestoreCli.ps1 apps list
  .\RestoreCli.ps1 apps status vscode,blender -Json
  .\RestoreCli.ps1 apps install blender -Scope Machine -Yes
  .\RestoreCli.ps1 apps install vscode -Source choco -Yes
  .\RestoreCli.ps1 profile plan -Config .\config\install.conf -Json
  .\RestoreCli.ps1 profile run -Config .\config\install.conf -Yes
  .\RestoreCli.ps1 system enable SSHClient,WSL -Yes
'@
}

$operationName = (($Command + ' ' + $Action).Trim()).ToLowerInvariant()

try {
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw "Core module not found: $modulePath"
    }

    Import-Module $modulePath -Force -DisableNameChecking -WarningAction SilentlyContinue
    $null = Initialize-RestoreCore -CatalogPath $Catalog -BasePath $script:CliRoot

    $data = $null

    switch ($Command.ToLowerInvariant()) {
        'help' {
            $data = Show-Help
        }

        '--help' {
            $data = Show-Help
        }

        '-h' {
            $data = Show-Help
        }

        'doctor' {
            $data = Get-RestoreDoctor
        }

        'catalog' {
            switch ($Action.ToLowerInvariant()) {
                'list' {
                    $data = @(Get-RestoreCatalog)
                }
                'validate' {
                    $data = Test-RestoreCatalog
                }
                default {
                    throw "Unknown catalog action '$Action'. Use: list, validate."
                }
            }
        }

        'apps' {
            switch ($Action.ToLowerInvariant()) {
                'list' {
                    $data = @(Get-RestoreAppInventory)
                }

                'status' {
                    $targets = Split-Targets $Target
                    if ($targets.Count -eq 0) {
                        throw 'apps status requires at least one catalog key.'
                    }

                    $data = @(Get-RestoreAppInventory -Keys $targets)
                }

                'install' {
                    $targets = Split-Targets $Target
                    if ($targets.Count -eq 0) {
                        throw 'apps install requires at least one catalog key.'
                    }

                    if (-not (Confirm-Operation "Install $($targets.Count) application(s)?")) {
                        $data = @()
                        break
                    }

                    $results = @()

                    if ($Reinstall) {
                        foreach ($appKey in $targets) {
                            $results += Install-RestoreApplication `
                                -Key $appKey `
                                -Scope $Scope `
                                -Source $Source `
                                -Reinstall
                        }
                    }
                    else {
                        $inventory = @(Get-RestoreAppInventory -Keys $targets)
                        $stateByKey = @{}

                        foreach ($item in $inventory) {
                            $stateByKey[([string]$item.key).ToLowerInvariant()] = $item
                        }

                        foreach ($appKey in $targets) {
                            $stateKey = ([string]$appKey).ToLowerInvariant()

                            if ($stateByKey.ContainsKey($stateKey) -and $stateByKey[$stateKey].installed) {
                                $results += [pscustomobject]@{
                                    key = $appKey
                                    action = 'install'
                                    ok = $true
                                    skipped = $true
                                    reason = 'Already installed'
                                }
                                continue
                            }

                            # The batch inventory already performed the exact
                            # installed-state check, so bypass the per-item scan.
                            $results += Install-RestoreApplication `
                                -Key $appKey `
                                -Scope $Scope `
                                -Source $Source `
                                -Reinstall
                        }
                    }

                    $data = @($results)
                }

                'uninstall' {
                    $targets = Split-Targets $Target
                    if ($targets.Count -eq 0) {
                        throw 'apps uninstall requires at least one catalog key.'
                    }

                    if (-not (Confirm-Operation "Uninstall $($targets.Count) application(s)?")) {
                        $data = @()
                        break
                    }

                    $results = @()
                    foreach ($appKey in $targets) {
                        $results += Uninstall-RestoreApplication -Key $appKey -Source $Source
                    }
                    $data = @($results)
                }

                'upgrade' {
                    $targets = Split-Targets $Target
                    if ($targets.Count -eq 0) {
                        throw 'apps upgrade requires at least one catalog key.'
                    }

                    if (-not (Confirm-Operation "Upgrade $($targets.Count) application(s)?")) {
                        $data = @()
                        break
                    }

                    $results = @()
                    foreach ($appKey in $targets) {
                        $results += Upgrade-RestoreApplication -Key $appKey -Source $Source
                    }
                    $data = @($results)
                }

                default {
                    throw "Unknown apps action '$Action'. Use: list, status, install, uninstall, upgrade."
                }
            }
        }

        'profile' {
            if ([string]::IsNullOrWhiteSpace($Config)) {
                throw 'Profile command requires -Config <path>.'
            }

            switch ($Action.ToLowerInvariant()) {
                'plan' {
                    $data = Get-RestoreProfilePlan -Path $Config
                }

                'run' {
                    Require-Administrator 'profile run'

                    if (-not (Confirm-Operation "Execute profile '$Config'?")) {
                        $data = @()
                        break
                    }

                    $data = @(
                        Invoke-RestoreProfile `
                            -Path $Config `
                            -ScopeOverride $Scope `
                            -Reinstall:$Reinstall
                    )
                }

                default {
                    throw "Unknown profile action '$Action'. Use: plan, run."
                }
            }
        }

        'system' {
            switch ($Action.ToLowerInvariant()) {
                'list' {
                    $data = @(Get-RestoreSystemInventory)
                }

                'enable' {
                    Require-Administrator 'system enable'
                    $targets = Split-Targets $Target
                    if ($targets.Count -eq 0) {
                        throw 'system enable requires at least one component key.'
                    }

                    if (-not (Confirm-Operation "Enable $($targets.Count) Windows component(s)?")) {
                        $data = @()
                        break
                    }

                    $results = @()
                    foreach ($componentKey in $targets) {
                        $results += Set-RestoreSystemComponent -Key $componentKey -Enable $true
                    }
                    $data = @($results)
                }

                'disable' {
                    Require-Administrator 'system disable'
                    $targets = Split-Targets $Target
                    if ($targets.Count -eq 0) {
                        throw 'system disable requires at least one component key.'
                    }

                    if (-not (Confirm-Operation "Disable $($targets.Count) Windows component(s)?")) {
                        $data = @()
                        break
                    }

                    $results = @()
                    foreach ($componentKey in $targets) {
                        $results += Set-RestoreSystemComponent -Key $componentKey -Enable $false
                    }
                    $data = @($results)
                }

                default {
                    throw "Unknown system action '$Action'. Use: list, enable, disable."
                }
            }
        }

        'settings' {
            switch ($Action.ToLowerInvariant()) {
                'list' {
                    $data = @(Get-RestoreSettingsInventory)
                }

                'set' {
                    Require-Administrator 'settings set'

                    if ([string]::IsNullOrWhiteSpace($Key)) {
                        throw 'settings set requires -Key.'
                    }

                    if ($null -eq $Value) {
                        throw 'settings set requires -Value.'
                    }

                    if (-not (Confirm-Operation "Set $Key=$Value?")) {
                        $data = $null
                        break
                    }

                    $data = Set-RestoreSystemSetting -Key $Key -Value $Value
                }

                default {
                    throw "Unknown settings action '$Action'. Use: list, set."
                }
            }
        }

        default {
            throw "Unknown command '$Command'. Run '.\RestoreCli.ps1 help'."
        }
    }

    if ($Json) {
        Write-JsonResponse -Ok $true -Operation $operationName -Data $data
    }
    else {
        Write-Human $data
    }

    exit 0
}
catch {
    if ($Json) {
        Write-JsonResponse -Ok $false -Operation $operationName -Data $null -ErrorMessage $_.Exception.Message
    }
    else {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }

    exit 1
}
