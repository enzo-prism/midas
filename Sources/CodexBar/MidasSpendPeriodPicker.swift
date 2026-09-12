import CodexBarCore
import SwiftUI

struct MidasSpendPeriodControl: View {
    @Bindable var settings: SettingsStore
    let store: UsageStore
    @State private var isPresented = false

    var body: some View {
        Button { self.isPresented.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "calendar").foregroundStyle(MidasTheme.secondaryText)
                Text(MidasSpendPeriod(selection: self.settings.midasSpendPeriodSelection).label)
                    .lineLimit(1)
                Image(systemName: self.isPresented ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(MidasPeriodButtonStyle(selected: self.isPresented))
        .accessibilityLabel("Spend period")
        .accessibilityValue(MidasSpendPeriod(selection: self.settings.midasSpendPeriodSelection).label)
        .help("Choose the date range for estimated spend")
        .popover(isPresented: self.$isPresented, arrowEdge: .bottom) {
            MidasSpendPeriodPicker(settings: self.settings, store: self.store)
        }
    }
}

/// A fixed control surface separates date choices from the underlying provider data.
struct MidasSpendPeriodPicker: View {
    @Bindable var settings: SettingsStore
    let store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedSelection: String?

    private var months: [String] {
        let providers = self.store.enabledProvidersForDisplay()
        let dates = providers.flatMap { provider -> [String] in
            let projected = self.store.tokenSnapshot(
                fromProviderSnapshot: self.store.snapshot(for: provider), provider: provider)
            let token = projected ?? (UsageStore.tokenCostRequiresProviderSnapshot(provider)
                ? nil : self.store.tokenSnapshot(for: provider))
            return token?.daily.map(\.date) ?? []
        }
        return MidasSpendPeriodChoices.recordedMonths(
            dates: dates, selection: self.settings.midasSpendPeriodSelection)
    }

    private var selections: [String] {
        ["currentMonth", "rolling30Days"] + self.months
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spend period").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { self.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(MidasTheme.secondaryText)
                    .accessibilityLabel("Close spend period")
            }.padding(.horizontal, 6)
            VStack(spacing: 4) {
                self.option("This month", selection: "currentMonth", icon: "calendar")
                self.option("Last 30 days", selection: "rolling30Days", icon: "clock.arrow.circlepath")
            }
            Divider()
            Text("RECORDED MONTHS")
                .font(.system(size: 10, weight: .semibold)).tracking(0.7)
                .foregroundStyle(MidasTheme.secondaryText).padding(.horizontal, 6)
            if self.months.isEmpty {
                Text("No earlier months recorded yet")
                    .font(.system(size: 12)).foregroundStyle(MidasTheme.secondaryText)
                    .padding(.horizontal, 6).padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(self.months, id: \.self) { month in
                                self.option(
                                    MidasSpendPeriod(selection: month).label,
                                    selection: month,
                                    icon: "archivebox")
                                    .id(month)
                            }
                        }
                    }
                    .frame(height: CGFloat(min(self.months.count, 4)) * 54)
                    .onAppear { proxy.scrollTo(self.settings.midasSpendPeriodSelection) }
                    .onChange(of: self.focusedSelection) { _, value in
                        if let value { proxy.scrollTo(value) }
                    }
                }
            }
            Text("Recorded history may be incomplete. Quota reset dates stay the same.")
                .font(.system(size: 11)).foregroundStyle(MidasTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
        }
        .padding(12).frame(width: 300)
        .foregroundStyle(MidasTheme.text).background(MidasTheme.background)
        .onAppear { self.focusedSelection = self.selections.contains(self.settings.midasSpendPeriodSelection)
            ? self.settings.midasSpendPeriodSelection : "currentMonth"
        }
        .onMoveCommand { direction in
            let index = self.selections.firstIndex(of: self.focusedSelection ?? "") ?? 0
            if direction == .down { self.focusedSelection = self.selections[min(index + 1, self.selections.count - 1)] }
            if direction == .up { self.focusedSelection = self.selections[max(index - 1, 0)] }
        }
        .onKeyPress(.return) {
            guard let selection = self.focusedSelection else { return .ignored }
            self.select(selection)
            return .handled
        }
        .onExitCommand { self.dismiss() }
    }

    private func select(_ selection: String) {
        self.settings.midasSpendPeriodSelection = selection
        self.dismiss()
    }

    private func option(_ title: String, selection: String, icon: String) -> some View {
        let selected = self.settings.midasSpendPeriodSelection == selection
        return Button { self.select(selection) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 16).foregroundStyle(MidasTheme.secondaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                    Text(MidasSpendPeriodChoices.dateLabel(selection: selection))
                        .font(.system(size: 11)).foregroundStyle(MidasTheme.secondaryText)
                }
                Spacer(minLength: 6)
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MidasTheme.accent).opacity(selected ? 1 : 0).accessibilityHidden(true)
            }.frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        }
        .buttonStyle(MidasPeriodButtonStyle(selected: selected, focused: self.focusedSelection == selection))
        .focused(self.$focusedSelection, equals: selection)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MidasPeriodButtonStyle: ButtonStyle {
    let selected: Bool
    var focused = false
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, selected: self.selected, focused: self.focused)
    }

    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let focused: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            self.configuration.label
                .padding(.horizontal, 10).padding(.vertical, 7)
                .foregroundStyle(MidasTheme.text)
                .background(self.fill, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            self.focused ? MidasTheme.accent : self.selected ? MidasTheme.accent.opacity(0.45)
                                : MidasTheme.secondaryText.opacity(self.hovered ? 0.3 : 0.12),
                            lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .opacity(self.enabled ? 1 : 0.45)
                .onHover { self.hovered = $0 }
        }

        private var fill: Color {
            if self.configuration.isPressed { return MidasTheme.accent.opacity(0.24) }
            if self.selected { return MidasTheme.accent.opacity(self.hovered ? 0.2 : 0.12) }
            return self.hovered ? MidasTheme.surface : MidasTheme.surface.opacity(0.35)
        }
    }
}

/// Dates are validated before becoming choices; malformed history must never look like the current month.
enum MidasSpendPeriodChoices {
    static func recordedMonths(dates: [String], selection: String = "currentMonth", now: Date = Date()) -> [String] {
        let formatter = self.formatter
        let current = String(MidasSpendPeriod.currentMonth.range(now: now)?.start.prefix(7) ?? "")
        let candidates = dates + (selection.count == 7 ? [selection + "-01"] : [])
        return Set(candidates.compactMap { day -> String? in
            guard day.count == 10, let date = formatter.date(from: day), formatter.string(from: date) == day else {
                return nil
            }
            let month = String(day.prefix(7))
            return month < current ? month : nil
        }).sorted(by: >)
    }

    static func dateLabel(selection: String, now: Date = Date()) -> String {
        guard let range = MidasSpendPeriod(selection: selection).range(now: now),
              let start = self.formatter.date(from: range.start), let end = self.formatter.date(from: range.end)
        else { return "Dates unavailable" }
        let format = DateIntervalFormatter()
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateTemplate = "MMM d"
        return format.string(from: start, to: end)
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
