# Changelog

All notable changes to Windows Restore Manager TUI are documented in this file.
The format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [3.2.8] - 2026-09-03

### Added

- New `installer` catalog source type for direct EXE/MSI installer packages
  downloaded over HTTP(S).
- The installer file is validated by its binary header (true EXE/MSI) before
  it is run; `.msi` packages are installed through `msiexec.exe /i`.
- Optional `installerArgs`, `runAsAdmin`, `successExitCodes` and `sha256`
  fields for installer sources. Reboot-requesting exit codes `1641`/`3010`
  are always treated as success.
- Direct installer sources can be used in `apps install`, `apps uninstall`
  (via a registered uninstall entry matching `registryNames`) and
  `apps upgrade`.
- Source override and profile source selection support an `installer|URL`
  type.
- Catalog validation for installer sources (HTTP/HTTPS URL and SHA-256 format).
- New `config/installer-source-example.json` documenting the `installer`
  source schema.

## [3.2.7] - 2026-09-03

### Fixed

- Main menu no longer blocks on `Console.ReadKey()`.
- Uses a non-blocking tick loop and coalesces queued identical navigation
  autorepeat events (`Up`, `Down`, `PageUp`, `PageDown`, `Home`, `End`) so the
  cursor stops scrolling once a held arrow key is released.
- A different key found while draining repeats is preserved as a pending input
  event rather than discarded.
- The coalesced input path is also used while CLI operations run, so `Esc`
  cancellation is not left behind navigation repeat events. Idle resize is
  detected on the UI tick and triggers a redraw without a key press.

## [3.2.6] - 2026

### Fixed

- Windows PowerShell 5.1 parse error in the GitHub source display string. The
  invalid interpolation is written as `@${release}:${asset}` so the colon cannot
  be parsed as part of a PowerShell scoped-variable reference.

## [3.2.5] - 2026

### Added

- Catalog entries can install directly from GitHub Releases (portable and
  installer modes).
- GitHub sources participate in `apps upgrade`.
- Profile source selection can force a GitHub source or use an ad-hoc
  `github|owner/repository` override.

## [3.2.4] - 2026

### Changed

- Installed Apps / Programs and Features matching is intentionally strict: an
  ARP `DisplayName` is accepted only when that exact name is listed in the
  application's `registryNames` array in `config/catalog.json`. No wildcards,
  fuzzy or implicit matching.

## [3.2.3] - 2026

### Changed

- Scope-aware WinGet: package IDs are classified with `winget list --scope user`
  / `--scope machine` and the detected scope is used during uninstall.
- Application install/uninstall/upgrade commands no longer force the whole CLI
  process to run as Administrator.

## [3.2.2] - 2026

### Fixed

- Uninstall now uses the same exact WinGet `PackageIdentifier` inventory used by
  the Installed status instead of parsing the human-readable `winget list`
  table.
- The TUI reports per-operation success/failure rather than displaying
  "operation completed" unconditionally.

## [3.2.1] - 2026

### Fixed

- Applications table no longer builds dynamic composite-format strings with the
  PowerShell `-f` operator. Column padding is handled by
  `Fit-Text`/`Join-TuiColumns`, fixing the "Error formatting a string" startup
  crash.

## [3.2.0] - 2026

### Changed

- The TUI no longer calls `Console.Clear()` on every navigation key or spinner
  frame; it updates only changed rows to avoid flicker.
- Uses real console dimensions and avoids the final physical column to prevent
  viewport scrolling from line wrapping.

### Added

- Crash handling: on an unhandled error the console is not cleared, the error
  and PowerShell stack trace remain visible, the TUI waits for Enter before
  exiting, and a crash log is written to `logs/tui-crash-*.log`.