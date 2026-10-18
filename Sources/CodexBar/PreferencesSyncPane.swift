import SwiftUI

@MainActor
struct PreferencesSyncPane: View {
    @Bindable var coordinator: MidasUsageSyncCoordinator

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection(title: "Combine usage across your devices") {
                    Picker("Connection", selection: Binding(
                        get: { self.coordinator.transport },
                        set: { self.coordinator.selectTransport($0) }))
                    {
                        ForEach(MidasUsageSyncTransport.allCases) { transport in
                            Text(transport.title).tag(transport)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("midas-sync-transport")
                    if self.coordinator.transport == .tailscaleHub {
                        self.caption("Use your Mac mini as a private hub. Import the connection file created " +
                            "for this Mac. Tailscale must be connected on both devices.")
                        self.hubControls
                    } else {
                        self.caption("Choose a private iCloud Drive folder, or another trusted folder that syncs " +
                            "between your Macs. Select the same folder in Midas on each Mac.")
                        self.folderControls
                    }
                    self.toggleRow(
                        title: "Sync usage from this Mac",
                        subtitle: "Keep Midas open on each Mac to share new usage.",
                        binding: self.$coordinator.isEnabled)
                        .disabled(!self.coordinator.hasConnection)
                    self.toggleRow(
                        title: "Show combined usage",
                        subtitle: "Turn this off to view only this Mac while continuing to share usage.",
                        binding: self.$coordinator.includesSyncedUsage)
                        .disabled(!self.coordinator.isEnabled)
                }

                Divider()

                SettingsSection(title: "This Mac", contentSpacing: 10) {
                    HStack(spacing: 12) {
                        Text("Device name")
                        TextField("Device name", text: self.$coordinator.deviceName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                            .accessibilityIdentifier("midas-sync-device-name")
                            .disabled(self.coordinator.transport == .tailscaleHub && self.coordinator.hasConnection)
                    }
                    if self.coordinator.transport == .tailscaleHub, self.coordinator.hasConnection {
                        self.caption("This name comes from the connection file. " +
                            "Create a new connection file to change it.")
                    }
                    MidasSyncStatusView(coordinator: self.coordinator)
                }

                if !self.coordinator.devices.isEmpty {
                    Divider()
                    SettingsSection(
                        title: "Devices sharing usage",
                        contentSpacing: 12)
                    {
                        self.caption(
                            "Last seen records a device’s latest shared usage. It does not mean that device is online.")
                        ForEach(self.coordinator.devices, id: \.id) { device in
                            self.deviceRow(device)
                        }
                    }
                }

                Divider()

                SettingsSection(title: "How totals work", contentSpacing: 8) {
                    Text("Codex, Claude, Meta (Muse Code), and supported local model logs " +
                        "are combined across devices. Cursor account usage is counted once.")
                    Text("Only supported, recorded sources are included. " +
                        "Activity without token records is not counted.")
                    Text("Synced days use UTC so every device agrees. Estimated value uses API prices, " +
                        "and is not a bill or subscription charge.")
                    Text("Meta AI / Muse app usage is currently unavailable. Muse Code token logs can sync.")
                }
                .font(.footnote)
                .foregroundStyle(MidasTheme.secondaryText)

                SettingsSection(title: "Your privacy", contentSpacing: 8) {
                    Text("Sync shares usage totals, costs, models, and device labels. " +
                        "Provider credentials and conversation text stay on each device.")
                    if self.coordinator.transport == .tailscaleHub {
                        Text("Your hub connection file is private. Each device has its own access credential. " +
                            "Usage waits locally when the hub is unavailable and retries automatically.")
                    } else {
                        Text("Use a private folder you trust. " +
                            "Anyone with access to that folder can read its usage data.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(MidasTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var hubControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(self.coordinator.hubEndpoint == nil ? "Import connection file…" : "Replace connection file…") {
                    self.coordinator.chooseHubConnection()
                }
                .disabled(self.coordinator.isSyncing)
                .accessibilityIdentifier("midas-sync-import-hub")
                if let endpoint = self.coordinator.hubEndpoint {
                    Label(endpoint.host ?? "Private hub", systemImage: "network")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Disconnect") { self.coordinator.disconnect() }
                        .disabled(self.coordinator.isSyncing)
                        .accessibilityIdentifier("midas-sync-disconnect")
                }
            }
            if self.coordinator.hubEndpoint != nil {
                self.caption("The Mac mini must be awake to sync. " +
                    "Collection can continue on each device while it is away.")
            }
        }
    }

    private var folderControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(self.coordinator.folderURL == nil ? "Choose sync folder…" : "Change sync folder…") {
                    self.coordinator.chooseFolder()
                }
                .disabled(self.coordinator.isSyncing)
                .accessibilityIdentifier("midas-sync-choose-folder")
                if let folder = self.coordinator.folderURL {
                    Label(folder.lastPathComponent, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder.path)
                    Spacer()
                    Button("Disconnect") {
                        self.coordinator.disconnect()
                    }
                    .disabled(self.coordinator.isSyncing)
                    .accessibilityIdentifier("midas-sync-disconnect")
                }
            }
            if self.coordinator.folderURL != nil {
                Text("Disconnect stops sharing and keeps the usage files already saved in your folder.")
                    .font(.footnote)
                    .foregroundStyle(MidasTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func deviceRow(_ device: MidasUsageSyncDeviceStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(MidasTheme.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.body.weight(.medium))
                    if device.isThisMac {
                        Text("This Mac")
                            .font(.caption)
                            .foregroundStyle(MidasTheme.secondaryText)
                    }
                }
                Text("Last seen \(device.lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(MidasTheme.secondaryText)
            }
            Spacer()
        }
    }

    private func toggleRow(title: String, subtitle: String, binding: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 5.4) {
            PreferenceToggleRow(title: title, subtitle: nil, binding: binding)
            self.caption(subtitle)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(MidasTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
