# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Windows Restore Manager
#
$script:catalogData = $null
$script:catalogApps = @()
$script:CatalogPath = $null
$script:BasePath = $null
$script:portableRoot = Join-Path $env:LOCALAPPDATA 'Programs\PortableApps'
$script:logFile = $null

function Initialize-RestoreCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$CatalogPath,
        [string]$BasePath,
        [string]$LogPath
    )

    if ([string]::IsNullOrWhiteSpace($BasePath)) {
        $BasePath = Split-Path -Parent $CatalogPath
    }

    $script:BasePath = $BasePath
    $script:CatalogPath = (Resolve-Path -LiteralPath $CatalogPath -ErrorAction Stop).Path
    $script:catalogData = Load-Catalog $script:CatalogPath
    $script:catalogApps = @($script:catalogData.applications)

    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $logDir = Join-Path $BasePath 'logs'
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $LogPath = Join-Path $logDir ("restore-{0:yyyy-MM-dd_HH-mm-ss}.log" -f (Get-Date))
    }

    $script:logFile = $LogPath

    return [pscustomobject]@{
        CatalogPath = $script:CatalogPath
        ApplicationCount = $script:catalogApps.Count
        PortableRoot = $script:portableRoot
        LogPath = $script:logFile
    }
}

function Write-ManagerLog {
    param(
        [string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR')][string]$Level = 'INFO'
    )

    if ([string]::IsNullOrWhiteSpace($script:logFile)) {
        return
    }

    $line = "[{0:HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $script:logFile -Value $line -Encoding UTF8
}

function Assert-RestoreInitialized {
    if ($null -eq $script:catalogData) {
        throw 'RestoreManager.Core is not initialized. Call Initialize-RestoreCore first.'
    }
}

function Test-RestoreAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}


function Load-Catalog {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Catalog file not found: $Path"
    }

    try {
        $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse catalog JSON: $($_.Exception.Message)"
    }

    if (-not $data.applications) {
        throw "Catalog contains no 'applications' array."
    }

    $keys = @{}
    foreach ($app in $data.applications) {
        if ([string]::IsNullOrWhiteSpace([string]$app.key)) {
            throw 'Catalog contains an application without a key.'
        }

        $k = ([string]$app.key).ToLowerInvariant()
        if ($keys.ContainsKey($k)) {
            throw "Duplicate catalog key: $($app.key)"
        }
        $keys[$k] = $true

        if (-not $app.sources -or @($app.sources).Count -eq 0) {
            throw "Application '$($app.key)' has no sources."
        }
    }

    return $data
}



function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [switch]$Quiet
    )

    if (-not $Quiet) {
        Write-ManagerLog ("{0} {1}" -f $FilePath, ($Arguments -join ' '))
    }

    try {
        $output = & $FilePath @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    catch {
        return [pscustomobject]@{
            ExitCode = 9009
            Output = $_.Exception.Message
        }
    }

    if (-not $Quiet -and -not [string]::IsNullOrWhiteSpace($output)) {
        foreach ($line in ($output -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-ManagerLog $line
            }
        }
    }

    return [pscustomobject]@{
        ExitCode = $code
        Output = $output
    }
}



function Get-WingetPath {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}



function Get-ChocoPath {
    $cmd = Get-Command choco.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $known = Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'
    if (Test-Path -LiteralPath $known) { return $known }

    return $null
}



function Ensure-Chocolatey {
    param([bool]$AutoInstall = $true)

    $existing = Get-ChocoPath
    if ($existing) { return $existing }

    if (-not $AutoInstall) {
        Write-ManagerLog 'Chocolatey is not installed and automatic bootstrap is disabled.' 'WARN'
        return $null
    }

    $winget = Get-WingetPath
    if (-not $winget) {
        Write-ManagerLog 'Chocolatey is required, but WinGet is unavailable for automatic bootstrap.' 'ERROR'
        return $null
    }

    Write-ManagerLog 'Chocolatey is not installed. Bootstrapping Chocolatey through WinGet...' 'INFO'

    $result = Invoke-External $winget @(
        'install',
        '--id', 'chocolatey.chocolatey',
        '--source', 'winget',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )

    if ($result.ExitCode -ne 0) {
        Write-ManagerLog "Chocolatey bootstrap failed with exit code $($result.ExitCode)." 'ERROR'
        return $null
    }

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"

    $choco = Get-ChocoPath
    if (-not $choco) {
        Write-ManagerLog 'Chocolatey install completed, but choco.exe is not visible yet. A manager restart may be required.' 'WARN'
    }
    else {
        Write-ManagerLog "Chocolatey ready: $choco" 'OK'
    }

    return $choco
}



function Get-AppxInventory {
    # The Appx module is not reliably loadable from PowerShell 7.
    # Try the native cmdlet first; if it cannot be loaded, query it through
    # Windows PowerShell 5.1 and deserialize only the fields we need.
    try {
        $cmd = Get-Command Get-AppxPackage -ErrorAction SilentlyContinue

        if ($cmd) {
            try {
                return @(Get-AppxPackage -ErrorAction Stop | Select-Object Name, PackageFamilyName, InstallLocation)
            }
            catch {
                Write-ManagerLog "Native Get-AppxPackage is unavailable in this PowerShell host: $($_.Exception.Message)" 'WARN'
            }
        }

        $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

        if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
            Write-ManagerLog 'Windows PowerShell 5.1 was not found; AppX location detection will be skipped.' 'WARN'
            return @()
        }

        $command = @'
$ErrorActionPreference = "Stop"
Get-AppxPackage |
    Select-Object Name, PackageFamilyName, InstallLocation |
    ConvertTo-Json -Depth 3 -Compress
'@

        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

        $result = & $windowsPowerShell `
            -NoProfile `
            -NonInteractive `
            -ExecutionPolicy Bypass `
            -EncodedCommand $encoded 2>$null | Out-String

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($result)) {
            Write-ManagerLog 'AppX inventory could not be read through Windows PowerShell; continuing without it.' 'WARN'
            return @()
        }

        $parsed = $result | ConvertFrom-Json

        if ($null -eq $parsed) {
            return @()
        }

        return @($parsed)
    }
    catch {
        Write-ManagerLog "AppX inventory failed and will be skipped: $($_.Exception.Message)" 'WARN'
        return @()
    }
}



function Get-WingetInventoryText {
    param(
        [ValidateSet('','User','Machine')][string]$Scope = ''
    )

    $winget = Get-WingetPath
    if (-not $winget) { return '' }

    $args = @(
        'list',
        '--accept-source-agreements',
        '--disable-interactivity'
    )

    if ($Scope -eq 'User') {
        $args += @('--scope','user')
    }
    elseif ($Scope -eq 'Machine') {
        $args += @('--scope','machine')
    }

    $result = Invoke-External $winget $args -Quiet
    return $result.Output
}



function Get-WingetInventory {
    $map = @{}
    $winget = Get-WingetPath

    if (-not $winget) {
        return [pscustomobject]@{
            Packages = $map
            ListText = ''
        }
    }

    $tempFile = Join-Path $env:TEMP ("RestoreManager-winget-{0}.json" -f [guid]::NewGuid().ToString('N'))

    try {
        $result = Invoke-External $winget @(
            'export',
            '--output', $tempFile,
            '--include-versions',
            '--accept-source-agreements',
            '--disable-interactivity'
        ) -Quiet

        if (Test-Path -LiteralPath $tempFile) {
            try {
                $export = Get-Content -LiteralPath $tempFile -Raw -Encoding UTF8 | ConvertFrom-Json

                foreach ($source in @($export.Sources)) {
                    foreach ($package in @($source.Packages)) {
                        $id = [string]$package.PackageIdentifier

                        if (-not [string]::IsNullOrWhiteSpace($id)) {
                            $map[$id.ToLowerInvariant()] = [pscustomobject]@{
                                Id = $id
                                Version = [string]$package.Version
                                Source = [string]$source.SourceDetails.Name
                            }
                        }
                    }
                }
            }
            catch {
                Write-ManagerLog "Failed to parse WinGet export JSON: $($_.Exception.Message)" 'WARN'
            }
        }
        elseif ($result.ExitCode -ne 0) {
            Write-ManagerLog "WinGet export failed with exit code $($result.ExitCode); package status may be incomplete." 'WARN'
        }
    }
    finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }

    # PackageIdentifier comes from export JSON. Scope is classified using
    # WinGet's installed-package scope filters for those exact IDs.
    $userListText = Get-WingetInventoryText -Scope User
    $machineListText = Get-WingetInventoryText -Scope Machine
    $listText = ($userListText + [Environment]::NewLine + $machineListText)

    foreach ($key in @($map.Keys)) {
        $package = $map[$key]
        $id = [string]$package.Id

        $inUser = [bool](Get-WingetLineForId -Text $userListText -Id $id)
        $inMachine = [bool](Get-WingetLineForId -Text $machineListText -Id $id)

        $scope = if ($inUser -and $inMachine) {
            'Both'
        }
        elseif ($inUser) {
            'User'
        }
        elseif ($inMachine) {
            'Machine'
        }
        else {
            'Unknown'
        }

        $package | Add-Member -NotePropertyName Scope -NotePropertyValue $scope -Force
    }

    return [pscustomobject]@{
        Packages = $map
        ListText = $listText
        UserListText = $userListText
        MachineListText = $machineListText
    }
}



function Get-ChocoInventory {
    $choco = Get-ChocoPath
    if (-not $choco) { return @{} }

    $versionResult = Invoke-External $choco @('--version') -Quiet
    $major = 2

    if ($versionResult.Output -match '^\s*(\d+)\.') {
        $major = [int]$matches[1]
    }

    if ($major -ge 2) {
        $result = Invoke-External $choco @('list','--limit-output') -Quiet
    }
    else {
        $result = Invoke-External $choco @('list','--local-only','--limit-output') -Quiet
    }

    $map = @{}

    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match '^([^|]+)\|(.+)$') {
            $map[$matches[1].ToLowerInvariant()] = $matches[2]
        }
    }

    return $map
}



