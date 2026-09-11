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
    var period = "Last 30 days · UTC"

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
            Text("Reported tokens · all devices").font(.caption).foregroundStyle(MidasTheme.secondaryText)
            Text(self.summary.tokens.map { $0.formatted(.number.notation(.compactName)) + " tokens" }
                ?? "History unavailable")
                .font(.system(size: 24, weight: .medium)).monospacedDigit()
            Text(self.summary.period).font(.caption).foregroundStyle(MidasTheme.secondaryText)
            Text(self.summary.coverage).font(.caption2).foregroundStyle(MidasTheme.secondaryText)
            if self.showsAccounts {
                ForEach(self.summary.accounts) { account in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(account.name).font(.callout.weight(.medium))
                        Text(account.usage?.totalTokens.map { $0.formatted() + " reported tokens" }
                            ?? "Token history pending or unavailable")
                        if let error = account.error {
                            DisclosureGroup("Refresh failed") {
                                Text(error).textSelection(.enabled)
                            }
                            .foregroundStyle(MidasTheme.warning)
                        }
                        if let usage = account.usage {
                            Text("Stats as of \(usage.statsAsOf)").foregroundStyle(MidasTheme.secondaryText)
                            if !usage.models.isEmpty {
                                DisclosureGroup("Model usage") {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Provider \(usage.modelUnits) units; not token counts.")
                                            .foregroundStyle(MidasTheme.secondaryText)
                                        ForEach(usage.models, id: \.model) { model in
                                            HStack {
                                                Text(model.model)
                                                Spacer()
                                                Text(model.value.formatted(.number.precision(.fractionLength(2))))
                                            }
                                        }
                                    }.padding(.top, 6)
                                }
                            }
                        }
                    }.font(.caption).padding(.vertical, 6)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
