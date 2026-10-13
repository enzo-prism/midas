import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MidasSyncRenderTests {
    @Test @MainActor func buildsDisconnectedSyncViewsWithoutProviders() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(!fixture.coordinator.isEnabled)
        #expect(fixture.coordinator.folderURL == nil)
        _ = PreferencesSyncPane(coordinator: fixture.coordinator).body
        _ = MidasSyncStatusView(coordinator: fixture.coordinator).body
    }

    /// Opt-in native snapshots use inert coordinators, unique defaults, and isolated temporary folders.
    @Test @MainActor func exportSyncFixturesWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["MIDAS_SYNC_PREVIEW_OUTPUT"] else { return }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z"))

        for name in ["setup", "waiting", "combined", "offline"] {
            coordinator.folderURL = name == "setup" ? nil : fixture.directory.appendingPathComponent("Midas Usage")
            coordinator.isEnabled = name != "setup"
            coordinator.includesSyncedUsage = true
            coordinator.deviceName = "Example Mac mini"
            coordinator.lastPublishedAt = name == "setup" ? nil : now
            coordinator.lastReceivedAt = ["combined", "offline"].contains(name) ? now : nil
            coordinator
                .issue = name == "offline" ? "The sync folder is unavailable. Try again when it reconnects." : nil
            coordinator.status = switch name {
            case "setup": "Sync is off. Choose the same private folder on each Mac to get started."
            case "waiting": "Usage saved from this Mac. Waiting for another Mac."
            case "combined": "Usage from your Macs is available here."
            default: "Showing the last usage received."
            }
            coordinator.devices = name == "setup" ? [] : [
                MidasUsageSyncDeviceStatus(
                    id: UUID(), name: "Example Mac mini", lastSeenAt: now, isThisMac: true, eventCount: 42),
            ]
            if ["combined", "offline"].contains(name) {
                coordinator.devices.append(MidasUsageSyncDeviceStatus(
                    id: UUID(),
                    name: "Example MacBook Pro",
                    lastSeenAt: now.addingTimeInterval(-3600),
                    isThisMac: false,
                    eventCount: 73))
            }

            for scheme in [ColorScheme.light, .dark] {
                let pane = PreferencesSyncPane(coordinator: coordinator)
                    .foregroundStyle(MidasTheme.text)
                    .tint(MidasTheme.accent)
                    .background(MidasTheme.background)
                    .environment(\.colorScheme, scheme)
                try Self.export(pane, name: "settings-\(name)", scheme: scheme, output: output)
            }
        }
    }

    @MainActor private struct Fixture {
        let suite: String
        let defaults: UserDefaults
        let directory: URL
        let coordinator: MidasUsageSyncCoordinator

        init() throws {
            let suite = "MidasSyncRender-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.suite = suite
            self.defaults = defaults
            self.directory = directory
            self.coordinator = MidasUsageSyncCoordinator(
                defaults: defaults,
                persistenceURL: directory.appendingPathComponent("sync-state.json"),
                automaticallySyncs: false)
        }

        func cleanup() {
            self.defaults.removePersistentDomain(forName: self.suite)
            try? FileManager.default.removeItem(at: self.directory)
        }
    }

    @MainActor private static func export(
        _ view: some View, name: String, scheme: ColorScheme, output: String) throws
    {
        let size = NSSize(width: 720, height: 850)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(MidasTheme.background))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide >= Int(size.width))
        #expect(bitmap.pixelsHigh >= Int(size.height))
        let filename = "midas-sync-\(name)-\(scheme == .dark ? "dark" : "light").png"
        try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(filename), options: .withoutOverwriting)
    }
}
