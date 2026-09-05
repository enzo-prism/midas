import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexResetCreditsMenuTests {
    @Test
    func everyExpiryIsVisibleWithoutHovering() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let resets = CodexResetCreditsSnapshot(
            credits: [
                CodexResetCredit(id: "later", status: "available", expiresAt: now.addingTimeInterval(86400 * 5)),
                CodexResetCredit(id: "soon", status: "available", expiresAt: now.addingTimeInterval(86400)),
                CodexResetCredit(id: "spent", status: "spent", expiresAt: now),
            ],
            availableCount: 2,
            hasPerCreditExpiries: true,
            updatedAt: now)
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, codexResetCredits: resets, updatedAt: now)
        let metric = try #require(UsageMenuCardView.Model.codexResetCreditsMetric(
            snapshot: snapshot, now: now, percentStyle: .left))
        #expect(metric.statusText == "2 available")
        let lines = try #require(metric.detailText).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains(CodexResetCreditFormatting.absoluteExpiryText(now.addingTimeInterval(86400))))
        #expect(lines[1].contains(CodexResetCreditFormatting.absoluteExpiryText(now.addingTimeInterval(86400 * 5))))
    }
}
