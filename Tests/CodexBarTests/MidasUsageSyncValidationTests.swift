import Foundation
import Testing
@testable import CodexBarCore

struct MidasUsageSyncValidationTests {
    private let now = Date(timeIntervalSince1970: 1_792_289_700)

    @Test func optimizedOpaqueIDsMatchPreviouslyPublishedBytes() {
        let workspace = MidasUsageSyncWorkspace(identitySalt: String(repeating: "s", count: 64))
        let vectors: [([String], String)] = [
            ([], "227702a0577bed6bd037181d91800c511aaa23ea01fab6d8a3524ecdd9054de0"),
            (["a:b", "c"], "53d8c6bb277acb44793c8de041aae805d09b3daae1fc80042d7cb26d2dff86be"),
            (
                ["private@example.test", "/private/Session", "quote\"\\line\n", "日本語"],
                "0e7c5d117a35856f687279486e559cc2787d7d3e91fd1fc8087701c580578c5a"),
        ]
        for (components, expected) in vectors {
            #expect(workspace.opaqueID(provider: .codex, components: components) == expected)
        }
    }

    @Test func utcObservationValidationIncludesFractionalDayEndAndRejectsAdjacentDays() throws {
        let workspace = MidasUsageSyncWorkspace(createdAt: self.now)
        let formatter = ISO8601DateFormatter()
        for day in ["1970-01-01", "2024-02-29", "2026-03-08", "2026-11-01"] {
            let start = try #require(formatter.date(from: day + "T00:00:00Z"))
            let published = max(self.now, start.addingTimeInterval(86400))
            func publication(offset: TimeInterval) -> MidasUsageSyncPublication {
                MidasUsageSyncPublication(
                    workspaceID: workspace.id,
                    deviceID: UUID(),
                    deviceName: "Fixture",
                    publishedAt: published,
                    events: [.init(
                        id: workspace.opaqueID(provider: .codex, components: [day]),
                        provider: .codex,
                        day: day,
                        observedAt: start.addingTimeInterval(offset),
                        values: .init(tokens: 1, costUSD: 0))])
            }
            for offset in [0.0, 0.001, 43200, 86399.999] {
                try publication(offset: offset).validate(workspaceID: workspace.id, now: published)
            }
            for offset in [-0.001, 86400, 86400.001] {
                #expect(throws: MidasUsageSyncError.invalidRecord) {
                    try publication(offset: offset).validate(workspaceID: workspace.id, now: published)
                }
            }
        }
    }

    @Test func accountReportDayRemainsIndependentOfObservationDay() throws {
        let workspace = MidasUsageSyncWorkspace(createdAt: self.now)
        let publication = MidasUsageSyncPublication(
            workspaceID: workspace.id,
            deviceID: UUID(),
            deviceName: "Fixture",
            publishedAt: self.now,
            accountDays: [.init(
                accountScope: workspace.opaqueID(provider: .cursor, components: ["fixture"]),
                provider: .cursor,
                day: "2026-10-01",
                observedAt: self.now,
                values: .init(tokens: 10, costUSD: 1))])
        try publication.validate(workspaceID: workspace.id, now: self.now)
    }
}
