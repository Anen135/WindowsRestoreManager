# Windows Restore Manager TUI 3.2.7

This package contains only the backend/CLI and the PowerShell console TUI.
The WPF GUI has been removed from this distribution.

## Start

From PowerShell:

```powershell
.\Start.cmd
```

or directly:

```powershell
.\tui\RestoreTui.ps1
```

For normal application management, start the TUI from a normal PowerShell window.
Windows feature/system operations still require Administrator privileges.

## Rendering changes in 3.2

The TUI no longer calls `Console.Clear()` on every navigation key or spinner
frame. It maintains a previous frame and updates only changed rows.

This avoids the full-screen blink/flicker that occurred in 3.1.

It also uses the real console dimensions and intentionally avoids the final
physical column, preventing line wrapping from causing viewport scrolling.

## Crash handling

If an unhandled TUI error occurs:

- the console is not cleared;
- the error and PowerShell stack trace remain visible;
- the TUI waits for Enter before exiting;
- a crash log is written to `logs\tui-crash-*.log`.

## Architecture

```text
RestoreTui.ps1
      |
      | JSON
      v
RestoreCli.ps1
      |
      v
RestoreManager.Core
      |
      +-- WinGet
      +-- Chocolatey
      +-- portable packages
      +-- Windows features/settings
```

The TUI does not contain package-manager logic.


## 3.2.1 — PowerShell 5.1 table formatter fix

The Applications table no longer builds dynamic composite-format strings with
PowerShell's `-f` operator. Column padding is handled by `Fit-Text` through the
`Join-TuiColumns` helper.

This fixes the startup crash:

```text
Error formatting a string: Input string was not in a correct format.
at Draw-Apps
```


## 3.2.2 — uninstall fix

Uninstall now uses the same exact WinGet `PackageIdentifier` inventory used by
the Installed status. It no longer depends on parsing the human-readable
`winget list` table before attempting removal.

For WinGet packages the backend now:

1. confirms the exact package ID is installed;
2. runs `winget uninstall --id <id> --exact`;
3. refreshes inventory;
4. reports success only when the package is no longer detected.

For Chocolatey packages it similarly verifies the application after Chocolatey
returns. If Chocolatey only removes package metadata while the native
application remains, the backend can continue to another configured route.

The TUI reports per-operation success/failure rather than displaying
"operation completed" unconditionally.


## 3.2.3 — scope-aware WinGet

Run the TUI from a normal PowerShell window for application management.

The backend classifies exact WinGet PackageIdentifiers with:

```text
winget list --scope user
winget list --scope machine
```

and uses the detected scope during uninstall:

```text
winget uninstall --id <id> --exact --scope user
winget uninstall --id <id> --exact --scope machine
```

Application install/uninstall/upgrade commands no longer force the whole CLI
process to run as Administrator. Windows feature/system operations still require
Administrator privileges.


## 3.2.4 — exact declared Windows registry names

Windows Installed Apps / Programs and Features is again a supported installed-state source.
It is intentionally strict: an ARP `DisplayName` is accepted only when that exact name is
listed in the application's `registryNames` array in `config/catalog.json`.

Matching is case-insensitive but otherwise exact. The detector does not use `Contains`,
wildcards, fuzzy matching, punctuation normalization, token matching, or implicit matching
against the catalog `name` property.

Example:

```json
"registryNames": [
  "Opera GX",
  "Opera GX Stable"
]
```

This can detect a manually installed Opera GX even when `winget export` does not map it to
`Opera.OperaGX`, without allowing `Opera`, `Opera Stable`, or another similar product to match.


## 3.2.5 — GitHub Releases source

Catalog entries can now install directly from GitHub Releases.

Portable example:

```json
{
  "type": "github",
  "repo": "owner/repository",
  "release": "latest",
  "assetPattern": "*windows*x64*.zip",
  "installMode": "portable",
  "priority": 30
}
```

Installer example:

```json
{
  "type": "github",
  "repo": "owner/repository",
  "release": "latest",
  "assetRegex": "(?i)setup.*x64\\.exe$",
  "installMode": "installer",
  "installerArgs": ["/S"],
  "priority": 30
}
```

Fields:

- `repo`: required GitHub `owner/repository`.
- `release`: `latest` (default) or exact release tag.
- `assetPattern`: PowerShell wildcard for release asset filename.
- `assetRegex`: regex selector; do not use together with `assetPattern`.
- `installMode`: `portable` (default) or `installer`.
- `installerArgs`: argument array for EXE/MSI installer mode.
- `priority`: normal source fallback priority.

If neither asset selector is supplied, WRM accepts `.zip`, `.exe`, and `.msi`
assets only and requires exactly one match. Ambiguous matches fail safely.

For public repositories no GitHub token is required. If `GITHUB_TOKEN` is
present in the environment, WRM uses it for GitHub REST API/download requests.

Portable GitHub installs use the existing managed portable marker and therefore
support uninstall. Installer-mode GitHub sources use the exact declared
`registryNames` entry and its Windows registered uninstaller.

GitHub sources also participate in `apps upgrade`: WRM resolves the configured
release again and installs the selected asset.

Profile source selection supports:

```ini
some-catalog-app = github
```

to force an already configured GitHub source, and:

```ini
custom-tool = github|owner/repository
```

for a simple ad-hoc public repository. For ad-hoc repositories with multiple
release assets, defining the full source in `catalog.json` is recommended so an
explicit asset selector can be used.


## 3.2.6 — Windows PowerShell 5.1 GitHub source parser fix

Fixed a PowerShell 5.1 parse error in the GitHub source display string.
The invalid interpolation `@$release:$asset` is now written as
`@${release}:${asset}`, so the colon cannot be parsed as part of a
PowerShell scoped-variable reference.


## 3.2.7 — input autorepeat queue fix

The main menu no longer blocks on `Console.ReadKey()`.

It now uses a non-blocking tick loop and coalesces already queued identical
navigation autorepeat events (`Up`, `Down`, `PageUp`, `PageDown`, `Home`, `End`).
This prevents the cursor from continuing to scroll after a held arrow key has
already been released.

A different key found while draining repeats is preserved as a pending input
event rather than discarded.

The same coalesced input path is used while CLI operations are running, so `Esc` cancellation is not left behind navigation repeat events. Idle resize is detected on the UI tick and triggers a redraw without requiring a key press.
