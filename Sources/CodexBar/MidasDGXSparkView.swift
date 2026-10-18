import AppKit
import CodexBarCore
import SwiftUI

/// Local inference has measured activity and a hosted-price comparison, never an account quota.
struct MidasDGXSparkCard: View {
    let model: MidasDGXSparkPresentation
    var isRefreshing = false
    var showsNavigation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                MidasProviderLogo(provider: .localInference, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DGX Spark").font(.system(size: 17, weight: .semibold))
                    Text("LOCAL INFERENCE")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.1).foregroundStyle(MidasDGXSparkStyle.green)
                }
                Spacer(minLength: 4)
                if self.isRefreshing { ProgressView().controlSize(.mini) }
                if self.showsNavigation {
                    Image(systemName: "arrow.up.right")
                        .font(.caption).foregroundStyle(MidasTheme.secondaryText)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Last 30 days · UTC").font(.caption).foregroundStyle(MidasTheme.secondaryText)
                Text(self.model.tokenText)
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .accessibilityLabel("\(self.model.tokenText) recorded tokens in the last 30 days")
                Text("tokens processed").font(.callout).foregroundStyle(MidasTheme.secondaryText)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API-equivalent value").font(.caption).foregroundStyle(MidasTheme.secondaryText)
                    Text(self.model.basisText).font(.caption2).foregroundStyle(MidasTheme.secondaryText)
                }
                Spacer(minLength: 4)
                Text(self.model.valueText).font(.system(size: 23, weight: .medium)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .help(self.model.preciseValueText.map { "\($0) USD · estimated hosted API value" }
                        ?? "No verified API-rate estimate is available for these records.")
                    .accessibilityLabel("API-equivalent value")
                    .accessibilityValue(self.model.preciseValueText ?? "Unavailable")
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(self.model.modelText).font(.caption.weight(.medium)).lineLimit(2)
                Text(self.model.coverageText).font(.caption2).foregroundStyle(MidasTheme.secondaryText)
                Text(self.model.freshnessText).font(.caption2)
                    .foregroundStyle(self.model.isStale ? MidasTheme.warning : MidasTheme.secondaryText)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(MidasTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2).fill(MidasDGXSparkStyle.green)
                .frame(width: 38, height: 3).padding(.leading, 20)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(MidasDGXSparkStyle.green.opacity(0.22), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

struct MidasDGXSparkDetailView: View {
    let model: MidasDGXSparkPresentation
    let actions: MidasActions
    var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            MidasDGXSparkCard(model: self.model, isRefreshing: self.isRefreshing)
            VStack(alignment: .leading, spacing: 12) {
                Text("Token breakdown").font(.headline)
                self.tokenRow("Input, including cached", count: self.model.inputTokens)
                self.tokenRow("Cached input", count: self.model.cachedInputTokens)
                self.tokenRow("Output", count: self.model.outputTokens)
                Text("Cached input is part of input. Total tokens count input + output once.")
                    .font(.caption).foregroundStyle(MidasTheme.secondaryText)
            }
            .padding(16)
            .background(MidasTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 10) {
                Text("How value is estimated").font(.headline)
                if self.model.hasVerifiedModel {
                    Text("The recorded model is compared with \(DGXSparkPricing.hostedProviderName)’s "
                        + "\(DGXSparkPricing.modelDisplayName) API prices.")
                    Text("Per million tokens: \(self.rate(DGXSparkPricing.inputUSDPerMillion)) input, "
                        + "\(self.rate(DGXSparkPricing.cachedInputUSDPerMillion)) cached input, "
                        + "\(self.rate(DGXSparkPricing.outputUSDPerMillion)) output.")
                    Text("Local \(DGXSparkPricing.localQuantization) inference is quantized; "
                        + "this comparison does not imply identical hosted output.")
                    Link(
                        "\(DGXSparkPricing.hostedProviderName) pricing · checked \(DGXSparkPricing.verifiedOn)",
                        destination: DGXSparkPricing.sourceURL)
                    if let precise = self.model.preciseValueText {
                        Text("Recorded API-equivalent subtotal: \(precise) USD.")
                    }
                } else {
                    Text("An estimate needs a verified model and separate input, cached-input, and output counts.")
                }
                Text("This is the value of recorded tokens at cloud API rates. "
                    + "It is not a bill or a measure of electricity and hardware costs.")
                if self.model.hasUnpricedUsage {
                    Text("Some recorded tokens have no verified pricing breakdown and are excluded from the value.")
                }
            }
            .font(.caption).foregroundStyle(MidasTheme.secondaryText).textSelection(.enabled)
            DisclosureGroup("History & sync details") {
                VStack(alignment: .leading, spacing: 8) {
                    if let range = self.model.range {
                        Text("\(range.start)–\(range.end), inclusive UTC calendar days.")
                    }
                    Text("Recorded history only; gaps or earlier activity may be missing. "
                        + "The Spark summary always shows 30 days, independently of the overview’s period picker.")
                    if !self.model.modelNames.isEmpty {
                        Text("Recorded models: \(self.model.modelNames.joined(separator: ", "))")
                    }
                    Text(self.model.freshnessText)
                    Button("Refresh", action: self.actions.refresh)
                }
                .font(.caption).foregroundStyle(MidasTheme.secondaryText).padding(.top, 8)
                .textSelection(.enabled)
            }
        }
        .foregroundStyle(MidasTheme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rate(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    private func tokenRow(_ label: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(MidasTheme.secondaryText)
            Spacer(minLength: 8)
            Text(count?.formatted() ?? "Unavailable").monospacedDigit().textSelection(.enabled)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

enum MidasDGXSparkStyle {
    /// NVIDIA green accent, with a darker text variant for contrast on the light surface.
    static let green = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.65, green: 0.84, blue: 0.36, alpha: 1)
            : NSColor(red: 0.23, green: 0.40, blue: 0, alpha: 1)
    })
}
