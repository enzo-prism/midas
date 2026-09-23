import Foundation
import Testing
@testable import CodexBar

struct UsageStoreProbeTimeoutTests {
    @Test
    func `returns operation result when it finishes first`() async {
        let result = await UsageStoreProbeTimeout.run(seconds: 5) { "probe-ok" }
        #expect(result == "probe-ok")
    }

    @Test
    func `returns timeout message when deadline wins`() async {
        let result = await UsageStoreProbeTimeout.run(seconds: 1) {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return "too-late"
        }
        #expect(result == "Probe timed out after 1s")
    }

    @Test
    func `usage store wrapper forwards to probe timeout`() async {
        let fast = await UsageStore.runWithTimeout(seconds: 5) { "forwarded-ok" }
        #expect(fast == "forwarded-ok")
        let slow = await UsageStore.runWithTimeout(seconds: 1) {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return "too-late"
        }
        #expect(slow == "Probe timed out after 1s")
    }
}
