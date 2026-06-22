# Changelog

All notable changes to Codex Status Bar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-06-22

### Added
- Initial release: macOS menu bar status indicator for the Codex CLI, driven entirely by Codex hooks.
- Original "prompt caret" identity: a terminal `>_` mark — a steady prompt at rest, and a loading-sweep-plus-breathing animation (8 frames) while Codex is thinking or running a tool, with a live elapsed turn timer. Rendered as alpha masks tinted in the brand accent, plus a gradient squircle app icon. No third-party logos or trademarks.
- An amber "Awaiting approval" dot when Codex fires a `PermissionRequest`.
- Session lifecycle without a close hook: launches on `SessionStart`, stays while a `codex` process is running (CLI, `codex exec`, or the app-server behind the desktop app and the VS Code extension), rests when idle, and quits once Codex fully closes (Codex has no `SessionEnd` event).
- One-time hook trust: Codex reviews command hooks before running them, so the indicator stays idle until you approve the bundled hooks on the next `codex` start (documented in the README).
- Accent (`#4D8FFF`) / System color toggle and an elapsed-timer toggle, persisted in preferences.
- Signed and notarized DMG so it opens without a Gatekeeper warning, plus a Codex plugin manifest for the plugin install path.
