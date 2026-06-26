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
- Shell out only to fixed, shell-free commands (run via `execFile`/`spawn`, not a shell): `ps`,
  `pgrep`, `pkill`, and `open`; `node` is resolved from PATH in the plugin manifest and pinned to
  the app's `process.execPath` by the installer.

The menu bar app itself:

- On first launch (and after a hook change) runs `/bin/zsh -lc` with an augmented PATH
  (`/opt/homebrew/bin:/usr/local/bin`) to locate `node` and run the bundled `install.js`.
- Calls `/usr/bin/pgrep` to detect running `codex` processes, and `/usr/bin/osascript` only when
  you pick "Open Codex" and the Codex app is not found (to open `codex` in Terminal).

Codex reviews command hooks before running them, so the indicator stays idle until you approve
the hooks on the next `codex` start (a one-time step per version).

## Supported versions

Only the latest released version receives fixes.
