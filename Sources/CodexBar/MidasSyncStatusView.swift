import SwiftUI

/// Describes what this Mac knows, without implying that a cloud save reached another Mac.
struct MidasSyncPresentation: Equatable {
    let title: String
    let symbol: String
    let sharingSummary: String?

    init(isEnabled: Bool, includesSyncedUsage: Bool, hasFolder: Bool, otherMacCount: Int) {
        self.init(
            isEnabled: isEnabled,
            includesSyncedUsage: includesSyncedUsage,
            hasConnection: hasFolder,
            otherDeviceCount: otherMacCount,
            transport: .folder)
    }

    init(
        isEnabled: Bool,
        includesSyncedUsage: Bool,
        hasConnection: Bool,
        otherDeviceCount: Int,
        transport: MidasUsageSyncTransport)
    {
        let isHub = transport == .tailscaleHub
        if !isEnabled {
            self.title = hasConnection ? "Sync paused" : "Usage on this Mac"
            self.symbol = hasConnection ? "pause.circle" : "desktopcomputer"
            self.sharingSummary = nil
        } else if !hasConnection {
            self.title = isHub ? "Connect your Tailscale hub" : "Choose a sync folder"
            self.symbol = isHub ? "network" : "icloud"
            self.sharingSummary = nil
        } else {
            self.title = includesSyncedUsage ? "Combined usage" : "Usage on this Mac"
            self.symbol = isHub ? "network" : "icloud"
            let count = max(0, otherDeviceCount)
            if isHub {
                self.sharingSummary = count == 0
                    ? "Waiting for usage from another device."
                    : "Usage received from \(count) other \(count == 1 ? "device" : "devices")."
            } else {
                self.sharingSummary = count == 0
                    ? "Waiting for usage from another Mac."
                    : "Usage received from \(count) other \(count == 1 ? "Mac" : "Macs")."
            }
        }
    }
}

@MainActor
struct MidasSyncStatusView: View {
    let coordinator: MidasUsageSyncCoordinator

    private var presentation: MidasSyncPresentation {
        MidasSyncPresentation(
            isEnabled: self.coordinator.isEnabled,
            includesSyncedUsage: self.coordinator.includesSyncedUsage,
            hasConnection: self.coordinator.hasConnection,
            otherDeviceCount: self.coordinator.devices.count(where: { !$0.isThisMac }),
            transport: self.coordinator.transport)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Label(self.presentation.title, systemImage: self.presentation.symbol)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if self.coordinator.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Syncing usage")
                }
                Button("Sync now") {
                    Task { await self.coordinator.syncNow() }
                }
                .disabled(
                    !self.coordinator.isEnabled || !self.coordinator.hasConnection || self.coordinator.isSyncing)
                .accessibilityIdentifier("midas-sync-now")
            }

            Text(self.coordinator.status)
                .font(.footnote)
                .foregroundStyle(MidasTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let summary = self.presentation.sharingSummary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(MidasTheme.secondaryText)
            }

            if let issue = self.coordinator.issue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(MidasTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if self.coordinator.isEnabled, self.coordinator.hasConnection {
                self.transferDates
                Text(self.coordinator.transport == .tailscaleHub
                    ? "Showing the last received totals. Devices that are offline may have newer usage waiting to sync."
                    : "Saving here does not confirm another Mac has received your usage.")
                    .font(.caption)
                    .foregroundStyle(MidasTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(MidasTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private var transferDates: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let date = self.coordinator.lastPublishedAt {
                Text("Last successful upload: \(date.formatted(date: .abbreviated, time: .shortened))")
            }
            if let date = self.coordinator.lastReceivedAt {
                Text("Received on this Mac: \(date.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .font(.caption)
        .foregroundStyle(MidasTheme.secondaryText)
    }
}
