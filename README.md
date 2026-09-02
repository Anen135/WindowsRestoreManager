# Windows Restore Manager

[![License: GPL-3.0-or-later](https://img.shields.io/badge/License-GPL--3.0--or--later-blue.svg)](https://www.gnu.org/licenses/gpl-3.0.html)

Windows Restore Manager (WRM) is a Windows restore/setup automation tool built
in PowerShell. It exposes state and operations through a backend CLI
(`RestoreCli.ps1`) and drives a fast console TUI (`tui/RestoreTui.ps1`) for
installing, uninstalling, and upgrading applications, toggling Windows optional
features and settings, and running declarative restore profiles.

This distribution contains only the backend/CLI and the PowerShell console TUI.
No WPF GUI is included.

> **Note (3.2.7):** for application management, start the TUI from a normal
> PowerShell window. Windows feature/system operations still require an
> elevated (Administrator) console.

## Features

- Install / uninstall / upgrade applications through **WinGet**,
  **Chocolatey**, **portable packages** and **GitHub Releases**.
- Scope-aware WinGet handling (`user` vs `machine`).
- Enable/disable Windows optional features (SSH client, WSL, Hyper-V, telnet, ...).
- Toggle allow-listed Windows settings (file extensions, hidden files,
  developer mode, dark mode, long paths, clipboard history, ...).
- Declarative restore profiles (`config/profiles/*.conf`).
- Fast non-blocking console TUI with incremental rendering (no full-screen
  flicker) and crash logging.

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 or later
- Optional: [WinGet](https://github.com/microsoft/winget-cli) and/or
  [Chocolatey](https://chocolatey.org/) for package operations

## Getting started

```bash
git clone <your-repository-url>
cd WindowsRestoreManager-TUI
```

Start the TUI:

```powershell
.\Start.cmd
```

or directly:

```powershell
.\tui\RestoreTui.ps1
```

Get CLI help:

```powershell
.\RestoreCli.ps1 help
```

## Configuration

- `config/catalog.json` — application catalog with install sources.
- `config/install.conf` — default profile (what to remove / install / upgrade,
  which Windows components and settings to change).
- `config/profiles/*.conf` — additional restore profiles.
- `config/catalog.schema.json` — JSON schema for the catalog.
- `protocol/restore-cli-json-v1.schema.json` — JSON protocol between the CLI
  and the TUI.
- `config/github-source-example.json` — example of a GitHub Releases source.

Catalog sources support WinGet, Chocolatey, portable downloads and GitHub
Releases.

## Architecture

```text
RestoreTui.ps1
      |
      | JSON (restore-cli-json-v1)
      v
RestoreCli.ps1
      |
      v
RestoreManager.Core
      |
      +-- WinGet
      +-- Chocolatey
      +-- portable packages
      +-- GitHub Releases
      +-- Windows features/settings
```

The TUI is a frontend only. It does not import `RestoreManager.Core` and never
calls WinGet/Chocolatey directly; every operation goes through
`RestoreCli.ps1 -Json`.

See `tui/README.md` for the TUI key bindings and behavior.

## Repository layout

| Path | Description |
| ---- | ----------- |
| `RestoreCli.ps1` | Backend CLI |
| `tui/` | PowerShell console TUI |
| `modules/RestoreManager.Core/` | Core worker module |
| `config/` | Catalog, default profile, profiles |
| `protocol/` | JSON protocol schema |
| `Start.cmd`, `Start-TUI.cmd`, `Start-Tui.ps1`, `wrm.cmd` | Launchers |

## Changelog

See [CHANGELOG.md](./CHANGELOG.md).

## License

Licensed under the **GNU General Public License v3.0 or later**. See
[LICENSE](./LICENSE) for the full license text.