function Get-WingetLineForId {
    param(
        [string]$Text,
        [string]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $escaped = [Regex]::Escape($Id)

    # WinGet list is a human-readable table. Package ID is the most stable
    # field, so locate the exact ID and capture the first token after it as
    # the installed version.
    $match = [Regex]::Match(
        $Text,
        "(?mi)^(?<name>.*?)\s+$escaped\s+(?<tail>.+)$"
    )

    if (-not $match.Success) { return $null }

    $tail = $match.Groups['tail'].Value.Trim()
    $parts = @($tail -split '\s+')

    return [pscustomobject]@{
        Name = $match.Groups['name'].Value.Trim()
        Version = $(if ($parts.Count -gt 0) { $parts[0] } else { '' })
        Raw = $match.Value.Trim()
    }
}



function Get-ArpEntries {
    $result = @()

    $roots = @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'User' },
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine' },
        @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine' }
    )

    foreach ($root in $roots) {
        foreach ($entry in (Get-ItemProperty $root.Path -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.DisplayName)) { continue }

            $result += [pscustomobject]@{
                DisplayName = [string]$entry.DisplayName
                DisplayVersion = [string]$entry.DisplayVersion
                InstallLocation = [string]$entry.InstallLocation
                DisplayIcon = [string]$entry.DisplayIcon
                UninstallString = [string]$entry.UninstallString
                QuietUninstallString = [string]$entry.QuietUninstallString
                Scope = $root.Scope
            }
        }
    }

    return @($result)
}





function Get-DirectoryFromCommand {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $candidate = $null

    if ($Text -match '^\s*"([^"]+)"') {
        $candidate = $matches[1]
    }
    elseif ($Text -match '^\s*([^\s,]+\.exe)') {
        $candidate = $matches[1]
    }

    if (-not $candidate) { return $null }

    $candidate = [Environment]::ExpandEnvironmentVariables($candidate)

    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Split-Path -Parent $candidate)
    }

    return $null
}



