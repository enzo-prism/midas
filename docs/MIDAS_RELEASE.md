# Midas releases

Midas releases belong exclusively to [enzo-prism/midas](https://github.com/enzo-prism/midas/releases).
The inherited `.mac-release.env`, `Scripts/release.sh`, and `Scripts/sign-and-notarize.sh` target
upstream CodexBar and must not be used unchanged to publish this fork.

## Current distribution

The current Midas distribution is version 0.33.2, build 84, tagged `v0.33.2-midas.1`.
Its downloadable app is for Apple Silicon Macs running macOS 14 or later. The bundle directory
and executable retain `CodexBar` for compatibility; the app's displayed name is Midas.

Midas keeps upstream Sparkle updates disabled. Install this release manually from GitHub.
No upstream Homebrew tap or appcast is updated. The inherited CLI release workflow automatically
runs only for upstream releases; fork maintainers may still invoke its artifact-only manual mode.

## 0.33.2 changes

- Replaces “Estimated spend” with “Token spend (API rates)” in provider cards, totals,
  menu-bar tooltips, and accessibility descriptions.
- Keeps provider-metered values distinct and preserves the explanation that API-rate values
  are estimates, not billed charges. Usage calculations and remaining-capacity behavior are unchanged.
- Validated with 34 focused presentation/layout tests, strict lint, and light/dark native fixtures.

## Release procedure

1. Run `make check` and the relevant native/menu regression tests. Inspect light/dark native fixtures.
2. Set the next build number in `version.env`, commit the reviewed source, and push `main`.
3. Build with `APP_TEAM_ID` and `APP_IDENTITY` matching the installed Midas developer signature:
   `APP_TEAM_ID=... APP_IDENTITY='Developer ID Application: ...' ./Scripts/package_app.sh release`.
4. Verify with `codesign --verify --deep --strict CodexBar.app` and inspect the timestamp/team.
5. Create a temporary ZIP using `ditto --norsrc -c -k --keepParent`, then submit it with
   `asc notarization submit --file <zip>`. Use `asc notarization status --id <id>` until accepted.
6. Staple with `xcrun stapler staple CodexBar.app`, then run `xcrun stapler validate` and
   `spctl --assess --type execute --verbose CodexBar.app`.
7. Create a new final ZIP of the stapled app and a SHA-256 checksum. Never reuse the unstapled ZIP
   for distribution. Publish against the exact tested commit in `enzo-prism/midas` with an explicit
   architecture label. Include license notices and the existing bundled credits.
8. Download the published asset, verify its SHA-256, and inspect the extracted app signature/ticket.
   Extract into a clean temporary directory outside Documents to avoid File Provider metadata
   modifying signed bundles. Restart the local app from the same validated bundle and confirm its process remains running.

Keep signed archives and signing credentials on internal encrypted storage. Do not publish logs,
provider account data, keys, or local settings. A source push, a signed build, an accepted Apple
submission, and a verified public download are separate verification steps.
