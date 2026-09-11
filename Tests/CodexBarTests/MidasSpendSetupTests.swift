import Foundation
import Testing
@testable import CodexBar

struct MidasSpendSetupTests {
    @Test func blankRateExplicitlyExcludesDollarEstimate() {
        #expect(MidasSpendSetupRate.parse("   ") == 0)
    }

    @Test func invalidRatesDoNotSilentlyBecomeZeroOrAcceptPrefixes() {
        for input in ["-1", "1001", "NaN", "inf", "2 dollars", "$2", "1.2.3", "1e3"] {
            #expect(MidasSpendSetupRate.parse(input, locale: Locale(identifier: "en_US")) == nil)
        }
    }

    @Test func ratesUseLocalDecimalSeparator() {
        #expect(MidasSpendSetupRate.parse("0.75", locale: Locale(identifier: "en_US")) == 0.75)
        #expect(MidasSpendSetupRate.parse("0,75", locale: Locale(identifier: "de_DE")) == 0.75)
        #expect(MidasSpendSetupRate.parse("1000", locale: Locale(identifier: "en_US")) == 1000)
    }
}
