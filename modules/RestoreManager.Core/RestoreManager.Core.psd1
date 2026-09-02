# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Windows Restore Manager
#
@{
    RootModule = 'RestoreManager.Core.psm1'
    ModuleVersion = '3.2.7'
    GUID = 'a298b041-f564-4bf7-8f43-e02db4e19307'
    Author = 'Windows Restore Manager'
    Description = 'Backend/core module for Windows Restore Manager.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Initialize-RestoreCore',
        'Test-RestoreAdministrator',
        'Get-RestoreCatalog',
        'Get-RestoreAppInventory',
        'Get-RestoreSystemInventory',
        'Get-RestoreSettingsInventory',
        'Install-RestoreApplication',
        'Uninstall-RestoreApplication',
        'Upgrade-RestoreApplication',
        'Set-RestoreSystemComponent',
        'Set-RestoreSystemSetting',
        'Get-RestoreProfile',
        'Get-RestoreProfilePlan',
        'Invoke-RestoreProfile',
        'Test-RestoreCatalog',
        'Get-RestoreDoctor'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()

    PrivateData = @{
        PSData = @{
            # TODO: replace with the real public repository URL before pushing.
            ProjectUri = 'https://github.com/<owner>/<repository>'
            LicenseUri = 'https://www.gnu.org/licenses/gpl-3.0.html'
            Tags = @('Windows', 'Restore', 'WinGet', 'Chocolatey', 'TUI', 'PowerShell')
            ReleaseNotes = 'See CHANGELOG.md for the full change history.'
        }
    }
}
