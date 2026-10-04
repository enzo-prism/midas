import Testing
@testable import CodexBar

struct ClaudeAccountConnectionPresentationTests {
    @Test
    func `credential badges distinguish subscription and organization connections without exposing credentials`() {
        #expect(ClaudeAccountConnectionPresentation.credentialKind("sk-ant-oat-test") == "OAuth")
        #expect(ClaudeAccountConnectionPresentation.credentialKind("Bearer sk-ant-oat-test") == "OAuth")
        #expect(ClaudeAccountConnectionPresentation.credentialKind("sessionKey=test-only") == "Web session")
        #expect(ClaudeAccountConnectionPresentation.credentialKind("sk-ant-admin-test") == "Organization API")
        #expect(ClaudeAccountConnectionPresentation.credentialKind("  ") == "Connection unavailable")
    }
}
