# PowerShell Console TUI

The TUI is a frontend only. It does not import `RestoreManager.Core` and does
not execute WinGet/Chocolatey directly. Every operation goes through
`RestoreCli.ps1 -Json`.

## Start

```powershell
.\Start-Tui.ps1
```

or:

```text
Start-TUI.cmd
```

`Start.cmd` also opens the TUI by default.

## Controls

Global:

- `Tab` / `Shift+Tab` — switch Applications/System/Profiles/Settings.
- arrows, `PgUp`, `PgDn`, `Home`, `End` — navigation.
- `R` — refresh current view.
- `Q` — quit.

Applications:

- `Space` or `Enter` — toggle selection.
- `I` — install selected missing applications.
- `U` — uninstall selected applications.
- `G` — upgrade selected applications.
- `M` — select all missing applications.
- `C` — clear selection.
- `/` — search.
- `F` — cycle category filter.
- `O` — cycle install scope Auto/User/Machine.

Windows components:

- `Space` — selection.
- `E` — enable selected.
- `D` — disable selected.

Profiles:

- `Enter` — show plan.
- `X` — execute selected profile.

System settings:

- `Enter` — edit the selected allow-listed setting.

## Non-blocking operation screen

Package scans/install/uninstall/upgrade/profile operations run in a separate
`powershell.exe` CLI process. The TUI stays active and redraws a spinner plus
elapsed time while the operation is in progress.

Press `Esc` during an operation to terminate the CLI process tree.
