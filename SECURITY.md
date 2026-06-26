# Security Policy

## Reporting a vulnerability

Please report security issues privately via GitHub's **Private Vulnerability Reporting**:
open the repository's **Security** tab → **Report a vulnerability**. Do not open a public
issue for security problems.

## What the app does on your machine

Codex Status Bar installs Codex hooks that run small Node scripts on Codex lifecycle events.
Those scripts:

- Read `session_id`, `cwd` (basename only), `tool_name`, and `transcript_path` from the hook payload.
- Write status files under `~/.codex/statusbar/` only. They make no network requests.
- Shell out only to fixed, argument-quoted commands (`ps`, `pgrep`, `pkill`, `open`); `node` is
  resolved from PATH in the plugin manifest and pinned to the app's `process.execPath` by the installer.

Codex reviews command hooks before running them, so the indicator stays idle until you approve
the hooks on the next `codex` start (a one-time step per version).

## Supported versions

Only the latest released version receives fixes.
