---
summary: "Midas fork: current features, local build, verification, and source publishing."
read_when:
  - Onboarding to Midas
  - Building or verifying the fork
---

# Midas quick start

Midas is Enzo’s personal macOS fork of [CodexBar](https://github.com/steipete/CodexBar),
created by Peter Steinberger and contributors under the MIT license.

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

Signed local builds must pass the appropriate `APP_TEAM_ID` and `APP_IDENTITY`; the packaging
script inherits upstream signing defaults. Preserve the identity used by an existing installation.
See [Midas Air](MIDAS_AIR.md#local-rebuild) for details.

For a focused Midas regression pass:

```sh
swift test --filter 'Midas|CodexWeeklyPreview|CodexResetCredits'
```

Follow [AGENTS.md](../AGENTS.md) for testing boundaries. Use fixtures and isolated stores;
do not initiate live provider probes, browser imports, or Keychain reads as routine tests.
Full-suite failures must be reported separately from passing focused tests.

Packaging produces `CodexBar.app` with the Midas display name. Bundle identifiers, executable
name, storage, and account identity are intentionally retained. To build, test, package, and
restart in one development workflow:

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
| Source on `main` | **0.35.3**, build **106** |
| Signed Sparkle / GitHub latest | **0.35.2**, tag `v0.35.2-midas.1` |
| Marketing site (`midas-site` / Vercel `midas-by-prism`) | **0.35.2** download |

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
