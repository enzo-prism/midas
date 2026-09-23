---
summary: "Midas fork: current features, local build, verification, and source publishing."
read_when:
  - Onboarding to Midas
  - Building or verifying the fork
---

# Midas quick start

Midas is Enzo’s macOS app, forked from [CodexBar](https://github.com/steipete/CodexBar)
(created by Peter Steinberger and contributors, MIT license) and developed and shipped as its
own project. See the README’s *Midas and CodexBar* table for what is Midas identity and what is
inherited naming.

- **Midas source:** [enzo-prism/midas](https://github.com/enzo-prism/midas)
- **Midas issues:** [issue tracker](https://github.com/enzo-prism/midas/issues)
- **Requirements:** macOS 14 or later and a compatible Swift 6/Xcode toolchain.

## New-user setup

Use [the setup guide](MIDAS_SETUP.md) for the current Services → Accounts → Overview flow,
multi-account Codex tracking, automatic estimates, and coverage limitations.

## Current features

Midas Air provides a native overview panel, a resizable Usage window, sidebar settings, and
bundled provider logos. Token spend (API rates) and remaining capacity are prominent. The overview total
includes enabled providers outside Favorites and discloses missing estimates and mixed periods.
Different currencies stay separate; usage-rate estimates are not billed charges.

Orbit shows total token spend beside one favorite provider’s capacity ring. Codex uses weekly
remaining and retains reset-credit details in the panel.
Cursor preserves actual usage pools and request counts. Meta supports local Muse usage history
and cost estimates without inventing quota availability.

See [Midas Air](MIDAS_AIR.md) for implementation boundaries and [Codex](codex.md) for provider
behavior. Orbit is the default; Ledger, Focus, Constellation, and Legacy remain available in
Settings → Display. The [menu-bar design research](MIDAS_MENU_BAR_DESIGN.md) records the alternatives and
implemented state behavior. Legacy restores the original icon preferences.

## Switch providers and update

Open Midas and use the provider dropdown in the footer to change the menu-bar circle immediately.
The dropdown selects Orbit; it does not change which providers contribute to the spend total.
Hover over Orbit to see 30-day token counts for the favorite and all enabled providers.

Choose **Check for Updates** from the panel’s More actions menu or Settings → About.
Developer ID Applications builds use Sparkle **Download → Install & Restart**. Development
builds open the latest signed GitHub ZIP instead. Builds older than 0.33.3 need a one-time
manual install from [Midas releases](https://github.com/enzo-prism/midas/releases).
See [the release procedure](MIDAS_RELEASE.md) before publishing; inherited upstream scripts are
not the Midas release path. A Sparkle release requires the Developer ID private key and the
`enzo-prism-midas` Keychain account — the certificate alone is not enough.

## Build and verify

Run from the repository root:

```sh
make check
swift test
./Scripts/package_app.sh release
```

The packaging script defaults to the Midas Developer ID identity (`L49MKXGVM4`); pass
`APP_TEAM_ID` and `APP_IDENTITY` only to override it for a different Mac.
See [Midas Air](MIDAS_AIR.md#local-rebuild) for details.

For a focused Midas regression pass:

```sh
swift test --filter 'Midas|CodexWeeklyPreview|CodexResetCredits'
```

Follow [AGENTS.md](../AGENTS.md) for testing boundaries. Use fixtures and isolated stores;
do not initiate live provider probes, browser imports, or Keychain reads as routine tests.
Full-suite failures must be reported separately from passing focused tests.

Packaging produces `Midas.app` with a `Midas` executable, bundle identifier
`com.designprism.midas`, and Midas-owned app group, Keychain services, and storage folders.
`Sources/CodexBarCore/MidasIdentity.swift` defines these; the `CodexBar*` Swift targets and
helper binaries keep their inherited names so upstream changes can still be merged. To build,
test, package, and restart in one development workflow:

```sh
./Scripts/compile_and_run.sh
```

The gold application artwork can be regenerated with `swift Scripts/build_midas_icon.swift`.
Generated work files and app bundles are excluded from Git.

## Navigation

Left-click the status icon to open Midas Air. Use **Open Usage** for the larger window.
Right-click the icon, or choose **Provider actions & accounts…** inside the panel, for the
original provider menu and existing account actions. Provider account settings retain the
selected provider.

## Source updates versus releases

| Surface | Current |
| --- | --- |
| Source on `main` | **0.37.0**, build **109** (own identity) |
| Signed Sparkle / GitHub latest | **0.36.0**, tag `v0.36.0-midas.1` (CodexBar-era identity) |
| Marketing site (`midas-site` / Vercel `midas-by-prism`) | **0.36.0** download |

Push source changes to `enzo-prism/midas`. Review `git status` and the staged diff before
committing; exclude generated bundles, logs, credentials, and local configuration.
A source push does not publish an installer, GitHub release, or Sparkle update. Follow
[Midas releases](MIDAS_RELEASE.md). Do not use inherited `Scripts/release.sh` or the
upstream CodexBar appcast. Do not advertise an unsigned build as the public download.

Sparkle publication needs the **Developer ID Application** *private key* (the certificate
alone is not enough) and Keychain account `enzo-prism-midas`. Do not mint a new Sparkle key.

## Code map

- `Sources/CodexBar/`: app, Midas views, presentation models, and status-item controller.
- `Sources/CodexBarCore/`: providers, usage parsing, costs, and shared models.
- `Sources/CodexBarCLI/`: command-line output.
- `Tests/CodexBarTests/`: model, parser, rendering, and regression tests.
- `Scripts/`: formatting, build, and packaging helpers.
