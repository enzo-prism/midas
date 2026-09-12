import SwiftUI

struct MidasCalibrationSharingView: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Share pricing through iCloud Drive", isOn: self.$settings.midasCalibrationSharingEnabled)
                .onChange(of: self.settings.midasCalibrationSharingEnabled) { _, _ in
                    self.store.scheduleMidasCalibrationSharing(force: true)
                    self.store.repriceMidasCloudUsage()
                }
            if self.settings.midasCalibrationSharingEnabled {
                HStack {
                    Text(self.store.midasCalibrationSharingStatus)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check now") { self.store.scheduleMidasCalibrationSharing(force: true) }
                        .controlSize(.small)
                }
                DisclosureGroup("How sharing works") {
                    Text("Enable this on each Mac using the same iCloud Drive and connected Codex accounts. "
                        + "Midas chooses the largest recent pricing sample once files arrive. "
                        + "Only the rate, sample size, dates and matching identifiers are shared. "
                        + "Credentials and conversations stay on each Mac. Custom rates stay local. "
                        + "Turning this off stops sharing on this Mac; existing samples expire after 24 hours.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .onAppear { self.store.scheduleMidasCalibrationSharing() }
    }
}
