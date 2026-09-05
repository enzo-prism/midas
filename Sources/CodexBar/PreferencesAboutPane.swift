import AppKit
import SwiftUI

@MainActor
struct AboutPane: View {
    let updater: UpdaterProviding
    @AppStorage("autoUpdateEnabled") private var autoUpdateEnabled: Bool = true
    @AppStorage(UpdateChannel.userDefaultsKey)
    private var updateChannelRaw: String = UpdateChannel.defaultChannel.rawValue
    @State private var didLoadUpdaterState = false

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private var buildTimestamp: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CodexBuildTimestamp") as? String else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: raw) else { return raw }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = .current
        return formatter.string(from: date)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(MidasTheme.accent.opacity(0.12))
                        .frame(width: 96, height: 96)
                    Image(systemName: "sparkles")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(MidasTheme.accent)
                }
                .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Midas")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                    Text("A little more clarity. A lot more room.")
                        .foregroundStyle(.secondary)
                    Text(String(format: L("version_format"), self.versionString))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let buildTimestamp {
                        Text(String(format: L("built_format"), buildTimestamp))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 24) {
                    AboutLinkRow(
                        icon: "chevron.left.slash.chevron.right",
                        title: "Midas on GitHub",
                        url: "https://github.com/enzo-prism/midas")
                    AboutLinkRow(
                        icon: "bubble.left",
                        title: "Feedback & support",
                        url: "https://github.com/enzo-prism/midas/issues")
                }

                Divider().padding(.vertical, 8)

                if self.updater.isAvailable {
                    VStack(spacing: 10) {
                        Toggle(L("check_updates_auto"), isOn: self.$autoUpdateEnabled)
                            .toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, alignment: .center)
                        if Bundle.main.object(forInfoDictionaryKey: "MidasAirEnabled") as? Bool != true {
                            VStack(spacing: 6) {
                                HStack(spacing: 12) {
                                    Text(L("update_channel"))
                                    Spacer()
                                    Picker("", selection: self.updateChannelBinding) {
                                        ForEach(UpdateChannel.allCases) { channel in
                                            Text(channel.displayName).tag(channel)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                }
                                .frame(maxWidth: 280)
                                Text(self.updateChannel.description)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 280)
                            }
                        }
                        Button(L("check_for_updates")) { self.updater.checkForUpdates(nil) }
                    }
                } else {
                    Text(self.updater.unavailableReason ?? L("updates_unavailable"))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    Text("Built on open source")
                        .font(.headline)
                    Text("Midas is a fork of CodexBar by Peter Steinberger and contributors, under the MIT License.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    AboutLinkRow(
                        icon: "heart",
                        title: "CodexBar · MIT License",
                        url: "https://github.com/steipete/CodexBar/blob/main/LICENSE")
                    Text("Provider marks via SVGL. All trademarks belong to their respective owners.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 16)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 24)
        }
        .onAppear {
            guard !self.didLoadUpdaterState, self.updater.isAvailable else { return }
            // Align Sparkle's flag with the persisted preference on first load.
            self.updater.automaticallyChecksForUpdates = self.autoUpdateEnabled
            self.updater.automaticallyDownloadsUpdates = self.autoUpdateEnabled
            self.didLoadUpdaterState = true
        }
        .onChange(of: self.autoUpdateEnabled) { _, newValue in
            guard self.updater.isAvailable else { return }
            self.updater.automaticallyChecksForUpdates = newValue
            self.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    private var updateChannel: UpdateChannel {
        UpdateChannel(rawValue: self.updateChannelRaw) ?? .stable
    }

    private var updateChannelBinding: Binding<UpdateChannel> {
        Binding(
            get: { self.updateChannel },
            set: { newValue in
                self.updateChannelRaw = newValue.rawValue
                self.updater.checkForUpdates(nil)
            })
    }
}
