import Foundation
import Testing
@testable import CodexBarCore

struct CodexRolloutArchiveTests {
    /// zstd of five rollout lines: session meta, turn context (gpt-6.1-sol), a Fast tier setting, and
    /// two cumulative token counts (1200/200/80, then 2000/500/140) on 2026-11-03.
    private static let archiveBase64 = """
    KLUv/WDpAa0HAKLOKx9QaasDQFKIVvDttWMk/uTz6UVUtWrFxlYejzmqqhX2hRhjzIAjkAjFHOjFKaaIYx03MtFJ515eW0UWLypZ7do\
    ZtG2LHrgTr+iFbuF7OtRtpccmoPINppu8txQjbbuVFVsKEQgrqpsmNHFsjuFg+iFPT5Q5pRG0mztUg0sXYvwxpjnh6Wy/SGfLJYr1br\
    wgMw2ZEhEApDnHHFCipz9lNauyfeOrVVHNLbPy0/Up+osaACARYEGAiRFoTneTvWdr+ZQLoMZp9c+UzAep2sBXKxgI74PZORUjqxs2e\
    gSwkHXqX6CgnScZjiA4dAwNaULm0XJ7
    """

    private static func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("midas-archive-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func writeArchive(in directory: URL, name: String = "rollout-2026-11-03.jsonl.zst") throws -> URL {
        let data = try #require(Data(base64Encoded: Self.archiveBase64))
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test
    func `compressed rollout parses to the same usage as its plain form`() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try Self.writeArchive(in: directory)
        let range = CostUsageScanner.CostUsageDayRange(
            since: Date(timeIntervalSince1970: 1_794_000_000 - 30 * 86400),
            until: Date(timeIntervalSince1970: 1_794_000_000 + 30 * 86400))

        let parsed = CostUsageScanner.parseCodexFile(fileURL: archive, range: range)

        #expect(parsed.sessionId == "zst-session-1")
        #expect(parsed.rows.map(\.input) == [1200, 800])
        #expect(parsed.rows.map(\.cached) == [200, 300])
        #expect(parsed.rows.map(\.output) == [80, 60])
        #expect(parsed.rows.map(\.model) == ["gpt-6.1-sol", "gpt-6.1-sol"])
        // The tier recorded inside the archive still applies.
        #expect(parsed.rows.map(\.fast) == [true, true])
    }

    @Test
    func `decompression leaves no plain copy behind and can stop at a prefix`() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try Self.writeArchive(in: directory)

        var temporaryPath: String?
        let text = try CodexRolloutArchive.withPlainFile(archive) { plain -> String in
            temporaryPath = plain.path
            return try String(contentsOf: plain, encoding: .utf8)
        }
        #expect(text.utf8.count == 745)
        #expect(text.hasPrefix(#"{"type":"session_meta""#))
        #expect(try !FileManager.default.fileExists(atPath: #require(temporaryPath)))

        let prefix = try CodexRolloutArchive.withPlainFile(archive, maxOutputBytes: 40) {
            try Data(contentsOf: $0)
        }
        #expect(prefix.count == 40)
    }

    @Test
    func `corrupt or truncated archives are rejected instead of half read`() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try #require(Data(base64Encoded: Self.archiveBase64))

        let truncated = directory.appendingPathComponent("truncated.jsonl.zst")
        try data.prefix(120).write(to: truncated)
        #expect(throws: CodexRolloutArchive.ArchiveError.corrupt) {
            try CodexRolloutArchive.withPlainFile(truncated) { _ in () }
        }

        let garbage = directory.appendingPathComponent("garbage.jsonl.zst")
        try Data("not zstd at all".utf8).write(to: garbage)
        #expect(throws: CodexRolloutArchive.ArchiveError.corrupt) {
            try CodexRolloutArchive.withPlainFile(garbage) { _ in () }
        }
        // The scanner reports no usage for an unreadable archive rather than failing the scan.
        let range = CostUsageScanner.CostUsageDayRange(since: Date(), until: Date())
        #expect(CostUsageScanner.parseCodexFile(fileURL: garbage, range: range).rows.isEmpty)
    }

    @Test
    func `a rollout present in both forms is listed once, as the plain file`() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let both = try Self.writeArchive(in: directory, name: "both.jsonl.zst")
        let plain = CodexRolloutArchive.plainSibling(of: both)
        try Data("{}\n".utf8).write(to: plain)
        let onlyArchive = try Self.writeArchive(in: directory, name: "only.jsonl.zst")

        #expect(plain.lastPathComponent == "both.jsonl")
        #expect(CodexRolloutArchive.preferringPlainFiles([both, plain, onlyArchive]) == [plain, onlyArchive])
        // The plain file wins even when only the archive was listed.
        #expect(CodexRolloutArchive.preferringPlainFiles([both, onlyArchive]) == [onlyArchive])
        #expect(CodexRolloutArchive.isRollout(plain))
        #expect(CodexRolloutArchive.isRollout(onlyArchive))
        #expect(!CodexRolloutArchive.isRollout(directory.appendingPathComponent("notes.zst")))
    }
}
