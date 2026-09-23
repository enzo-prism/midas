# Repository Guidelines

## Project Structure & Modules
- `Sources/CodexBar`: Swift 6 menu bar app (usage/credits probes, icon renderer, settings). Keep changes small and reuse existing helpers.
- `Tests/CodexBarTests`: XCTest coverage for usage parsing, status probes, icon patterns; mirror new logic with focused tests.
- `Scripts`: build/package helpers (`package_app.sh`, `sign-and-notarize.sh`, `make_appcast.sh`, `build_icon.sh`, `compile_and_run.sh`). Release wrappers call `Scripts/mac-release`, which resolves `MAC_RELEASE_TOOL` or the shared `agent-scripts` checkout.
- `docs`: release notes and process (`docs/RELEASING.md`, screenshots). Root-level zips/appcast are generated artifacts—avoid editing except during releases.

## Identity: Midas is its own product, forked from CodexBar

- Midas is a fork of [steipete/CodexBar](https://github.com/steipete/CodexBar) (MIT) that ships and evolves separately. Attribution stays visible (README, LICENSE, About); identity does not.
- `Sources/CodexBarCore/MidasIdentity.swift` is the single source of truth for everything observable outside the source tree: bundle id `com.designprism.midas`, `Midas.app` / `Midas` executable, team `L49MKXGVM4`, app group, Keychain services, `~/Library/*/Midas` folders, log subsystem, update feed. `Scripts/package_app.sh` mirrors these values. Never introduce a new `com.steipete.*`, `CodexBar`-named path, service, or feed; reference `MidasIdentity` instead of literals.
- `MidasIdentity.Upstream` holds the inherited identifiers for attribution and one-time migration only (`MidasIdentityMigration`, `MidasLegacyKeychain`, `AppGroupSupport.legacyGroupIDs`). Read from them, never write.
- Swift targets, modules, helper binaries, widget kinds, and Info.plist keys such as `CodexBarTeamID` keep their inherited names on purpose so upstream changes can still be reviewed and merged. They are internal names, not product identity; do not rename them piecemeal.
- Process names: the packaged app runs as `Midas`; `swift build` products in `.build/` keep the `CodexBar` target name. Scripts kill by full path or `-x Midas`, never `-x CodexBar`.

## Build, Test, Run
- Dev loop: `./Scripts/compile_and_run.sh` kills old Midas instances, runs `swift build` + `swift test`, packages, relaunches `Midas.app`, and confirms it stays running.
- Quick build/test: `swift build` (debug) or `swift build -c release`; `swift test` for the full XCTest suite.
- Package locally: `./Scripts/package_app.sh` to refresh `Midas.app`, then restart with `pkill -x Midas || pkill -f Midas.app || true; open -n "$PWD/Midas.app"`.
- Midas release flow: follow `docs/MIDAS_RELEASE.md`. Version/build metadata lives in `version.env`. The inherited `.mac-release.env`, `Scripts/release.sh`, and `Scripts/sign-and-notarize.sh` target upstream CodexBar; do not use them unchanged for Midas. Signed packaging must pass the Midas `APP_TEAM_ID` and `APP_IDENTITY`.

## Coding Style & Naming
- Enforce SwiftFormat/SwiftLint: run `swiftformat Sources Tests` and `swiftlint --strict`. 4-space indent, 120-char lines, explicit `self` is intentional—do not remove.
- Favor small, typed structs/enums; maintain existing `MARK` organization. Use descriptive symbols; match current commit tone.

## Testing Guidelines
- Add/extend XCTest cases under `Tests/CodexBarTests/*Tests.swift` (`FeatureNameTests` with `test_caseDescription` methods).
- Model names in tests/code: released models or clearly fictitious names only; never expose unreleased names.
- Always run `swift test` before handoff; add focused filters for parser/provider fixes when possible.
- After any code change, run `make check` and fix all reported format/lint issues before handoff.
- Prefer CLI/focused tests over app-bundle live tests when behavior can be verified without relaunching CodexBar.
- Never run tests/checks or ad-hoc validation that can display macOS Keychain prompts. Live provider probes, browser-cookie imports, `codexbar usage` against real accounts, and real SecItem reads must be explicitly requested; otherwise use parser tests, stubs, test stores, or `KeychainNoUIQuery`.
- macOS CI is brittle around headless AppKit status/menu tests. Prefer covering menu behavior through stable state/model seams (`MenuDescriptor`, `ProvidersPane`, `CodexAccountsSectionState`, etc.) instead of constructing live `NSStatusBar`/`NSMenu` flows unless the AppKit wiring itself is the thing under test.

## Commit & PR Guidelines
- Commit messages: short imperative clauses (e.g., “Improve usage probe”, “Fix icon dimming”); keep commits scoped.
- PRs/patches should list summary, commands run, screenshots/GIFs for UI changes, and linked issue/reference when relevant.

## Agent Notes
- Use the provided scripts and package manager (SwiftPM); avoid adding dependencies or tooling without confirmation.
- Validate UI/runtime behavior against the freshly built bundle; restart via the pkill+open command above to avoid running stale binaries.
- To guarantee the right bundle is running after a rebuild, use: `pkill -x Midas || pkill -f Midas.app || true; open -n "$PWD/Midas.app"`. Never `pkill CodexBar`: upstream CodexBar.app is a separate app that may be installed alongside Midas.
- For CLI-testable provider/parser/settings behavior, use CLI/focused tests instead of `Scripts/package_app.sh` or `./Scripts/compile_and_run.sh`.
- Run `./Scripts/compile_and_run.sh` only when UI/runtime behavior needs bundle-level validation; it builds, tests, packages, relaunches, and verifies the app stays running.
- Widget/Tahoe UI issues: use Parallels macOS VM plus screenshots/clicks for autonomous verification.
- Release script: keep it in the foreground; do not background it—wait until it finishes.
- Midas Sparkle signing: use the `enzo-prism-midas` Keychain account with Sparkle’s signing tools. Never use upstream CodexBar or VibeTunnel keys. Keep private keys out of the repository. Every latest stable release must include `Midas-appcast-arm64-v2.xml` (signed item for the Midas identity) and `Midas-appcast-arm64.xml` (informational item for 0.33.3–0.36.0 clients); `Scripts/make_midas_appcast.py` writes both.
- Swift concurrency: treat sibling `async let` tasks as a review red flag when one child is required and another is optional/best-effort. Prefer sequential awaits or a drained `withThrowingTaskGroup` that surfaces required failures and explicitly contains optional failures; crash stacks mentioning `swift_task_dealloc` or `asyncLet_finish_after_task_completion` should trigger an audit of nearby `async let` usage.
- Prefer modern SwiftUI/Observation macros: use `@Observable` models with `@State` ownership and `@Bindable` in views; avoid `ObservableObject`, `@ObservedObject`, and `@StateObject`.
- Favor modern macOS 15+ APIs over legacy/deprecated counterparts when refactoring (Observation, new display link APIs, updated menu item styling, etc.).
- Keep provider data siloed: when rendering usage or account info for a provider (Claude vs Codex), never display identity/plan fields sourced from a different provider.***
- Claude CLI status line is custom + user-configurable; never rely on it for usage parsing.
- Cookie imports: default Chrome-only when possible to avoid other browser prompts; override via browser list when needed.
