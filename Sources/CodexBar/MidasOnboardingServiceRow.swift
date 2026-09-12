import CodexBarCore
import SwiftUI

struct MidasOnboardingServiceRow: View {
    let provider: UsageProvider
    let isSelected: Bool
    let action: () -> Void

    private var title: String {
        switch self.provider {
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .meta: "Meta"
        default: self.provider.rawValue
        }
    }

    private var detail: String {
        switch self.provider {
        case .codex: "OpenAI accounts across your computers"
        case .cursor: "Usage from your Cursor account"
        case .meta: "Muse activity on this Mac"
        default: ""
        }
    }

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 14) {
                if let image = ProviderBrandIcon.image(for: self.provider) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.title).font(.headline)
                    Text(self.detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: self.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(self.isSelected ? MidasTheme.accent : .secondary)
                    .accessibilityHidden(true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                self.isSelected ? MidasTheme.accent.opacity(0.09) : Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(self.isSelected ? MidasTheme.accent.opacity(0.65) : Color.primary.opacity(0.10)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(self.title + ", " + self.detail)
        .accessibilityValue(self.isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }
}
