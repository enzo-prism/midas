import CodexBarCore
import SwiftUI

struct MidasCloudUsagePresentation {
    struct Account: Identifiable {
        let id: String
        let name: String
        let usage: CodexCloudAccountUsage?
        let error: String?
    }

    let accounts: [Account]
    let tokens: Int?
    let hasEstimate: Bool

    var coverage: String {
        let reported = self.accounts.count { $0.usage?.totalTokens != nil }
        let failures = self.accounts.count { $0.error != nil }
        let status = failures > 0 ? " · \(failures) refresh failures" : ""
        return "\(reported) of \(self.accounts.count) account histories · OpenAI-reported" + status
    }
}

struct MidasCloudUsageView: View {
    let summary: MidasCloudUsagePresentation
    var showsAccounts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cloud token usage · all devices").font(.caption).foregroundStyle(MidasTheme.secondaryText)
            Text(self.summary.tokens.map { $0.formatted(.number.notation(.compactName)) + " tokens" }
                ?? "History unavailable")
                .font(.system(size: 24, weight: .medium)).monospacedDigit()
            Text("Last 30 days · UTC").font(.caption).foregroundStyle(MidasTheme.secondaryText)
            Text(self.summary.coverage).font(.caption2).foregroundStyle(MidasTheme.secondaryText)
            Text("Cloud history can lag; an empty account history is not treated as zero.")
                .font(.caption2).foregroundStyle(MidasTheme.secondaryText)
            if !self.summary.hasEstimate {
                Text(
                    "Cloud spend unavailable: OpenAI does not report "
                        + "input/cache/output token counts for these accounts.")
                    .font(.caption2).foregroundStyle(MidasTheme.secondaryText)
            }
            if self.showsAccounts {
                ForEach(self.summary.accounts) { account in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(account.name).font(.callout.weight(.medium))
                        Text(account.usage?.totalTokens.map { $0.formatted() + " reported tokens" }
                            ?? "Token history pending or unavailable")
                        if let error = account.error {
                            Text(error).foregroundStyle(MidasTheme.warning)
                        }
                        if let usage = account.usage {
                            Text("Stats as of \(usage.statsAsOf)").foregroundStyle(MidasTheme.secondaryText)
                            if !usage.models.isEmpty {
                                Text("Model usage (provider \(usage.modelUnits) units, not token counts)")
                                    .foregroundStyle(MidasTheme.secondaryText)
                                ForEach(usage.models, id: \.model) { model in
                                    HStack {
                                        Text(model.model)
                                        Spacer()
                                        Text(model.value.formatted(.number.precision(.fractionLength(2))))
                                    }
                                }
                            }
                        }
                    }.font(.caption).padding(.vertical, 6)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