function Get-DeclaredRegistryNames {
    param($App)

    if (-not ($App.PSObject.Properties.Name -contains 'registryNames')) {
        return @()
    }

    return @(
        $App.registryNames |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
}


function Find-ArpEntry {
    param(
        [array]$Entries,
        [string[]]$DeclaredNames
    )

    $names = @(
        $DeclaredNames |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    if ($names.Count -eq 0) {
        return $null
    }

    # STRICT MATCH ONLY:
    # - no Contains()
    # - no wildcards
    # - no fuzzy/Levenshtein matching
    # - no punctuation/word normalization
    # - catalog App.name is NOT implicitly trusted
    # Only DisplayName values explicitly listed in registryNames may match.
    foreach ($declaredName in $names) {
        $matches = @(
            $Entries |
                Where-Object {
                    ([string]$_.DisplayName).Trim() -ieq $declaredName
                }
        )

        if ($matches.Count -eq 1) {
            return $matches[0]
        }

        if ($matches.Count -gt 1) {
            # Same exact DisplayName can exist in HKCU/HKLM. Prefer the entry
            # whose declared installation location exists; otherwise keep the
            # first exact match. This never changes which name was matched.
            foreach ($entry in $matches) {
                if (-not [string]::IsNullOrWhiteSpace([string]$entry.InstallLocation)) {
                    $path = [Environment]::ExpandEnvironmentVariables(([string]$entry.InstallLocation).Trim('"'))
                    if (Test-Path -LiteralPath $path) {
                        return $entry
                    }
                }
            }

            return $matches[0]
        }
    }

    return $null
}


function Get-AppInstallLocation {
    param(
        $App,
        [array]$ArpEntries,
        [array]$AppxEntries,
        [string]$DetectedName
    )

    $portablePath = Join-Path $portableRoot (($App.key -replace '[^\w\.\-]','_'))
    if (Test-Path (Join-Path $portablePath '.restore-installed')) {
        return [pscustomobject]@{ Path = $portablePath; Scope = 'User'; Source = 'Portable' }
    }

    # AppX matching is only attempted when the catalog explicitly provides
    # an AppX package name. WinGet IDs are not assumed to equal AppX names.
    $appxNames = @()
    if ($App.PSObject.Properties.Name -contains 'appxNames') {
        $appxNames = @($App.appxNames)
    }

    foreach ($appxName in $appxNames) {
        $match = @(
            $AppxEntries |
                Where-Object {
                    $_.Name -ieq $appxName -or
                    $_.PackageFamilyName -ieq $appxName
                } |
                Select-Object -First 1
        )

        if ($match.Count -gt 0 -and
            -not [string]::IsNullOrWhiteSpace([string]$match[0].InstallLocation) -and
            (Test-Path -LiteralPath ([string]$match[0].InstallLocation))) {
            return [pscustomobject]@{
                Path = [string]$match[0].InstallLocation
                Scope = 'User'
                Source = 'AppX/MSIX'
            }
        }
    }

    $declaredRegistryNames = @(Get-DeclaredRegistryNames -App $App)
    $arp = Find-ArpEntry -Entries $ArpEntries -DeclaredNames $declaredRegistryNames

    if ($arp) {
        if (-not [string]::IsNullOrWhiteSpace($arp.InstallLocation)) {
            $location = [Environment]::ExpandEnvironmentVariables($arp.InstallLocation.Trim('"'))

            if (Test-Path -LiteralPath $location) {
                return [pscustomobject]@{
                    Path = $location
                    Scope = $arp.Scope
                    Source = 'Registry'
                }
            }
        }

        $fromIcon = Get-DirectoryFromCommand $arp.DisplayIcon
        if ($fromIcon) {
            return [pscustomobject]@{
                Path = $fromIcon
                Scope = $arp.Scope
                Source = 'DisplayIcon'
            }
        }

        $fromUninstall = Get-DirectoryFromCommand $arp.UninstallString
        if ($fromUninstall) {
            return [pscustomobject]@{
                Path = $fromUninstall
                Scope = $arp.Scope
                Source = 'UninstallString'
            }
        }
    }

    return [pscustomobject]@{
        Path = 'Unknown'
        Scope = 'Unknown'
        Source = ''
    }
}



function Get-InstalledState {
    param(
        $App,
        [hashtable]$WingetPackages,
        [string]$WingetText,
        [hashtable]$ChocoInventory,
        [array]$ArpEntries,
        [array]$AppxEntries
    )

    # 1) Portable packages managed by this tool are deterministic.
    $portablePath = Join-Path $portableRoot (($App.key -replace '[^\w\.\-]','_'))
    if (Test-Path (Join-Path $portablePath '.restore-installed')) {
        return [pscustomobject]@{
            Installed = $true
            Version = ''
            Via = 'Portable'
            Name = $App.name
            Location = $portablePath
            Scope = 'User'
        }
    }

    # 2) Exact Chocolatey package ID.
    foreach ($source in @($App.sources)) {
        if ($source.type -eq 'choco' -and $source.id) {
            $key = ([string]$source.id).ToLowerInvariant()

            if ($ChocoInventory.ContainsKey($key)) {
                $location = Get-AppInstallLocation `
                    -App $App `
                    -ArpEntries $ArpEntries `
                    -AppxEntries $AppxEntries `
                    -DetectedName ([string]$App.name)

                return [pscustomobject]@{
                    Installed = $true
                    Version = [string]$ChocoInventory[$key]
                    Via = 'Chocolatey'
                    Name = $App.name
                    Location = $location.Path
                    Scope = $location.Scope
                }
            }
        }
    }

    # 3) Exact WinGet PackageIdentifier from winget export JSON.
    foreach ($source in @($App.sources)) {
        if ($source.type -eq 'winget' -and $source.id) {
            $key = ([string]$source.id).ToLowerInvariant()

            if ($WingetPackages.ContainsKey($key)) {
                $package = $WingetPackages[$key]

                # Recover display name from winget list only after the package
                # ID has already matched exactly. The list table no longer
                # decides Installed/Not installed.
                $line = Get-WingetLineForId -Text $WingetText -Id ([string]$source.id)
                $detectedName = if ($line -and $line.Name) {
                    [string]$line.Name
                }
                else {
                    [string]$App.name
                }

                $location = Get-AppInstallLocation `
                    -App $App `
                    -ArpEntries $ArpEntries `
                    -AppxEntries $AppxEntries `
                    -DetectedName $detectedName

                $exactScope = if ($package.PSObject.Properties.Name -contains 'Scope') {
                    [string]$package.Scope
                }
                else {
                    ''
                }

                return [pscustomobject]@{
                    Installed = $true
                    Version = [string]$package.Version
                    Via = 'WinGet'
                    Name = $detectedName
                    Location = $location.Path
                    Scope = $(if ($exactScope -and $exactScope -ne 'Unknown') { $exactScope } else { $location.Scope })
                }
            }
        }
    }

    # 4) Windows Installed Apps / Programs and Features fallback.
    # This is safe for managed apps because matching is allowed ONLY against
    # exact DisplayName values explicitly declared in catalog.registryNames.
    $declaredRegistryNames = @(Get-DeclaredRegistryNames -App $App)
    $arp = Find-ArpEntry -Entries $ArpEntries -DeclaredNames $declaredRegistryNames

    if ($arp) {
        $location = Get-AppInstallLocation `
            -App $App `
            -ArpEntries $ArpEntries `
            -AppxEntries $AppxEntries `
            -DetectedName ([string]$arp.DisplayName)

        return [pscustomobject]@{
            Installed = $true
            Version = [string]$arp.DisplayVersion
            Via = 'Registry'
            Name = [string]$arp.DisplayName
            Location = $location.Path
            Scope = [string]$arp.Scope
        }
    }

    return [pscustomobject]@{
        Installed = $false
        Version = ''
        Via = ''
        Name = $App.name
        Location = ''
        Scope = ''
    }
}



function Get-AppSourcesText {
    param($App)

    $parts = @()

    foreach ($source in @($App.sources) | Sort-Object { [int]$_.priority }) {
        switch ([string]$source.type) {
            'winget'   {
                $repo = $(if ($source.repository) { [string]$source.repository } else { 'winget' })
                $parts += "winget[$repo]:$($source.id)"
            }
            'choco'    {
                $repo = $(if ($source.repository) { [string]$source.repository } else { 'community' })
                $parts += "choco[$repo]:$($source.id)"
            }
            'portable' { $parts += 'portable' }
            'github'   {
                $release = $(if ($source.release) { [string]$source.release } else { 'latest' })
                $asset = $(if ($source.assetPattern) { [string]$source.assetPattern } elseif ($source.assetRegex) { [string]$source.assetRegex } else { '*' })
                $parts += "github:$($source.repo)@${release}:${asset}"
            }
            'manual'   { $parts += 'manual/web' }
            default    { $parts += [string]$source.type }
        }
    }

    return ($parts -join ' -> ')
}



function Find-CatalogApp {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }

    $direct = @($catalogApps | Where-Object { $_.key -ieq $Token } | Select-Object -First 1)
    if ($direct.Count -gt 0) { return $direct[0] }

    foreach ($app in $catalogApps) {
        foreach ($source in @($app.sources)) {
            if ($source.id -and ([string]$source.id -ieq $Token)) {
                return $app
            }
        }
    }

    return $null
}



function New-AdHocApp {
    param(
        [string]$Token,
        $OverrideSource
    )

    $source = $null

    if ($OverrideSource) {
        $source = $OverrideSource
    }
    else {
        $source = [pscustomobject]@{
            type = 'winget'
            id = $Token
            priority = 10
        }
    }

    return [pscustomobject]@{
        key = $Token
        name = $Token
        group = 'Profile / Custom'
        description = 'Custom profile entry'
        defaultScope = 'Auto'
        homepage = ''
        sources = @($source)
    }
}



function Convert-GoogleDriveUrl {
    param([string]$Url)

    if ($Url -match 'drive\.google\.com/file/d/([^/?]+)') {
        return "https://drive.usercontent.google.com/download?id=$($matches[1])&export=download&confirm=t"
    }

    if ($Url -match '[?&]id=([^&]+)') {
        return "https://drive.usercontent.google.com/download?id=$($matches[1])&export=download&confirm=t"
    }

    return $Url
}



function New-GitHubHttpClient {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('WindowsRestoreManager/3.2.5')
    $client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')

    if (-not [string]::IsNullOrWhiteSpace([string]$env:GITHUB_TOKEN)) {
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation(
            'Authorization',
            "Bearer $($env:GITHUB_TOKEN)"
        )
    }

    return [pscustomobject]@{
        Client = $client
        Handler = $handler
    }
}


function Get-GitHubReleaseAsset {
    param($Source)

    $repo = ([string]$Source.repo).Trim()

    if ($repo -notmatch '^[^/\s]+/[^/\s]+$') {
        throw "GitHub source repo must be 'owner/repository', got '$repo'."
    }

    $releaseName = if ($Source.release) {
        ([string]$Source.release).Trim()
    }
    else {
        'latest'
    }

    if ($releaseName -ieq 'latest') {
        $apiUrl = "https://api.github.com/repos/$repo/releases/latest"
    }
    else {
        $encodedTag = [Uri]::EscapeDataString($releaseName)
        $apiUrl = "https://api.github.com/repos/$repo/releases/tags/$encodedTag"
    }

    $http = New-GitHubHttpClient
    $client = $http.Client
    $handler = $http.Handler
    $response = $null

    try {
        Write-ManagerLog "Querying GitHub release: $repo / $releaseName..."
        $response = $client.GetAsync($apiUrl).GetAwaiter().GetResult()

        if (-not $response.IsSuccessStatusCode) {
            $remaining = ''
            if ($response.Headers.Contains('X-RateLimit-Remaining')) {
                $remaining = " RateLimitRemaining=$([string]::Join(',', $response.Headers.GetValues('X-RateLimit-Remaining')))."
            }

            throw "GitHub API HTTP $([int]$response.StatusCode) $($response.ReasonPhrase).$remaining"
        }

        $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $release = $json | ConvertFrom-Json
    }
    finally {
        if ($response) { $response.Dispose() }
        if ($client) { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
    }

    $assets = @(
        $release.assets |
            Where-Object {
                $_.state -eq 'uploaded' -and
                -not [string]::IsNullOrWhiteSpace([string]$_.browser_download_url)
            }
    )

    if ($Source.assetRegex) {
        $regex = [string]$Source.assetRegex
        $assets = @($assets | Where-Object { ([string]$_.name) -match $regex })
    }
    elseif ($Source.assetPattern) {
        $pattern = [string]$Source.assetPattern
        $assets = @($assets | Where-Object { ([string]$_.name) -like $pattern })
    }
    else {
        # Safe default: only executable/archive payloads. Checksums/signatures
        # and source archives are not release assets returned here unless the
        # project uploaded them explicitly.
        $assets = @(
            $assets |
                Where-Object {
                    [IO.Path]::GetExtension([string]$_.name).ToLowerInvariant() -in @('.zip','.exe','.msi')
                }
        )
    }

    if ($assets.Count -eq 0) {
        $selector = if ($Source.assetRegex) {
            "regex '$($Source.assetRegex)'"
        }
        elseif ($Source.assetPattern) {
            "pattern '$($Source.assetPattern)'"
        }
        else {
            'supported payload extensions (.zip/.exe/.msi)'
        }

        throw "No GitHub release asset matched $selector in $repo release '$($release.tag_name)'."
    }

    if ($assets.Count -gt 1) {
        $names = (($assets | ForEach-Object { [string]$_.name }) -join ', ')
        throw "GitHub source matched multiple assets in $repo release '$($release.tag_name)': $names. Set assetPattern or assetRegex explicitly."
    }

    $asset = $assets[0]

    return [pscustomobject]@{
        Repo = $repo
        Tag = [string]$release.tag_name
        ReleaseName = [string]$release.name
        AssetName = [string]$asset.name
        DownloadUrl = [string]$asset.browser_download_url
        Size = [long]$asset.size
        Digest = $(if ($asset.PSObject.Properties.Name -contains 'digest') { [string]$asset.digest } else { '' })
    }
}


function Save-GitHubReleaseAsset {
    param(
        $Asset,
        [string]$Destination
    )

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('WindowsRestoreManager/3.2.5')

    if (-not [string]::IsNullOrWhiteSpace([string]$env:GITHUB_TOKEN)) {
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation(
            'Authorization',
            "Bearer $($env:GITHUB_TOKEN)"
        )
    }

    $response = $null

    try {
        Write-ManagerLog "Downloading GitHub asset '$($Asset.AssetName)' from $($Asset.Repo) $($Asset.Tag)..."
        $response = $client.GetAsync([string]$Asset.DownloadUrl).GetAwaiter().GetResult()

        if (-not $response.IsSuccessStatusCode) {
            throw "GitHub asset download HTTP $([int]$response.StatusCode) $($response.ReasonPhrase)."
        }

        [IO.File]::WriteAllBytes(
            $Destination,
            $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        )
    }
    finally {
        if ($response) { $response.Dispose() }
        if ($client) { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
    }

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "GitHub asset was not written to '$Destination'."
    }

    if ($Asset.Size -gt 0) {
        $actualSize = (Get-Item -LiteralPath $Destination).Length
        if ($actualSize -ne $Asset.Size) {
            throw "GitHub asset size mismatch. Expected $($Asset.Size), got $actualSize."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Asset.Digest) -and
        ([string]$Asset.Digest) -match '^sha256:([0-9a-fA-F]{64})$') {
        $expectedHash = $matches[1].ToLowerInvariant()
        $actualHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($actualHash -ne $expectedHash) {
            throw "GitHub asset SHA-256 mismatch for '$($Asset.AssetName)'."
        }

        Write-ManagerLog "GitHub SHA-256 verified for '$($Asset.AssetName)'." 'OK'
    }
}


function Install-GitHubSource {
    param(
        $App,
        $Source
    )

    try {
        $asset = Get-GitHubReleaseAsset -Source $Source
        $installMode = if ($Source.installMode) {
            ([string]$Source.installMode).Trim().ToLowerInvariant()
        }
        else {
            'portable'
        }

        if ($installMode -eq 'portable') {
            $portableSource = [pscustomobject]@{
                type = 'portable'
                url = [string]$asset.DownloadUrl
                priority = 1
            }

            $ok = Install-PortableSource -App $App -Source $portableSource

            if ($ok) {
                $safeKey = ([string]$App.key -replace '[^\w\.\-]','_')
                $target = Join-Path $portableRoot $safeKey
                $marker = Join-Path $target '.restore-installed'

                Set-Content -LiteralPath $marker -Encoding UTF8 -Value @(
                    "Installed: $((Get-Date).ToString('o'))"
                    'SourceType: github'
                    "Repo: $($asset.Repo)"
                    "Release: $($asset.Tag)"
                    "Asset: $($asset.AssetName)"
                    "URL: $($asset.DownloadUrl)"
                )

                Write-ManagerLog "Installed $($App.name) from GitHub release $($asset.Tag) as managed portable." 'OK'
            }

            return [bool]$ok
        }

        if ($installMode -ne 'installer') {
            throw "Unsupported GitHub installMode '$installMode'. Use 'portable' or 'installer'."
        }

        $temp = Join-Path $env:TEMP ("RestoreManager-GitHub-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temp -Force | Out-Null

        try {
            $download = Join-Path $temp ([IO.Path]::GetFileName([string]$asset.AssetName))
            Save-GitHubReleaseAsset -Asset $asset -Destination $download

            $ext = [IO.Path]::GetExtension($download).ToLowerInvariant()
            $installerArgs = @()

            if ($Source.PSObject.Properties.Name -contains 'installerArgs' -and $Source.installerArgs) {
                $installerArgs = @($Source.installerArgs | ForEach-Object { [string]$_ })
            }

            if ($ext -eq '.exe') {
                Write-ManagerLog "Running GitHub installer '$($asset.AssetName)' for $($App.name)..."
                $result = Invoke-External $download $installerArgs
            }
            elseif ($ext -eq '.msi') {
                $args = @('/i', $download)

                if ($installerArgs.Count -gt 0) {
                    $args += $installerArgs
                }
                else {
                    $args += @('/qn','/norestart')
                }

                Write-ManagerLog "Running GitHub MSI '$($asset.AssetName)' for $($App.name)..."
                $result = Invoke-External 'msiexec.exe' $args
            }
            else {
                throw "GitHub installer mode supports EXE/MSI assets, got '$($asset.AssetName)'."
            }

            if ($result.ExitCode -eq 0) {
                Write-ManagerLog "Installed $($App.name) from GitHub release $($asset.Tag)." 'OK'
                return $true
            }

            Write-ManagerLog "GitHub installer failed for $($App.name) with exit code $($result.ExitCode)." 'WARN'
            return $false
        }
        finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-ManagerLog "GitHub source failed for $($App.name): $($_.Exception.Message)" 'WARN'
        return $false
    }
}


function Invoke-RegisteredUninstallForApp {
    param($App)

    $declared = @(Get-DeclaredRegistryNames -App $App)
    if ($declared.Count -eq 0) {
        return $false
    }

    $entry = Find-ArpEntry -Entries @(Get-ArpEntries) -DeclaredNames $declared
    if (-not $entry) {
        return $false
    }

    $command = if (-not [string]::IsNullOrWhiteSpace([string]$entry.QuietUninstallString)) {
        [string]$entry.QuietUninstallString
    }
    else {
        [string]$entry.UninstallString
    }

    if ([string]::IsNullOrWhiteSpace($command)) {
        return $false
    }

    Write-ManagerLog "Running exact registered uninstaller for $($App.name)..."
    $result = Invoke-External $env:ComSpec @('/d','/s','/c', $command)

    if ($result.ExitCode -eq 0) {
        Start-Sleep -Milliseconds 500
        $remaining = Find-ArpEntry -Entries @(Get-ArpEntries) -DeclaredNames $declared

        if (-not $remaining) {
            Write-ManagerLog "Registered uninstall verified for $($App.name)." 'OK'
            return $true
        }

        Write-ManagerLog "Registered uninstaller returned success but $($App.name) is still registered." 'WARN'
    }

    return $false
}


function Install-PortableSource {
    param(
        $App,
        $Source
    )

    $url = [string]$Source.url
    if ([string]::IsNullOrWhiteSpace($url)) {
        Write-ManagerLog "Portable source for '$($App.key)' has no URL." 'ERROR'
        return $false
    }

    $safeKey = ([string]$App.key -replace '[^\w\.\-]','_')
    $target = Join-Path $portableRoot $safeKey
    $temp = Join-Path $env:TEMP ("RestoreManager-" + [guid]::NewGuid().ToString('N'))

    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    New-Item -ItemType Directory -Path $target -Force | Out-Null

    try {
        $downloadUrl = Convert-GoogleDriveUrl $url

        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $true
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromMinutes(30)

        try {
            Write-ManagerLog "Downloading portable source for $($App.name)..."
            $response = $client.GetAsync($downloadUrl).GetAwaiter().GetResult()

            if (-not $response.IsSuccessStatusCode) {
                throw "HTTP $([int]$response.StatusCode) $($response.ReasonPhrase)"
            }

            $contentType = [string]$response.Content.Headers.ContentType
            if ($contentType -match 'text/html') {
                throw 'The URL returned HTML instead of a file. Check sharing permissions.'
            }

            $fileName = $null
            if ($response.Content.Headers.ContentDisposition) {
                $fileName = [string]$response.Content.Headers.ContentDisposition.FileNameStar
                if ([string]::IsNullOrWhiteSpace($fileName)) {
                    $fileName = [string]$response.Content.Headers.ContentDisposition.FileName
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($fileName)) {
                $fileName = [IO.Path]::GetFileName($fileName.Trim('"'))
            }
            else {
                $fileName = "$safeKey.download"
            }

            $download = Join-Path $temp $fileName
            [IO.File]::WriteAllBytes(
                $download,
                $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            )
        }
        finally {
            if ($response) { $response.Dispose() }
            if ($client) { $client.Dispose() }
            if ($handler) { $handler.Dispose() }
        }

        $ext = [IO.Path]::GetExtension($download).ToLowerInvariant()

        if ($ext -eq '.zip') {
            Expand-Archive -LiteralPath $download -DestinationPath $target -Force
        }
        elseif ($ext -eq '.exe') {
            Copy-Item -LiteralPath $download -Destination (Join-Path $target ([IO.Path]::GetFileName($download))) -Force
        }
        else {
            $stream = [IO.File]::OpenRead($download)
            try {
                $header = New-Object byte[] 4
                [void]$stream.Read($header,0,4)
            }
            finally {
                $stream.Dispose()
            }

            $isZip = ($header[0] -eq 0x50 -and $header[1] -eq 0x4B)
            $isExe = ($header[0] -eq 0x4D -and $header[1] -eq 0x5A)

            if ($isZip) {
                $zip = "$download.zip"
                Move-Item -LiteralPath $download -Destination $zip -Force
                Expand-Archive -LiteralPath $zip -DestinationPath $target -Force
            }
            elseif ($isExe) {
                Copy-Item -LiteralPath $download -Destination (Join-Path $target "$safeKey.exe") -Force
            }
            else {
                throw 'Unsupported portable file type. Expected ZIP or standalone EXE.'
            }
        }

        Set-Content -LiteralPath (Join-Path $target '.restore-installed') `
            -Value ("Installed: {0:o}`r`nSource: {1}" -f (Get-Date), $url) `
            -Encoding UTF8

        Write-ManagerLog "Portable app installed: $($App.name) -> $target" 'OK'
        return $true
    }
    catch {
        Write-ManagerLog "Portable install failed for $($App.name): $($_.Exception.Message)" 'ERROR'
        return $false
    }
    finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}



function Get-EffectiveScope {
    param(
        $App,
        [string]$RequestedScope
    )

    if ($RequestedScope -and $RequestedScope -ne 'Auto') {
        return $RequestedScope
    }

    if ($App.defaultScope -and [string]$App.defaultScope -ne 'Auto') {
        return [string]$App.defaultScope
    }

    return 'Auto'
}



function Install-App {
    param(
        $App,
        [string]$RequestedScope = 'Auto',
        [string]$ForceSourceType,
        $SourceOverride,
        [bool]$AutoInstallChocolatey = $true
    )

    $effectiveScope = Get-EffectiveScope -App $App -RequestedScope $RequestedScope

    if ($SourceOverride) {
        $sources = @($SourceOverride)
    }
    else {
        $sources = @($App.sources | Sort-Object { [int]$_.priority })
        if ($ForceSourceType) {
            $sources = @($sources | Where-Object { $_.type -ieq $ForceSourceType })
        }
    }

    if ($sources.Count -eq 0) {
        Write-ManagerLog "No matching install source for $($App.name)." 'ERROR'
        return $false
    }

    foreach ($source in $sources) {
        $type = ([string]$source.type).ToLowerInvariant()

        switch ($type) {
            'winget' {
                $winget = Get-WingetPath
                if (-not $winget) {
                    Write-ManagerLog "Skipping WinGet source for $($App.name): winget.exe is unavailable." 'WARN'
                    continue
                }

                $repository = $(if ($source.repository) { [string]$source.repository } else { 'winget' })

                $args = @(
                    'install',
                    '--id', [string]$source.id,
                    '--source', $repository,
                    '--silent',
                    '--accept-package-agreements',
                    '--accept-source-agreements',
                    '--disable-interactivity'
                )

                if ($effectiveScope -eq 'User') {
                    $args += @('--scope','user')
                }
                elseif ($effectiveScope -eq 'Machine') {
                    $args += @('--scope','machine')
                }

                Write-ManagerLog "Trying WinGet source '$($source.id)' for $($App.name)..."
                $result = Invoke-External $winget $args

                if ($result.ExitCode -eq 0) {
                    Write-ManagerLog "Installed $($App.name) through WinGet." 'OK'
                    return $true
                }

                Write-ManagerLog "WinGet failed for $($App.name) (exit $($result.ExitCode)); trying next configured source." 'WARN'
            }

            'choco' {
                $choco = Ensure-Chocolatey -AutoInstall $AutoInstallChocolatey
                if (-not $choco) {
                    Write-ManagerLog "Skipping Chocolatey source for $($App.name): Chocolatey unavailable." 'WARN'
                    continue
                }

                if ($effectiveScope -ne 'Auto') {
                    Write-ManagerLog "Requested scope '$effectiveScope' cannot be generically enforced for Chocolatey packages; package installer behavior applies." 'WARN'
                }

                Write-ManagerLog "Trying Chocolatey source '$($source.id)' for $($App.name)..."
                $chocoArgs = @(
                    'install', [string]$source.id,
                    '-y',
                    '--no-progress'
                )
                if ($source.repository) {
                    $chocoArgs += @('--source',[string]$source.repository)
                }
                $result = Invoke-External $choco $chocoArgs

                if ($result.ExitCode -eq 0) {
                    Write-ManagerLog "Installed $($App.name) through Chocolatey." 'OK'
                    return $true
                }

                Write-ManagerLog "Chocolatey failed for $($App.name) (exit $($result.ExitCode)); trying next configured source." 'WARN'
            }

            'portable' {
                if (Install-PortableSource -App $App -Source $source) {
                    return $true
                }
            }

            'github' {
                if (Install-GitHubSource -App $App -Source $source) {
                    return $true
                }

                Write-ManagerLog "GitHub failed for $($App.name); trying next configured source." 'WARN'
            }

            'manual' {
                if ($source.url) {
                    Write-ManagerLog "Opening manual/web source for $($App.name): $($source.url)" 'WARN'
                    Start-Process ([string]$source.url)
                    return $true
                }
            }

            default {
                Write-ManagerLog "Unknown source type '$type' for $($App.name)." 'WARN'
            }
        }
    }

    Write-ManagerLog "All configured sources failed for $($App.name)." 'ERROR'
    return $false
}



function Test-AppInstalledExact {
    param(
        $App,
        [hashtable]$WingetPackages,
        [hashtable]$ChocoInventory
    )

    $portablePath = Join-Path $portableRoot (($App.key -replace '[^\w\.\-]','_'))
    if (Test-Path (Join-Path $portablePath '.restore-installed')) {
        return $true
    }

    foreach ($source in @($App.sources)) {
        if ($source.type -eq 'choco' -and $source.id) {
            $key = ([string]$source.id).ToLowerInvariant()
            if ($ChocoInventory.ContainsKey($key)) {
                return $true
            }
        }

        if ($source.type -eq 'winget' -and $source.id) {
            $key = ([string]$source.id).ToLowerInvariant()
            if ($WingetPackages.ContainsKey($key)) {
                return $true
            }
        }
    }

    $declared = @(Get-DeclaredRegistryNames -App $App)
    if ($declared.Count -gt 0) {
        $arp = Find-ArpEntry -Entries @(Get-ArpEntries) -DeclaredNames $declared
        if ($arp) {
            return $true
        }
    }

    return $false
}

function Uninstall-App {
    param(
        $App,
        [string]$ForceSourceType,
        $SourceOverride,
        [bool]$AutoInstallChocolatey = $false
    )

    $script:LastUninstallReason = ''

    $portablePath = Join-Path $portableRoot (($App.key -replace '[^\w\.\-]','_'))
    if ((-not $ForceSourceType -or $ForceSourceType -in @('portable','github')) -and
        (Test-Path (Join-Path $portablePath '.restore-installed'))) {
        try {
            Remove-Item -LiteralPath $portablePath -Recurse -Force -ErrorAction Stop

            if (Test-Path -LiteralPath $portablePath) {
                $script:LastUninstallReason = 'Portable application directory still exists after removal.'
                return $false
            }

            Write-ManagerLog "Removed portable application $($App.name)." 'OK'
            return $true
        }
        catch {
            $script:LastUninstallReason = $_.Exception.Message
            Write-ManagerLog "Failed to remove portable application $($App.name): $($_.Exception.Message)" 'ERROR'
            return $false
        }
    }

    if ($SourceOverride) {
        $sources = @($SourceOverride)
    }
    else {
        $sources = @($App.sources | Sort-Object { [int]$_.priority })
        if ($ForceSourceType) {
            $sources = @($sources | Where-Object { $_.type -ieq $ForceSourceType })
        }
    }

    $wingetInventory = Get-WingetInventory
    $wingetPackages = $wingetInventory.Packages
    $chocoInventory = Get-ChocoInventory

    $sources = @($sources | Sort-Object {
        if ($_.type -eq 'choco' -and $_.id) {
            $key = ([string]$_.id).ToLowerInvariant()
            if ($chocoInventory.ContainsKey($key)) { return 0 }
        }

        if ($_.type -eq 'winget' -and $_.id) {
            $key = ([string]$_.id).ToLowerInvariant()
            if ($wingetPackages.ContainsKey($key)) { return 1 }
        }

        return (10 + [int]$_.priority)
    })

    $attempted = $false

    foreach ($source in $sources) {
        $type = ([string]$source.type).ToLowerInvariant()

        if ($type -eq 'choco' -and $source.id) {
            $packageKey = ([string]$source.id).ToLowerInvariant()
            if (-not $chocoInventory.ContainsKey($packageKey)) { continue }

            $attempted = $true
            $choco = Get-ChocoPath

            if (-not $choco -and $AutoInstallChocolatey) {
                $choco = Ensure-Chocolatey -AutoInstall $true
            }

            if (-not $choco) {
                $script:LastUninstallReason = 'Chocolatey tracks this package, but choco.exe is unavailable.'
                continue
            }

            Write-ManagerLog "Uninstalling $($App.name) through Chocolatey..."

            $chocoArgs = @('uninstall',[string]$source.id,'-y','--no-progress')
            if ($source.repository) {
                $chocoArgs += @('--source',[string]$source.repository)
            }

            $result = Invoke-External $choco $chocoArgs

            if ($result.ExitCode -ne 0) {
                $script:LastUninstallReason = "Chocolatey uninstall failed with exit code $($result.ExitCode)."
                Write-ManagerLog $script:LastUninstallReason 'WARN'
                continue
            }

            $afterWinget = Get-WingetInventory
            $afterChoco = Get-ChocoInventory

            if (-not (Test-AppInstalledExact -App $App -WingetPackages $afterWinget.Packages -ChocoInventory $afterChoco)) {
                Write-ManagerLog "Uninstalled $($App.name) through Chocolatey and verified removal." 'OK'
                return $true
            }

            $script:LastUninstallReason = 'Chocolatey returned success, but the application is still detected.'
            $wingetInventory = $afterWinget
            $wingetPackages = $afterWinget.Packages
            $chocoInventory = $afterChoco
        }

        if ($type -eq 'winget' -and $source.id) {
            $packageKey = ([string]$source.id).ToLowerInvariant()
            if (-not $wingetPackages.ContainsKey($packageKey)) { continue }

            $attempted = $true
            $winget = Get-WingetPath

            if (-not $winget) {
                $script:LastUninstallReason = 'winget.exe is unavailable.'
                continue
            }

            $package = $wingetPackages[$packageKey]
            $installedScope = if ($package.PSObject.Properties.Name -contains 'Scope') {
                [string]$package.Scope
            }
            else {
                'Unknown'
            }

            if ($installedScope -eq 'User' -and (Test-RestoreAdministrator)) {
                $script:LastUninstallReason = 'User-scope package cannot be removed from an elevated PowerShell session. Restart the TUI from a normal (non-Administrator) PowerShell window.'
                Write-ManagerLog "$($App.name) is User scope; elevated WinGet cannot uninstall it." 'ERROR'
                return $false
            }

            Write-ManagerLog "Uninstalling $($App.name) through WinGet using exact ID '$($source.id)' and scope '$installedScope'..."

            $args = @(
                'uninstall',
                '--id',[string]$source.id,
                '--exact',
                '--silent',
                '--accept-source-agreements',
                '--disable-interactivity'
            )

            if ($installedScope -eq 'User') {
                $args += @('--scope','user')
            }
            elseif ($installedScope -eq 'Machine') {
                $args += @('--scope','machine')
            }

            if ($source.repository) {
                $args += @('--source',[string]$source.repository)
            }

            $result = Invoke-External $winget $args

            if ($result.ExitCode -ne 0) {
                $script:LastUninstallReason = "WinGet uninstall failed with exit code $($result.ExitCode)."
                Write-ManagerLog "WinGet uninstall failed for $($App.name) (exit $($result.ExitCode))." 'WARN'
                continue
            }

            $afterWinget = Get-WingetInventory
            $afterChoco = Get-ChocoInventory

            if (-not (Test-AppInstalledExact -App $App -WingetPackages $afterWinget.Packages -ChocoInventory $afterChoco)) {
                Write-ManagerLog "Uninstalled $($App.name) through WinGet and verified removal." 'OK'
                return $true
            }

            $script:LastUninstallReason = 'WinGet returned success, but the package is still detected after uninstall.'
            Write-ManagerLog $script:LastUninstallReason 'ERROR'

            $wingetInventory = $afterWinget
            $wingetPackages = $afterWinget.Packages
            $chocoInventory = $afterChoco
        }

        if ($type -eq 'github') {
            $installMode = $(if ($source.installMode) { ([string]$source.installMode).ToLowerInvariant() } else { 'portable' })

            if ($installMode -eq 'installer') {
                $attempted = $true

                if (Invoke-RegisteredUninstallForApp -App $App) {
                    return $true
                }

                $script:LastUninstallReason = 'GitHub installer package has no usable exact registered uninstall entry, or its uninstaller failed.'
                Write-ManagerLog $script:LastUninstallReason 'WARN'
            }
        }

        if ($type -eq 'manual') {
            $script:LastUninstallReason = 'Manual/web source has no automatic uninstall route.'
            Write-ManagerLog "Manual source cannot be automatically uninstalled: $($App.name)." 'WARN'
        }
    }

    if (-not $attempted) {
        if ([string]::IsNullOrWhiteSpace($script:LastUninstallReason)) {
            $script:LastUninstallReason = 'No installed managed source was found.'
        }
        Write-ManagerLog "No installed managed source was found for $($App.name)." 'ERROR'
    }
    else {
        if ([string]::IsNullOrWhiteSpace($script:LastUninstallReason)) {
            $script:LastUninstallReason = 'No uninstall route successfully removed the application.'
        }
        Write-ManagerLog "No uninstall route successfully removed $($App.name)." 'ERROR'
    }

    return $false
}


function Upgrade-App {
    param(
        $App,
        [string]$ForceSourceType,
        $SourceOverride,
        [bool]$AutoInstallChocolatey = $true
    )

    if ($SourceOverride) {
        $sources = @($SourceOverride)
    }
    else {
        $sources = @($App.sources | Sort-Object { [int]$_.priority })
        if ($ForceSourceType) {
            $sources = @($sources | Where-Object { $_.type -ieq $ForceSourceType })
        }
    }

    $chocoInventory = Get-ChocoInventory

    foreach ($source in $sources) {
        $type = ([string]$source.type).ToLowerInvariant()

        if ($type -eq 'choco' -and $source.id) {
            $key = ([string]$source.id).ToLowerInvariant()
            if (-not $chocoInventory.ContainsKey($key)) { continue }

            $choco = Get-ChocoPath
            if (-not $choco) { continue }

            $chocoArgs = @(
                'upgrade', [string]$source.id,
                '-y',
                '--no-progress'
            )
            if ($source.repository) {
                $chocoArgs += @('--source',[string]$source.repository)
            }
            $result = Invoke-External $choco $chocoArgs

            if ($result.ExitCode -eq 0) {
                Write-ManagerLog "Upgraded $($App.name) through Chocolatey." 'OK'
                return $true
            }
        }

        if ($type -eq 'winget' -and $source.id) {
            $winget = Get-WingetPath
            if (-not $winget) { continue }

            $repository = $(if ($source.repository) { [string]$source.repository } else { 'winget' })
            $result = Invoke-External $winget @(
                'upgrade',
                '--id', [string]$source.id,
                '--source', $repository,
                '--silent',
                '--accept-package-agreements',
                '--accept-source-agreements',
                '--disable-interactivity'
            )

            if ($result.ExitCode -eq 0) {
                Write-ManagerLog "Upgrade completed for $($App.name) through WinGet." 'OK'
                return $true
            }
        }

        if ($type -eq 'github') {
            Write-ManagerLog "Checking GitHub release source for upgrade of $($App.name)..."

            if (Install-GitHubSource -App $App -Source $source) {
                Write-ManagerLog "Upgrade completed for $($App.name) through GitHub." 'OK'
                return $true
            }
        }
    }

    Write-ManagerLog "No upgrade route succeeded for $($App.name)." 'WARN'
    return $false
}



$systemCatalog = @(
    [pscustomobject]@{ Key='SSHClient'; Name='OpenSSH Client'; Kind='Capability'; FeatureName='OpenSSH.Client~~~~0.0.1.0'; Description='SSH client: ssh, scp, sftp.' },
    [pscustomobject]@{ Key='SSHServer'; Name='OpenSSH Server'; Kind='Capability'; FeatureName='OpenSSH.Server~~~~0.0.1.0'; Description='Windows OpenSSH server (sshd).' },
    [pscustomobject]@{ Key='Telnet'; Name='Telnet Client'; Kind='Feature'; FeatureName='TelnetClient'; Description='Legacy Telnet client.' },
    [pscustomobject]@{ Key='VMP'; Name='Virtual Machine Platform'; Kind='Feature'; FeatureName='VirtualMachinePlatform'; Description='Virtualization platform used by WSL2 and other tools.' },
    [pscustomobject]@{ Key='WSL'; Name='Windows Subsystem for Linux'; Kind='WSL'; FeatureName='Microsoft-Windows-Subsystem-Linux'; Description='Windows Subsystem for Linux / WSL2.' },
    [pscustomobject]@{ Key='HyperV'; Name='Hyper-V'; Kind='Feature'; FeatureName='Microsoft-Hyper-V-All'; Description='Microsoft Hyper-V platform.' }
)



function Find-SystemComponent {
    param([string]$Key)
    return ($systemCatalog | Where-Object { $_.Key -ieq $Key } | Select-Object -First 1)
}



function Get-SystemComponentState {
    param($Component)

    try {
        switch ($Component.Kind) {
            'Capability' {
                $state = (Get-WindowsCapability -Online -Name $Component.FeatureName -ErrorAction Stop).State
                if ($state -eq 'Installed') { return 'Installed' }
                return 'Not installed'
            }

            'Feature' {
                $state = (Get-WindowsOptionalFeature -Online -FeatureName $Component.FeatureName -ErrorAction Stop).State
                if ($state -eq 'Enabled') { return 'Enabled' }
                return 'Disabled'
            }

            'WSL' {
                $state = (Get-WindowsOptionalFeature -Online -FeatureName $Component.FeatureName -ErrorAction Stop).State
                if ($state -eq 'Enabled') { return 'Enabled' }
                return 'Disabled'
            }
        }
    }
    catch {
        return 'Unavailable'
    }

    return 'Unknown'
}



function Set-SystemComponent {
    param(
        $Component,
        [bool]$Enable
    )

    try {
        if ($Enable) {
            Write-ManagerLog "Enabling Windows component: $($Component.Name)..."

            switch ($Component.Kind) {
                'Capability' {
                    Add-WindowsCapability -Online -Name $Component.FeatureName -ErrorAction Stop | Out-Null

                    if ($Component.Key -eq 'SSHServer') {
                        Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
                        Start-Service sshd -ErrorAction SilentlyContinue
                    }
                }

                'Feature' {
                    Enable-WindowsOptionalFeature -Online -FeatureName $Component.FeatureName -All -NoRestart -ErrorAction Stop | Out-Null
                }

                'WSL' {
                    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
                    if ($wsl) {
                        & wsl.exe --install --no-distribution | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            Write-ManagerLog 'WSL install command completed.' 'OK'
                            return $true
                        }
                    }

                    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -All -NoRestart -ErrorAction Stop | Out-Null
                    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -ErrorAction Stop | Out-Null
                }
            }

            Write-ManagerLog "Enabled Windows component: $($Component.Name)." 'OK'
            return $true
        }
        else {
            Write-ManagerLog "Disabling Windows component: $($Component.Name)..."

            switch ($Component.Kind) {
                'Capability' {
                    Remove-WindowsCapability -Online -Name $Component.FeatureName -ErrorAction Stop | Out-Null
                }

                'Feature' {
                    Disable-WindowsOptionalFeature -Online -FeatureName $Component.FeatureName -NoRestart -ErrorAction Stop | Out-Null
                }

                'WSL' {
                    Disable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -ErrorAction Stop | Out-Null
                }
            }

            Write-ManagerLog "Disabled Windows component: $($Component.Name)." 'OK'
            return $true
        }
    }
    catch {
        Write-ManagerLog "Windows component operation failed for $($Component.Name): $($_.Exception.Message)" 'ERROR'
        return $false
    }
}



$systemSettingsInfo = @(
    [pscustomobject]@{ Key='ShowFileExtensions'; Type='Boolean'; Description='Show known file extensions in File Explorer.' },
    [pscustomobject]@{ Key='ShowHiddenFiles'; Type='Boolean'; Description='Show hidden files in File Explorer.' },
    [pscustomobject]@{ Key='ShowProtectedOSFiles'; Type='Boolean'; Description='Show protected operating system files.' },
    [pscustomobject]@{ Key='DeveloperMode'; Type='Boolean'; Description='Enable Windows Developer Mode policy.' },
    [pscustomobject]@{ Key='LongPaths'; Type='Boolean'; Description='Enable Win32 long path support.' },
    [pscustomobject]@{ Key='DarkMode'; Type='Boolean'; Description='Use dark mode for Windows and applications.' },
    [pscustomobject]@{ Key='ClipboardHistory'; Type='Boolean'; Description='Enable Windows clipboard history.' },
    [pscustomobject]@{ Key='ShowSecondsInClock'; Type='Boolean'; Description='Show seconds in the taskbar clock when supported.' },
    [pscustomobject]@{ Key='PowerPlan'; Type='Enum'; Description='Balanced, HighPerformance or PowerSaver.' }
)



function ConvertTo-Bool {
    param([string]$Value)

    switch -Regex ($Value.Trim()) {
        '^(?i:true|yes|y|1|on|enable|enabled)$' { return $true }
        '^(?i:false|no|n|0|off|disable|disabled)$' { return $false }
        default { throw "Invalid boolean value: '$Value'." }
    }
}



function Ensure-RegistryKey {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
}



function Set-NamedSystemSetting {
    param(
        [string]$Key,
        [string]$Value
    )

    try {
        switch -Regex ($Key) {
            '^(?i:ShowFileExtensions)$' {
                $enabled = ConvertTo-Bool $Value
                $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                Ensure-RegistryKey $path
                New-ItemProperty -Path $path -Name HideFileExt -PropertyType DWord -Value $(if ($enabled) { 0 } else { 1 }) -Force | Out-Null
            }

            '^(?i:ShowHiddenFiles)$' {
                $enabled = ConvertTo-Bool $Value
                $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                Ensure-RegistryKey $path
                New-ItemProperty -Path $path -Name Hidden -PropertyType DWord -Value $(if ($enabled) { 1 } else { 2 }) -Force | Out-Null
            }

            '^(?i:ShowProtectedOSFiles)$' {
                $enabled = ConvertTo-Bool $Value
                $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                Ensure-RegistryKey $path
                New-ItemProperty -Path $path -Name ShowSuperHidden -PropertyType DWord -Value $(if ($enabled) { 1 } else { 0 }) -Force | Out-Null
            }

            '^(?i:DeveloperMode)$' {
                $enabled = ConvertTo-Bool $Value
                $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
                Ensure-RegistryKey $path
                New-ItemProperty -Path $path -Name AllowDevelopmentWithoutDevLicense -PropertyType DWord -Value $(if ($enabled) { 1 } else { 0 }) -Force | Out-Null
            }

            '^(?i:LongPaths)$' {
                $enabled = ConvertTo-Bool $Value
                $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
                New-ItemProperty -Path $path -Name LongPathsEnabled -PropertyType DWord -Value $(if ($enabled) { 1 } else { 0 }) -Force | Out-Null
            }

            '^(?i:DarkMode)$' {
                $enabled = ConvertTo-Bool $Value
                $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
                Ensure-RegistryKey $path
                $light = $(if ($enabled) { 0 } else { 1 })
                New-ItemProperty -Path $path -Name AppsUseLightTheme -PropertyType DWord -Value $light -Force | Out-Null
                New-ItemProperty -Path $path -Name SystemUsesLightTheme -PropertyType DWord -Value $light -Force | Out-Null
            }

            '^(?i:ClipboardHistory)$' {
                $enabled = ConvertTo-Bool $Value
                $path = 'HKCU:\Software\Microsoft\Clipboard'
                Ensure-RegistryKey $path
                New-ItemProperty -Path $path -Name EnableClipboardHistory -PropertyType DWord -Value $(if ($enabled) { 1 } else { 0 }) -Force | Out-Null
            }

            '^(?i:ShowSecondsInClock)$' {
                $enabled = ConvertTo-Bool $Value
                $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                Ensure-RegistryKey $path
                New-ItemProperty -Path $path -Name ShowSecondsInSystemClock -PropertyType DWord -Value $(if ($enabled) { 1 } else { 0 }) -Force | Out-Null
            }

            '^(?i:PowerPlan)$' {
                switch -Regex ($Value.Trim()) {
                    '^(?i:Balanced)$'        { & powercfg.exe /setactive SCHEME_BALANCED | Out-Null }
                    '^(?i:HighPerformance|High Performance)$' { & powercfg.exe /setactive SCHEME_MIN | Out-Null }
                    '^(?i:PowerSaver|Power Saver)$' { & powercfg.exe /setactive SCHEME_MAX | Out-Null }
                    default { throw "Unknown PowerPlan '$Value'." }
                }
            }

            default {
                throw "Unknown system setting '$Key'."
            }
        }

        Write-ManagerLog "System setting applied: $Key=$Value" 'OK'
        return $true
    }
    catch {
        Write-ManagerLog "Failed to apply system setting $Key=$Value : $($_.Exception.Message)" 'ERROR'
        return $false
    }
}



function Get-NamedSystemSetting {
    param([string]$Key)

    try {
        switch -Regex ($Key) {
            '^(?i:ShowFileExtensions)$' {
                $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideFileExt -ErrorAction Stop).HideFileExt
                return $(if ($v -eq 0) { 'true' } else { 'false' })
            }

            '^(?i:ShowHiddenFiles)$' {
                $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name Hidden -ErrorAction Stop).Hidden
                return $(if ($v -eq 1) { 'true' } else { 'false' })
            }

            '^(?i:ShowProtectedOSFiles)$' {
                $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name ShowSuperHidden -ErrorAction Stop).ShowSuperHidden
                return $(if ($v -eq 1) { 'true' } else { 'false' })
            }

            '^(?i:DeveloperMode)$' {
                $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name AllowDevelopmentWithoutDevLicense -ErrorAction Stop).AllowDevelopmentWithoutDevLicense
                return $(if ($v -eq 1) { 'true' } else { 'false' })
            }

            '^(?i:LongPaths)$' {
                $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction Stop).LongPathsEnabled
                return $(if ($v -eq 1) { 'true' } else { 'false' })
            }

            '^(?i:DarkMode)$' {
                $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme
                return $(if ($v -eq 0) { 'true' } else { 'false' })
            }

            '^(?i:ClipboardHistory)$' {
                $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Clipboard' -Name EnableClipboardHistory -ErrorAction Stop).EnableClipboardHistory
                return $(if ($v -eq 1) { 'true' } else { 'false' })
            }

            '^(?i:ShowSecondsInClock)$' {
                $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name ShowSecondsInSystemClock -ErrorAction Stop).ShowSecondsInSystemClock
                return $(if ($v -eq 1) { 'true' } else { 'false' })
            }

            '^(?i:PowerPlan)$' {
                $output = (& powercfg.exe /getactivescheme 2>$null | Out-String)
                if ($output -match '381b4222-f694-41f0-9685-ff5bb260df2e') { return 'Balanced' }
                if ($output -match '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') { return 'HighPerformance' }
                if ($output -match 'a1841308-3541-4fab-bc81-f71556f20b4a') { return 'PowerSaver' }
                return 'Custom'
            }
        }
    }
    catch {
        return 'Unknown'
    }

    return 'Unknown'
}



