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

## Current features

Midas Air provides a native overview panel, a resizable Usage window, sidebar settings, and
bundled provider logos. Estimated spend and remaining capacity are prominent. The overview total
includes enabled providers outside Favorites and discloses missing estimates and mixed periods.
Different currencies stay separate; usage-rate estimates are not billed charges.

Codex shows weekly remaining in one centered menu-bar capsule, plus reset-credit details.
Cursor preserves actual usage pools and request counts. Meta supports local Muse usage history
and cost estimates without inventing quota availability.

See [Midas Air](MIDAS_AIR.md) for implementation boundaries and [Codex](codex.md) for provider
behavior. The [menu-bar design research](MIDAS_MENU_BAR_DESIGN.md) is a proposal, not shipped UI.

## Build and verify

Run from the repository root:

```sh
make check
swift test
./Scripts/package_app.sh release
```

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

Push source changes to `enzo-prism/midas`. Review `git status` and the staged diff before
committing; exclude generated bundles, logs, credentials, and local configuration.
A source push does not publish an installer, GitHub release, or Sparkle update.

Midas packages disable upstream CodexBar update checks. The inherited release/Homebrew links
in the README refer to CodexBar. A future Midas binary release needs a deliberate fork-specific
release channel; consult [RELEASING.md](RELEASING.md) before configuring one.

## Code map

- `Sources/CodexBar/`: app, Midas views, presentation models, and status-item controller.
- `Sources/CodexBarCore/`: providers, usage parsing, costs, and shared models.
- `Sources/CodexBarCLI/`: command-line output.
- `Tests/CodexBarTests/`: model, parser, rendering, and regression tests.
- `Scripts/`: formatting, build, and packaging helpers.
