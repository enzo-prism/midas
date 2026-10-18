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
- **Requirements:** macOS 14 or later; full Xcode 26 or later is preferred for builds and tests.

## New-user setup

Use [the setup guide](MIDAS_SETUP.md) for the current Services → Accounts → Overview flow,
multi-account Codex tracking, automatic estimates, and coverage limitations.

## Current features

The **0.48.1, build 127 candidate** removes inline partial-estimate notices and condenses Meta's
recorded-activity fallback in the overview. **Estimate details** retains full coverage and pricing
disclosures, and provider details retain the activity breakdown. Publication is pending.

**0.48.0, build 126** adds a compact native panel, SF Pro/SF Symbols, adaptive
system colors, and a macOS 26 Liquid Glass navigation capsule with an older-system/accessibility
fallback. Usage and Settings have native selectable sidebars. The signed, notarized release is
[v0.48.0-midas.1](https://github.com/enzo-prism/midas/releases/tag/v0.48.0-midas.1).

The overview keeps estimated AI token value, recorded tokens, per-provider dollars, remaining
capacity, and reset times visible. Local totals include enabled providers outside Favorites;
combined totals use the same shared source set on every Mac. Missing estimates stay unavailable;
coverage details explain incomplete history and unpriced usage. Different currencies stay
separate; estimates are not billed charges.
Anthropic billed spend stays separate to avoid counting activity twice.

Orbit shows total token spend beside one favorite provider’s capacity ring. Codex uses weekly
remaining and retains reset-credit details in the panel.
Cursor preserves actual usage pools and request counts. Meta uses observed plan limits when
available, with labeled recorded-activity baselines as fallback, and never drives a quota ring.
Private Tailscale hub or shared-folder sync, independent OpenAI account history, and DGX Spark's
recorded tokens and explicitly priced API-equivalent value retain the 0.47.x behavior. Unknown
models and incomplete token classes remain unpriced. See [hub setup](MIDAS_TAILSCALE_HUB.md).

See [Midas Air](MIDAS_AIR.md) for implementation boundaries and [Codex](codex.md) for provider
behavior. Orbit is the default; Ledger, Focus, Constellation, and Legacy remain available in
Settings → Display. The [menu-bar design research](MIDAS_MENU_BAR_DESIGN.md) records the alternatives and
implemented state behavior. Legacy restores the original icon preferences.

## Switch providers and update

In the native redesign, choose **More actions → Menu-bar provider** to change the Orbit provider.
This does not change which providers contribute to the total. **Settings → Display → Orbit provider**
provides the same preference.
Hover over Orbit to see 30-day token counts for the favorite and all enabled providers.

Choose **Check for Updates** from the panel’s More actions menu or Settings → About.
Developer ID Applications builds use Sparkle **Download → Install & Restart**. Development
builds open the latest signed GitHub ZIP instead. Builds older than 0.33.3 need a one-time
manual install from [Midas releases](https://github.com/enzo-prism/midas/releases).
See [the release procedure](MIDAS_RELEASE.md) before publishing; inherited upstream scripts are
not the Midas release path. A Sparkle release requires the Developer ID private key and the
`enzo-prism-midas` Keychain account — the certificate alone is not enough.

## Build and verify

With full Xcode selected, run from the repository root:

```sh
make check
swift test
./Scripts/package_app.sh release
```

The packaging script defaults to the Midas Developer ID identity (`L49MKXGVM4`); pass
`APP_TEAM_ID` and `APP_IDENTITY` only to override it for a different Mac.
See [Midas Air](MIDAS_AIR.md#local-rebuild) for the selected full Xcode installation, external
scratch paths, synthetic preview exports, and historical CLT-only limitations. Release validation
uses the canonical package; a focused or CLT-only pass does not establish a complete XCTest pass.

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

Left-click the status icon to open Midas Air. Use **Spend history** for the larger window.
In the native redesign, the date menu changes the value period without changing quota resets;
estimate coverage and usage-scope/sync details open inside the panel with Back navigation.
Right-click the icon, or choose **Provider actions & accounts…** inside the panel, for the
original provider menu and existing account actions. Provider account settings retain the
selected provider.

## Source updates versus releases

| Surface | Current |
| --- | --- |
| Overview refinement candidate | **0.48.1**, build **127**, publication pending |
| Last verified source on `main` | **0.48.0**, build **126** |
| Last verified GitHub latest / signed Sparkle feed | **0.48.0**, tag `v0.48.0-midas.1` |
| Last verified marketing-site download (`midas-ai.dev`) | **0.48.0**, tag `v0.48.0-midas.1` |

The app release and public archive were verified on October 17, 2026 (published October 18 UTC).
Website commit `e846d43` reached Vercel production Ready and passed all 18 browser checks against
`https://midas-ai.dev`. Installed-app state and receipt on another Mac remain separate checks.

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