function Parse-SourceOverride {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $trimmed = $Value.Trim()

    # Backward compatible: plain HTTP URL means portable.
    if ($trimmed -match '^https?://') {
        return [pscustomobject]@{
            type = 'portable'
            url = $trimmed
            priority = 1
        }
    }

    $parts = $trimmed -split '\|', 2
    $type = $parts[0].Trim().ToLowerInvariant()
    $value2 = $(if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' })

    if ($parts.Count -eq 1 -and $type -in @('auto','choco','winget','portable','github','manual')) {
        return [pscustomobject]@{ type=$type; forceOnly=$true; priority=1 }
    }

    switch ($type) {
        'winget' {
            return [pscustomobject]@{ type='winget'; id=$value2; priority=1 }
        }
        'choco' {
            return [pscustomobject]@{ type='choco'; id=$value2; priority=1 }
        }
        'portable' {
            return [pscustomobject]@{ type='portable'; url=$value2; priority=1 }
        }
        'github' {
            return [pscustomobject]@{
                type='github'
                repo=$value2
                release='latest'
                installMode='portable'
                priority=1
            }
        }
        'manual' {
            return [pscustomobject]@{ type='manual'; url=$value2; priority=1 }
        }
        default {
            # "vscode = choco" means force the existing Chocolatey source.
            if ($type -in @('auto','choco','winget','portable','github','manual')) {
                return [pscustomobject]@{ type=$type; forceOnly=$true; priority=1 }
            }
            throw "Invalid source override '$Value'."
        }
    }
}



function Read-Profile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Profile not found: $Path"
    }

    $profile = [pscustomobject]@{
        Path = (Resolve-Path -LiteralPath $Path).Path
        Settings = @{}
        Install = @()
        Uninstall = @()
        Upgrade = @()
        SystemEnable = @()
        SystemDisable = @()
        SystemSettings = @{}
    }

    $section = ''
    $lineNumber = 0

    foreach ($raw in (Get-Content -LiteralPath $profile.Path -Encoding UTF8)) {
        $lineNumber++
        $line = $raw.Trim()

        if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }

        if ($line -match '^\[(.+)\]$') {
            $section = $matches[1].Trim()
            continue
        }

        switch -Regex ($section) {
            '^(?i:Settings)$' {
                if ($line -notmatch '^([^=]+?)\s*=\s*(.*)$') {
                    throw "Expected key=value at line $lineNumber."
                }
                $profile.Settings[$matches[1].Trim()] = $matches[2].Trim()
            }

            '^(?i:Apps\.Install|Packages)$' {
                $parts = $line -split '=', 2
                $target = $parts[0].Trim()
                $override = $(if ($parts.Count -gt 1) { Parse-SourceOverride $parts[1].Trim() } else { $null })
                $profile.Install += [pscustomobject]@{ Target=$target; Override=$override }
            }

            '^(?i:Apps\.Uninstall)$' {
                $parts = $line -split '=', 2
                $target = $parts[0].Trim()
                $override = $(if ($parts.Count -gt 1) { Parse-SourceOverride $parts[1].Trim() } else { $null })
                $profile.Uninstall += [pscustomobject]@{ Target=$target; Override=$override }
            }

            '^(?i:Apps\.Upgrade)$' {
                $parts = $line -split '=', 2
                $target = $parts[0].Trim()
                $override = $(if ($parts.Count -gt 1) { Parse-SourceOverride $parts[1].Trim() } else { $null })
                $profile.Upgrade += [pscustomobject]@{ Target=$target; Override=$override }
            }

            '^(?i:System\.Enable|System)$' {
                $key = ($line -split '=',2)[0].Trim()
                if ($key) { $profile.SystemEnable += $key }
            }

            '^(?i:System\.Disable)$' {
                $key = ($line -split '=',2)[0].Trim()
                if ($key) { $profile.SystemDisable += $key }
            }

            '^(?i:System\.Settings)$' {
                if ($line -notmatch '^([^=]+?)\s*=\s*(.*)$') {
                    throw "Expected key=value in [System.Settings] at line $lineNumber."
                }
                $profile.SystemSettings[$matches[1].Trim()] = $matches[2].Trim()
            }

            default {
                throw "Unknown or missing profile section '$section' at line $lineNumber."
            }
        }
    }

    return $profile
}



