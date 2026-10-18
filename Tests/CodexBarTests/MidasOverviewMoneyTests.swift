import Foundation
import Testing
@testable import CodexBar

struct MidasOverviewMoneyTests {
    @Test func providerSpendRetainsCentsAtOrdinaryAndLargeAmounts() throws {
        for amount in [1.01, 18.72, 42.80, 128.42, 12345.67, 1_234_567.89] {
            let text = MidasOverviewMoney.format(amount, currency: "USD")
            let parsed = try Double(text, format: .currency(code: "USD"))
            #expect(abs(parsed - amount) < 0.000_001, "\(text) must preserve the provider's cents")
        }
    }

    @Test func tinyNonzeroSpendIsNeverDisplayedAsZero() throws {
        for amount in [0.000_001, 0.001, 0.009_999] {
            let text = MidasOverviewMoney.format(amount, currency: "USD")
            #expect(text.hasPrefix("<"))
            let threshold = try Double(String(text.dropFirst()), format: .currency(code: "USD"))
            #expect(threshold == 0.01)
        }
    }

    @Test func knownZeroAndOneCentRemainExactValues() throws {
        for amount in [0.0, 0.01] {
            let text = MidasOverviewMoney.format(amount, currency: "USD")
            #expect(!text.hasPrefix("<"))
            #expect(try Double(text, format: .currency(code: "USD")) == amount)
        }
    }

    @Test func currencyFormattingPreservesCentsWithoutCombiningCurrencies() throws {
        for currency in ["USD", "EUR", "GBP", "CHF"] {
            let text = MidasOverviewMoney.format(128.42, currency: currency)
            let parsed = try Double(text, format: .currency(code: currency))
            #expect(abs(parsed - 128.42) < 0.000_001)
        }
    }
}
