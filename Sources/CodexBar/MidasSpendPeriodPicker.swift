import CodexBarCore
import SwiftUI

struct MidasSpendPeriodPicker: View {
    @Bindable var settings: SettingsStore
    let store: UsageStore
    @Environment(\.dismiss) private var dismiss

    private var months: [String] {
        let current = String(MidasSpendPeriod.currentMonth.range()?.start.prefix(7) ?? "")
        return Array(Set(self.store.tokenSnapshots.values.flatMap(\.daily).compactMap { entry in
            guard entry.date.count == 10 else { return nil as String? }
            let month = String(entry.date.prefix(7))
            return month < current ? month : nil
        })).sorted(by: >)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Spend period").font(.headline)
                self.option("This month", selection: "currentMonth")
                self.option("Last 30 days", selection: "rolling30Days")
                if !self.months.isEmpty {
                    Divider()
                    Text("Recorded months · may be incomplete").font(.caption).foregroundStyle(.secondary)
                    ForEach(self.months, id: \.self) { month in
                        self.option(MidasSpendPeriod(selection: month).label, selection: month)
                    }
                }
                Text("Based on recorded daily dates. Quota resets keep their own schedules.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(18)
        }.frame(width: 300).frame(maxHeight: 420)
    }

    private func option(_ title: String, selection: String) -> some View {
        Button {
            self.settings.midasSpendPeriodSelection = selection
            self.dismiss()
        } label: {
            HStack {
                Text(title)
                Spacer()
                if self.settings.midasSpendPeriodSelection == selection { Image(systemName: "checkmark") }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