function Get-ProfileSetting {
    param(
        $Profile,
        [string]$Name,
        $Default
    )

    foreach ($key in $Profile.Settings.Keys) {
        if ($key -ieq $Name) {
            return $Profile.Settings[$key]
        }
    }

    return $Default
}



function Resolve-ProfileApp {
    param($Entry)

    $app = Find-CatalogApp $Entry.Target

    if ($Entry.Override -and $Entry.Override.forceOnly) {
        if (-not $app) {
            throw "Profile target '$($Entry.Target)' is not in catalog; source '$($Entry.Override.type)' needs an explicit ID/URL using type|value."
        }

        return [pscustomobject]@{
            App = $app
            ForceSourceType = $(if ([string]$Entry.Override.type -ieq 'auto') { $null } else { [string]$Entry.Override.type })
            SourceOverride = $null
        }
    }

    if ($app) {
        return [pscustomobject]@{
            App = $app
            ForceSourceType = $null
            SourceOverride = $Entry.Override
        }
    }

    return [pscustomobject]@{
        App = (New-AdHocApp -Token $Entry.Target -OverrideSource $Entry.Override)
        ForceSourceType = $null
        SourceOverride = $Entry.Override
    }
}



function Get-ProfilePlanText {
    param($Profile)

    $lines = @()
    $lines += "Profile: $($Profile.Path)"
    $lines += ''
    $lines += "Apps to uninstall: $(@($Profile.Uninstall).Count)"
    foreach ($x in $Profile.Uninstall) { $lines += "  - $($x.Target)" }
    $lines += ''
    $lines += "Windows components to disable: $(@($Profile.SystemDisable).Count)"
    foreach ($x in $Profile.SystemDisable) { $lines += "  - $x" }
    $lines += ''
    $lines += "System settings: $($Profile.SystemSettings.Count)"
    foreach ($x in $Profile.SystemSettings.GetEnumerator()) { $lines += "  - $($x.Key)=$($x.Value)" }
    $lines += ''
    $lines += "Windows components to enable: $(@($Profile.SystemEnable).Count)"
    foreach ($x in $Profile.SystemEnable) { $lines += "  + $x" }
    $lines += ''
    $lines += "Apps to install: $(@($Profile.Install).Count)"
    foreach ($x in $Profile.Install) { $lines += "  + $($x.Target)" }
    $lines += ''
    $lines += "Apps to upgrade: $(@($Profile.Upgrade).Count)"
    foreach ($x in $Profile.Upgrade) { $lines += "  ^ $($x.Target)" }

    return ($lines -join [Environment]::NewLine)
}




