# Midas releases

Midas releases belong exclusively to [enzo-prism/midas](https://github.com/enzo-prism/midas/releases).
The inherited `.mac-release.env`, `Scripts/release.sh`, and `Scripts/sign-and-notarize.sh` target
upstream CodexBar and must not be used unchanged to publish this fork.

## Current distribution

Source on `main` is version **0.37.1**, build **110**. 0.37.0 (build 109) was the first build with
Midas’s own identity: bundle identifier `com.designprism.midas`, `Midas.app` with a `Midas` executable, team
`L49MKXGVM4`, its own app group, Keychain services, `~/Library/*/Midas` folders, and Sparkle feed.
Everything is defined once in `Sources/CodexBarCore/MidasIdentity.swift` and mirrored by
`Scripts/package_app.sh`.

The last **signed, notarized, Sparkle-published** binary is **0.37.0**, build **109**, tagged
`v0.37.0-midas.1`; 0.36.0 (build 108) was the last CodexBar-identity build. Check GitHub releases for live
binary status. The downloadable app is for Apple Silicon Macs running macOS 14 or later.

### Update feeds after 0.37.0

Sparkle refuses to install an update whose bundle identifier differs from the running app, so
0.33.3–0.36.0 clients cannot update themselves to 0.37.0. Every latest stable release therefore
ships two feeds, both written by `Scripts/make_midas_appcast.py`:

- `Midas-appcast-arm64-v2.xml` — the real feed for the Midas identity (0.37.0+): signed enclosure.
- `Midas-appcast-arm64.xml` — the legacy feed (`--informational`): no enclosure, a link to the
  release page, and a note asking for a one-time manual download. Keep publishing it until the
  0.35.x install base is gone.

Installed Midas reads `/releases/latest/download/<feed>`. Users who install 0.37.0 manually keep
their settings (adopted on first launch) and update automatically from then on. Widgets must be
re-added once because the app identity changed.

## 0.37.1 changes

Version 0.37.1, build 110, adopts cache items from the CodexBar-era cache service
(`com.steipete.codexbar.cache`) into `com.designprism.midas.cache` on first use. 0.37.0 adopted only
the main Keychain service, so cached browser sessions such as `cookie.cursor` were orphaned and
Cursor showed Needs attention. Each item is attempted once; macOS may ask to allow the read.

## 0.37.0 changes

Version 0.37.0, build 109, moves Midas to its own product identity and adopts pre-0.37.0 data on
first launch (preferences, storage folders, app group, and lazily the Keychain items). See
[the changelog](../CHANGELOG.md).

## 0.36.0 changes

Version 0.36.0, build 108:

- **Claude limits:** the Air overview pins Claude's **5-hour limit** and **Weekly limit** bars
  (`MidasClaudeLimits`), titled by window length.
- **Anthropic provider:** organization billed spend via the Admin API (`CostProvenance.vendorBilled`),
  shown per provider and excluded from the estimate total.
- **Settings:** now an AppKit window owned by the app delegate (`SettingsWindowController`), replacing the
  hidden SwiftUI keepalive window that macOS 27 could tear down, which left Settings clicks with no effect.

## 0.35.4 changes

Version 0.35.4, build 107, updates Sparkle to 2.10.0 (Golden Gate compatibility release)
and KeyboardShortcuts to 3.1.0 (Swift 6.3 release-build crash fix), and clears the
format/lint gate. No behavior changes.

## 0.35.3 changes

Version 0.35.3, build 106, expands the spend-period list and estimate-coverage details inline so
Last 30 days → This month and Partial total do not abort on macOS 27, hydrates cached Codex
weekly usage when managed accounts omit `workspaceAccountID`, and offers the public signed ZIP
from Check for Updates when Sparkle cannot run. Period math is unchanged.

## 0.35.2 changes

Version 0.35.2, build 105, adds per-account Codex banked reset counts, explicit missing and stale
reading states, and fresh menu-bar pop-up anchoring on every opening. The published archive and
signed update feed passed public checksum, signature, and notarization verification.

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
4. Verify with `codesign --verify --deep --strict Midas.app` and inspect the timestamp/team.
5. Create a temporary ZIP using `ditto --norsrc -c -k --keepParent`, then submit it with
   `asc notarization submit --file <zip>`. Use `asc notarization status --id <id>` until accepted.
6. Staple with `xcrun stapler staple Midas.app`, then run `xcrun stapler validate` and
   `spctl --assess --type execute --verbose Midas.app`.
7. Create a new final ZIP of the stapled app and a SHA-256 checksum. Never reuse the unstapled ZIP
   for distribution. Prepare the release against the exact tested commit in `enzo-prism/midas`
   with an explicit architecture label. Include license notices and the existing bundled credits.
8. Sign the final app ZIP using Sparkle’s `sign_update --account enzo-prism-midas`.
   The private key remains in the login Keychain; never export it into the repository.
   Generate `Midas-appcast-arm64-v2.xml` using `Scripts/make_midas_appcast.py` with that signature,
   the exact version/build/tag, and the final archive, and `Midas-appcast-arm64.xml` with
   `--informational` for pre-0.37.0 clients. Include both feeds in **every** latest stable
   GitHub release: installed Midas reads `/releases/latest/download/<feed>`.
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
