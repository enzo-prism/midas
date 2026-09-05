import Foundation
import Testing
@testable import CodexBarCore

struct CodexOAuthRefreshTimingTests {
    @Test
    func expiredIdentityDoesNotRefreshValidAccessToken() {
        let credentials = self.credentials(accessExpiry: 86400, identityExpiry: -86400, lastRefresh: nil)
        #expect(!credentials.needsRefresh)
    }

    @Test
    func expiredAccessRefreshesEvenWithFreshIdentityAndRefreshTimestamp() {
        let credentials = self.credentials(accessExpiry: -3600, identityExpiry: 86400, lastRefresh: Date())
        #expect(credentials.needsRefresh)
    }

    @Test
    func validAccessOverridesOldRefreshTimestamp() {
        let credentials = self.credentials(
            accessExpiry: 86400,
            identityExpiry: -86400,
            lastRefresh: Date().addingTimeInterval(-10 * 86400))
        #expect(!credentials.needsRefresh)
    }

    @Test
    func opaqueTokensKeepAgeBasedFallback() {
        for (age, expected) in [(3600.0, false), (9 * 86400.0, true)] {
            let credentials = CodexOAuthCredentials(
                accessToken: "opaque",
                refreshToken: "fixture",
                idToken: nil,
                accountId: nil,
                lastRefresh: Date().addingTimeInterval(-age))
            #expect(credentials.needsRefresh == expected)
        }
    }

    private func credentials(
        accessExpiry: TimeInterval,
        identityExpiry: TimeInterval,
        lastRefresh: Date?) -> CodexOAuthCredentials
    {
        CodexOAuthCredentials(
            accessToken: self.token(expiringIn: accessExpiry),
            refreshToken: "fixture",
            idToken: self.token(expiringIn: identityExpiry),
            accountId: nil,
            lastRefresh: lastRefresh)
    }

    private func token(expiringIn interval: TimeInterval) -> String {
        let payload = Data("{\"exp\":\(Int(Date().addingTimeInterval(interval).timeIntervalSince1970))}".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "fixture.\(payload).fixture"
    }
}