function Get-RestoreCatalog {
    [CmdletBinding()]
    param()

    Assert-RestoreInitialized

    foreach ($app in $script:catalogApps) {
        [pscustomobject]@{
            key = [string]$app.key
            name = [string]$app.name
            group = [string]$app.group
            description = [string]$app.description
            defaultScope = [string]$app.defaultScope
            homepage = [string]$app.homepage
            sources = (Get-AppSourcesText $app)
        }
    }
}

function Get-RestoreAppInventory {
    [CmdletBinding()]
    param(
        [string[]]$Keys
    )

    Assert-RestoreInitialized

    $wingetInventory = Get-WingetInventory
    $chocoInventory = Get-ChocoInventory
    $arpEntries = @(Get-ArpEntries)
    $appxEntries = @(Get-AppxInventory)

    $apps = @($script:catalogApps)
    if ($Keys -and $Keys.Count -gt 0) {
        $wanted = @($Keys | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $apps = @($apps | Where-Object { $wanted -contains ([string]$_.key).ToLowerInvariant() })
    }

    foreach ($app in $apps) {
        $state = Get-InstalledState `
            -App $app `
            -WingetPackages $wingetInventory.Packages `
            -WingetText $wingetInventory.ListText `
            -ChocoInventory $chocoInventory `
            -ArpEntries $arpEntries `
            -AppxEntries $appxEntries

        [pscustomobject]@{
            key = [string]$app.key
            name = [string]$app.name
            group = [string]$app.group
            description = [string]$app.description
            sources = (Get-AppSourcesText $app)
            installed = [bool]$state.Installed
            status = $(if ($state.Installed) { 'Installed' } else { 'Not installed' })
            version = [string]$state.Version
            installedVia = [string]$state.Via
            scope = [string]$state.Scope
            location = [string]$state.Location
        }
    }
}

function Get-RestoreSystemInventory {
    [CmdletBinding()]
    param()

    foreach ($component in $script:systemCatalog) {
        [pscustomobject]@{
            key = [string]$component.Key
            name = [string]$component.Name
            status = Get-SystemComponentState $component
            description = [string]$component.Description
        }
    }
}

function Get-RestoreSettingsInventory {
    [CmdletBinding()]
    param()

    foreach ($setting in $script:systemSettingsInfo) {
        [pscustomobject]@{
            key = [string]$setting.Key
            type = [string]$setting.Type
            value = Get-NamedSystemSetting ([string]$setting.Key)
            description = [string]$setting.Description
        }
    }
}

function Resolve-RestoreApp {
    param([Parameter(Mandatory=$true)][string]$Key)

    Assert-RestoreInitialized
    $app = Find-CatalogApp $Key
    if (-not $app) {
        throw "Application '$Key' was not found in catalog."
    }
    return $app
}

function Install-RestoreApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [ValidateSet('Auto','User','Machine')][string]$Scope = 'Auto',
        [string]$Source,
        [bool]$AutoInstallChocolatey = $true,
        [switch]$Reinstall
    )

    $app = Resolve-RestoreApp $Key

    if (-not $Reinstall) {
        $existing = @(Get-RestoreAppInventory -Keys @($Key) | Select-Object -First 1)
        if ($existing.Count -gt 0 -and $existing[0].installed) {
            return [pscustomobject]@{
                key = $Key
                action = 'install'
                ok = $true
                skipped = $true
                reason = 'Already installed'
            }
        }
    }

    $ok = Install-App `
        -App $app `
        -RequestedScope $Scope `
        -ForceSourceType $Source `
        -AutoInstallChocolatey $AutoInstallChocolatey

    return [pscustomobject]@{
        key = $Key
        action = 'install'
        ok = [bool]$ok
        skipped = $false
        reason = ''
    }
}

