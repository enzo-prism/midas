# Midas releases

Midas releases belong exclusively to [enzo-prism/midas](https://github.com/enzo-prism/midas/releases).
The inherited `.mac-release.env`, `Scripts/release.sh`, and `Scripts/sign-and-notarize.sh` target
upstream CodexBar and must not be used unchanged to publish this fork.

## Current distribution

As of September 12, the published distribution is version 0.35.1, build 104, tagged
`v0.35.1-midas.1`, from commit `4691c801db257ca5f77bbce831ef58b9a8769821`.
The signed archive, notarization ticket, public download, and signed update feed were verified.
Check GitHub releases for live status.
Its downloadable app is for Apple Silicon Macs running macOS 14 or later. The bundle directory
and executable retain `CodexBar` for compatibility; the app's displayed name is Midas.

Midas 0.33.3 enables Sparkle using a Midas-only feed and Ed25519 key. In the panel, click
**Check for Updates**, then follow **Download → Install & Restart**. Automatic checks can be
controlled in Settings → About. Older builds need one manual install to bootstrap this channel.
The upstream CodexBar feed remains disabled. Debug, ad-hoc, and Intel builds cannot use this
Apple Silicon channel.
No upstream Homebrew tap or appcast is updated. The inherited CLI release workflow automatically
runs only for upstream releases; fork maintainers may still invoke its artifact-only manual mode.

## 0.35.1 changes

Version 0.35.1, build 104, is published as `v0.35.1-midas.1`. It improves the spend-period dropdown
with direct anchoring, distinct interaction states, date previews, keyboard controls, and validated
historical-month choices. See [setup](MIDAS_SETUP.md#choosing-a-spend-period).

## 0.35.0 changes

See [the changelog](../CHANGELOG.md) and [setup and estimate coverage](MIDAS_SETUP.md).
This release combines the focused spend design, multi-account Codex cloud usage, automatic
pricing and optional iCloud calibration sharing, and resumable three-step onboarding.

## 0.33.6 changes

- Brighten the pixel crown with a crisp highlight, warm trail, and a single-point sparkle.
- Give the crown a longer rest between loops; Reduce Motion keeps it static.

## 0.33.5 changes

- Size menu-bar items to their visible content, removing unused horizontal space.
- Preserve readable amounts and provider indicators across Orbit, Ledger, Focus, and Constellation.

## 0.33.4 changes

- Sharper native SF typography across the panel, provider details, and Usage window.
- A gold pixel crown with a subtle looping shimmer in the panel header; Reduce Motion keeps it static.
- A fixed footer for Favorite provider and Check for Updates, with an explicit selector label.

## 0.33.3 changes

- Switch the menu-bar circle provider directly from the panel’s provider dropdown.
- Add a visible Check for Updates action using Sparkle’s standard signed download/install flow.
- Ship Orbit, the selected-provider ring, and concise 30-day token-count tooltips.

## 0.33.2 changes

- Replaces “Estimated spend” with “Token spend (API rates)” in provider cards, totals,
  menu-bar tooltips, and accessibility descriptions.
- Keeps provider-metered values distinct and preserves the explanation that API-rate values
  are estimates, not billed charges. Usage calculations and remaining-capacity behavior are unchanged.
- Validated with 34 focused presentation/layout tests, strict lint, and light/dark native fixtures.

## Release procedure

1. Run `make check` and the relevant native/menu regression tests. Inspect light/dark native fixtures.
2. Set the next build number in `version.env`, commit the reviewed source, and push `main`.
3. Confirm `security find-identity -v -p codesigning` lists a valid **Developer ID Application**
   identity with its private key. Apple Development and Apple Distribution identities are not
   substitutes for outside-the-App-Store distribution. Stop binary publication if it is missing.
   Build with `APP_TEAM_ID` and `APP_IDENTITY` matching the installed Midas developer signature:
   `APP_TEAM_ID=... APP_IDENTITY='Developer ID Application: ...' ./Scripts/package_app.sh release`.
4. Verify with `codesign --verify --deep --strict CodexBar.app` and inspect the timestamp/team.
5. Create a temporary ZIP using `ditto --norsrc -c -k --keepParent`, then submit it with
   `asc notarization submit --file <zip>`. Use `asc notarization status --id <id>` until accepted.
6. Staple with `xcrun stapler staple CodexBar.app`, then run `xcrun stapler validate` and
   `spctl --assess --type execute --verbose CodexBar.app`.
7. Create a new final ZIP of the stapled app and a SHA-256 checksum. Never reuse the unstapled ZIP
   for distribution. Prepare the release against the exact tested commit in `enzo-prism/midas`
   with an explicit architecture label. Include license notices and the existing bundled credits.
8. Sign the final app ZIP using Sparkle’s `sign_update --account enzo-prism-midas`.
   The private key remains in the login Keychain; never export it into the repository.
   Generate `Midas-appcast-arm64.xml` using `Scripts/make_midas_appcast.py` with that signature,
   the exact version/build/tag, and the final archive. Include this feed in **every** latest stable
   GitHub release: installed Midas reads `/releases/latest/download/Midas-appcast-arm64.xml`.
   Verify the archive signature with `sign_update --account enzo-prism-midas --verify` before publishing.
   Sign the XML feed too with `sign_update --account enzo-prism-midas <feed.xml>`, then verify it
   using `--verify`. Generate final checksums after signing. Upload the archive, feed, checksums,
   and matching dSYM as a draft; verify downloaded draft assets before publishing it as latest.
   Never replace a release asset after signing it. Do not publish Intel archives on this feed.
9. Download the published asset, verify its SHA-256, and inspect the extracted app signature/ticket.
   Extract into a clean temporary directory outside Documents to avoid File Provider metadata
   modifying signed bundles. Restart the local app from the same validated bundle and confirm its process remains running.

Keep signed archives and signing credentials on internal encrypted storage. Do not publish logs,
provider account data, keys, or local settings. A source push, a signed build, an accepted Apple
submission, and a verified public download are separate verification steps.

## Website publication

The marketing site is a separate repository at `enzo-prism/midas-site` (Vercel project
`midas-by-prism`, production domain `midas-ai.dev`). Verify its actual Git remote before pushing.
Update version labels, download URLs, and the Updates entry only after the matching GitHub
archive is public and verified. Build and test the site, deploy production, then follow the
public download link and confirm it retrieves the exact signed archive. Do not advertise a
release candidate as available while notarization or signing is blocked.
