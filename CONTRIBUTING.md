# Contributing

Thanks for your interest in Codex Status Bar.

> This is an unofficial project and is **not affiliated with, endorsed by, or sponsored by OpenAI**.

## Prerequisites

- macOS 12+
- Xcode Command Line Tools (`xcode-select --install`)
- Node.js 22+

## Build

```bash
./build.sh            # builds build/Codex Status Bar.app
./build.sh --dmg      # also produces build/CodexStatusBar.dmg (signing/notarization optional)
```

## Test

```bash
node --test Tests/install.test.mjs
node --test Tests/update.test.mjs
swiftc Tests/logic_tests.swift Sources/SessionState.swift -o /tmp/csbt && /tmp/csbt
```

## Format / lint

A `.swift-format` config is checked in for editor formatting of new Swift code; the existing
files use a deliberately compact hand-tuned style, so a repo-wide reformat is intentionally
not enforced. JavaScript hook scripts are intentionally dependency-free; keep them so, and
syntax-check with `node --check hooks/*.js`.

## Pull requests

- Branch from `main`.
- Update `CHANGELOG.md` under the appropriate version/section.
- Changing any hook script changes the hooks Codex must trust, so users will be prompted to
  re-approve them on the next `codex` start — call this out in your PR if it applies.
- Make sure CI is green (build + tests).