function Uninstall-RestoreApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [string]$Source
    )

    $app = Resolve-RestoreApp $Key

    $before = @(Get-RestoreAppInventory -Keys @($Key) | Select-Object -First 1)
    if ($before.Count -eq 0 -or -not $before[0].installed) {
        return [pscustomobject]@{
            key = $Key
            action = 'uninstall'
            ok = $true
            skipped = $true
            reason = 'Not installed'
        }
    }

    $ok = Uninstall-App -App $app -ForceSourceType $Source
    $after = @(Get-RestoreAppInventory -Keys @($Key) | Select-Object -First 1)
    $stillInstalled = ($after.Count -gt 0 -and [bool]$after[0].installed)

    $reason = ''

    if (-not $ok -and -not [string]::IsNullOrWhiteSpace([string]$script:LastUninstallReason)) {
        $reason = [string]$script:LastUninstallReason
    }
    elseif ($stillInstalled) {
        $reason = 'Still installed after uninstall command'
    }

    return [pscustomobject]@{
        key = $Key
        action = 'uninstall'
        ok = ([bool]$ok -and -not $stillInstalled)
        skipped = $false
        reason = $reason
    }
}

function Upgrade-RestoreApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [string]$Source
    )

    $app = Resolve-RestoreApp $Key
    $ok = Upgrade-App -App $app -ForceSourceType $Source

    return [pscustomobject]@{
        key = $Key
        action = 'upgrade'
        ok = [bool]$ok
    }
}

