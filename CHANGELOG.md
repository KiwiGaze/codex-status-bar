# Changelog

All notable changes to Codex Status Bar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## [0.2.2] - 2026-06-26

### Changed
- The release binary is now a universal build (Intel and Apple Silicon) targeting macOS 12, so it runs on every Mac the project advertises instead of only the build machine's architecture and OS version.
- Documented that the build script, hook scripts, and menu bar app derive from the MIT-licensed claude-status-bar by Mick Cesanek; the upstream license is reproduced in NOTICE and bundled into the app and DMG.

### Fixed
- Global Codex app-server liveness no longer proves that a specific status-bar session is still active. Desktop/app-server-backed sessions now age out of the visible active state unless a fresh hook update arrives.
- Bundled hook scripts reinstall when their resource fingerprint changes, even if a local development build keeps the same app version string.
- Session ids containing path-traversal segments ("." / "..") are sanitized before being used as state-file names.
- The hook timeout log is appended to rather than overwritten, preserving prior timeout records.

## [0.2.1] - 2026-06-23

### Fixed
- The elapsed timer no longer keeps counting after a session ends abnormally — quitting the VS Code/IDE extension or the desktop app, or closing the terminal, mid-turn. Codex fires no `Stop` hook on an abnormal exit, so the state file was stranded at a "thinking"/"tool" state with a live clock and the indicator kept advancing for up to 15 minutes (until the 900s stale window) whenever another `codex` process kept the app alive. The hook now records the owning `codex` process id, and the app drops any in-progress session whose owner has exited — within one poll — while leaving genuinely long, quiet turns running. Updating changes the hooks, so approve them again on the next `codex` start.

## [0.1.0] - 2026-06-22

### Added
- Initial release: macOS menu bar status indicator for the Codex CLI, driven entirely by Codex hooks.
- Original "prompt caret" identity: a terminal `>_` mark — a steady prompt at rest, and a loading-sweep-plus-breathing animation (8 frames) while Codex is thinking or running a tool, with a live elapsed turn timer. Rendered as alpha masks tinted in the brand accent, plus a gradient squircle app icon. No third-party logos or trademarks.
- An amber "Awaiting approval" dot when Codex fires a `PermissionRequest`.
- Session lifecycle without a close hook: launches on `SessionStart`, stays while a `codex` process is running (CLI, `codex exec`, or the app-server behind the desktop app and the VS Code extension), rests when idle, and quits once Codex fully closes (Codex has no `SessionEnd` event).
- One-time hook trust: Codex reviews command hooks before running them, so the indicator stays idle until you approve the bundled hooks on the next `codex` start (documented in the README).
- Accent (`#4D8FFF`) / System color toggle and an elapsed-timer toggle, persisted in preferences.
- Signed and notarized DMG so it opens without a Gatekeeper warning, plus a Codex plugin manifest for the plugin install path.
