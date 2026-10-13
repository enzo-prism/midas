import SwiftUI

/// Describes what this Mac knows, without implying that a cloud save reached another Mac.
struct MidasSyncPresentation: Equatable {
    let title: String
    let symbol: String
    let sharingSummary: String?

    init(isEnabled: Bool, includesSyncedUsage: Bool, hasFolder: Bool, otherMacCount: Int) {
        if !isEnabled {
            self.title = hasFolder ? "Sync paused" : "Usage on this Mac"
            self.symbol = hasFolder ? "pause.circle" : "desktopcomputer"
            self.sharingSummary = nil
        } else if !hasFolder {
            self.title = "Choose a sync folder"
            self.symbol = "icloud"
            self.sharingSummary = nil
        } else {
            self.title = includesSyncedUsage ? "Combined usage" : "Usage on this Mac"
            self.symbol = "icloud"
            let count = max(0, otherMacCount)
            self.sharingSummary = count == 0
                ? "Waiting for usage from another Mac."
                : "Usage received from \(count) other \(count == 1 ? "Mac" : "Macs")."
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
            hasFolder: self.coordinator.folderURL != nil,
            otherMacCount: self.coordinator.devices.count(where: { !$0.isThisMac }))
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
                    !self.coordinator.isEnabled || self.coordinator.folderURL == nil || self.coordinator.isSyncing)
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

            if self.coordinator.isEnabled, self.coordinator.folderURL != nil {
                self.transferDates
                Text("Saving here does not confirm another Mac has received your usage.")
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
                Text("Saved from this Mac: \(date.formatted(date: .abbreviated, time: .shortened))")
            }
            if let date = self.coordinator.lastReceivedAt {
                Text("Received on this Mac: \(date.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .font(.caption)
        .foregroundStyle(MidasTheme.secondaryText)
    }
}