function Set-RestoreSystemComponent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][bool]$Enable
    )

    $component = Find-SystemComponent $Key
    if (-not $component) {
        throw "Unknown Windows component '$Key'."
    }

    $ok = Set-SystemComponent -Component $component -Enable $Enable

    return [pscustomobject]@{
        key = $Key
        action = $(if ($Enable) { 'enable' } else { 'disable' })
        ok = [bool]$ok
    }
}

function Set-RestoreSystemSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Value
    )

    $ok = Set-NamedSystemSetting -Key $Key -Value $Value

    return [pscustomobject]@{
        key = $Key
        value = $Value
        ok = [bool]$ok
    }
}

function Get-RestoreProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    return Read-Profile $Path
}

function Get-RestoreProfilePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    $profile = Read-Profile $Path
    return [pscustomobject]@{
        path = $profile.Path
        text = Get-ProfilePlanText $profile
        install = @($profile.Install | ForEach-Object { $_.Target })
        uninstall = @($profile.Uninstall | ForEach-Object { $_.Target })
        upgrade = @($profile.Upgrade | ForEach-Object { $_.Target })
        systemEnable = @($profile.SystemEnable)
        systemDisable = @($profile.SystemDisable)
        systemSettings = $profile.SystemSettings
    }
}

function Invoke-RestoreProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [ValidateSet('Auto','User','Machine')][string]$ScopeOverride,
        [switch]$Reinstall
    )

    Assert-RestoreInitialized
    $profile = Read-Profile $Path
    $results = @()

    $autoChoco = ConvertTo-Bool ([string](Get-ProfileSetting $profile 'AutoInstallChocolatey' 'true'))
    $scope = if ($ScopeOverride) {
        $ScopeOverride
    }
    else {
        [string](Get-ProfileSetting $profile 'DefaultScope' 'Auto')
    }

    foreach ($entry in $profile.Uninstall) {
        try {
            $resolved = Resolve-ProfileApp $entry
            $ok = Uninstall-App `
                -App $resolved.App `
                -ForceSourceType $resolved.ForceSourceType `
                -SourceOverride $resolved.SourceOverride

            $results += [pscustomobject]@{
                category='app'; key=$entry.Target; action='uninstall'; ok=[bool]$ok
            }
        }
        catch {
            $results += [pscustomobject]@{
                category='app'; key=$entry.Target; action='uninstall'; ok=$false; error=$_.Exception.Message
            }
        }
    }

    foreach ($key in $profile.SystemDisable) {
        try {
            $results += Set-RestoreSystemComponent -Key $key -Enable $false
        }
        catch {
            $results += [pscustomobject]@{
                category='system'; key=$key; action='disable'; ok=$false; error=$_.Exception.Message
            }
        }
    }

    foreach ($entry in $profile.SystemSettings.GetEnumerator()) {
        try {
            $results += Set-RestoreSystemSetting -Key $entry.Key -Value ([string]$entry.Value)
        }
        catch {
            $results += [pscustomobject]@{
                category='setting'; key=$entry.Key; action='set'; ok=$false; error=$_.Exception.Message
            }
        }
    }

    foreach ($key in $profile.SystemEnable) {
        try {
            $results += Set-RestoreSystemComponent -Key $key -Enable $true
        }
        catch {
            $results += [pscustomobject]@{
                category='system'; key=$key; action='enable'; ok=$false; error=$_.Exception.Message
            }
        }
    }

    # Snapshot installed state once for the profile install phase.
    $wingetInventory = Get-WingetInventory
    $chocoInventory = Get-ChocoInventory
    $arpEntries = @(Get-ArpEntries)
    $appxEntries = @(Get-AppxInventory)

    foreach ($entry in $profile.Install) {
        try {
            $resolved = Resolve-ProfileApp $entry
            $app = $resolved.App

            if (-not $Reinstall) {
                $state = Get-InstalledState `
                    -App $app `
                    -WingetPackages $wingetInventory.Packages `
                    -WingetText $wingetInventory.ListText `
                    -ChocoInventory $chocoInventory `
                    -ArpEntries $arpEntries `
                    -AppxEntries $appxEntries

                if ($state.Installed) {
                    $results += [pscustomobject]@{
                        category='app'; key=$entry.Target; action='install'; ok=$true; skipped=$true; reason='Already installed'
                    }
                    continue
                }
            }

            $ok = Install-App `
                -App $app `
                -RequestedScope $scope `
                -ForceSourceType $resolved.ForceSourceType `
                -SourceOverride $resolved.SourceOverride `
                -AutoInstallChocolatey $autoChoco

            $results += [pscustomobject]@{
                category='app'; key=$entry.Target; action='install'; ok=[bool]$ok; skipped=$false
            }
        }
        catch {
            $results += [pscustomobject]@{
                category='app'; key=$entry.Target; action='install'; ok=$false; error=$_.Exception.Message
            }
        }
    }

    foreach ($entry in $profile.Upgrade) {
        try {
            $resolved = Resolve-ProfileApp $entry
            $ok = Upgrade-App `
                -App $resolved.App `
                -ForceSourceType $resolved.ForceSourceType `
                -SourceOverride $resolved.SourceOverride `
                -AutoInstallChocolatey $autoChoco

            $results += [pscustomobject]@{
                category='app'; key=$entry.Target; action='upgrade'; ok=[bool]$ok
            }
        }
        catch {
            $results += [pscustomobject]@{
                category='app'; key=$entry.Target; action='upgrade'; ok=$false; error=$_.Exception.Message
            }
        }
    }

    return @($results)
}

function Test-RestoreCatalog {
    [CmdletBinding()]
    param()

    Assert-RestoreInitialized

    $errors = @()
    $warnings = @()
    $seen = @{}

    foreach ($app in $script:catalogApps) {
        $key = ([string]$app.key).ToLowerInvariant()

        if ($seen.ContainsKey($key)) {
            $errors += "Duplicate key: $($app.key)"
        }
        else {
            $seen[$key] = $true
        }

        if (-not $app.sources -or @($app.sources).Count -eq 0) {
            $errors += "No sources: $($app.key)"
        }

        foreach ($source in @($app.sources)) {
            if ($source.type -in @('winget','choco') -and [string]::IsNullOrWhiteSpace([string]$source.id)) {
                $errors += "Missing package ID: $($app.key) / $($source.type)"
            }

            if ($source.type -in @('portable','manual') -and [string]::IsNullOrWhiteSpace([string]$source.url)) {
                $errors += "Missing URL: $($app.key) / $($source.type)"
            }

            if ($source.type -eq 'github') {
                if ([string]::IsNullOrWhiteSpace([string]$source.repo)) {
                    $errors += "Missing GitHub repo: $($app.key)"
                }
                elseif ([string]$source.repo -notmatch '^[^/\s]+/[^/\s]+$') {
                    $errors += "Invalid GitHub repo (expected owner/repository): $($app.key) / $($source.repo)"
                }

                if ($source.installMode -and [string]$source.installMode -notin @('portable','installer')) {
                    $errors += "Invalid GitHub installMode: $($app.key) / $($source.installMode)"
                }

                if ($source.assetPattern -and $source.assetRegex) {
                    $errors += "GitHub source must use either assetPattern or assetRegex, not both: $($app.key)"
                }
            }
        }
    }

    return [pscustomobject]@{
        valid = ($errors.Count -eq 0)
        applicationCount = $script:catalogApps.Count
        errors = @($errors)
        warnings = @($warnings)
    }
}

function Get-RestoreDoctor {
    [CmdletBinding()]
    param()

    Assert-RestoreInitialized

    [pscustomobject]@{
        administrator = Test-RestoreAdministrator
        winget = [bool](Get-WingetPath)
        wingetPath = [string](Get-WingetPath)
        chocolatey = [bool](Get-ChocoPath)
        chocolateyPath = [string](Get-ChocoPath)
        catalogPath = $script:CatalogPath
        catalogApplications = $script:catalogApps.Count
        portableRoot = $script:portableRoot
        logPath = $script:logFile
        windowsPowerShell = Test-Path (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
    }
}



Export-ModuleMember -Function Initialize-RestoreCore,Test-RestoreAdministrator,Get-RestoreCatalog,Get-RestoreAppInventory,Get-RestoreSystemInventory,Get-RestoreSettingsInventory,Install-RestoreApplication,Uninstall-RestoreApplication,Upgrade-RestoreApplication,Set-RestoreSystemComponent,Set-RestoreSystemSetting,Get-RestoreProfile,Get-RestoreProfilePlan,Invoke-RestoreProfile,Test-RestoreCatalog,Get-RestoreDoctor
