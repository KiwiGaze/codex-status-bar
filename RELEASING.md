# Releasing

1. Update `CHANGELOG.md`: move changes under a new `## [x.y.z] - YYYY-MM-DD` section and add the release tag link (`[x.y.z]: https://github.com/KiwiGaze/codex-status-bar/releases/tag/vx.y.z`), matching CHANGELOG's existing style.
2. Bump the version: `VERSION=x.y.z` is read by `build.sh`; confirm `.codex-plugin/plugin.json` matches.
3. Build the signed, notarized, universal DMG:
   ```bash
   export TEAM_ID=<your Developer ID team id>
   NOTARY_PROFILE=codex-statusbar VERSION=x.y.z ./build.sh --dmg
   ```
4. Validate the artifact:
   ```bash
   xcrun stapler validate build/CodexStatusBar.dmg
   spctl -a -t open --context context:primary-signature build/CodexStatusBar.dmg
   lipo -info "build/Codex Status Bar.app/Contents/MacOS/CodexStatusBar"   # x86_64 arm64
   ```
5. Tag and publish (asset MUST be named `CodexStatusBar.dmg`):
   ```bash
   git tag vx.y.z && git push origin vx.y.z
   gh release create vx.y.z build/CodexStatusBar.dmg --title vx.y.z --notes-from-tag
   ```
