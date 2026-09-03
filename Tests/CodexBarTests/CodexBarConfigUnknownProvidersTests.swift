import CodexBarCore
import Foundation
import Testing

struct CodexBarConfigUnknownProvidersTests {
    private static func decode(_ json: String) throws -> CodexBarConfig {
        try JSONDecoder().decode(CodexBarConfig.self, from: Data(json.utf8))
    }

    @Test
    func `loads config with unknown provider ids`() throws {
        let config = try Self.decode("""
        {"providers": [
            {"enabled": true, "id": "codex"},
            {"apiKey": "fictitious-secret", "enabled": false, "id": "futureprovider",
             "nested": {"count": 3, "tags": ["a", "b"]}}
        ], "version": 1}
        """)

        #expect(config.providers.map(\.id) == [.codex])
        #expect(config.providers.first?.enabled == true)
        #expect(config.unknownProviders.map(\.id) == ["futureprovider"])
        #expect(config.unknownProviders[0].fields["apiKey"] == .string("fictitious-secret"))
        #expect(config.unknownProviders[0].fields["enabled"] == .bool(false))
        #expect(
            config.unknownProviders[0].fields["nested"]
                == .object(["count": .int(3), "tags": .array([.string("a"), .string("b")])]))
    }

    @Test
    func `round trip preserves unknown entries`() throws {
        let config = try Self.decode("""
        {"providers": [
            {"enabled": true, "id": "codex"},
            {"apiKey": "fictitious-secret", "enabled": false, "id": "futureprovider"}
        ], "version": 1}
        """)

        let data = try JSONEncoder().encode(config)
        let reloaded = try JSONDecoder().decode(CodexBarConfig.self, from: data)

        #expect(reloaded.providers.map(\.id) == [.codex])
        #expect(reloaded.unknownProviders.count == 1)
        #expect(reloaded.unknownProviders[0].id == "futureprovider")
        #expect(reloaded.unknownProviders[0].fields["apiKey"] == .string("fictitious-secret"))
    }

    @Test
    func `normalized keeps unknown entries and backfills known providers`() throws {
        let config = try Self.decode("""
        {"providers": [
            {"enabled": true, "id": "codex"},
            {"enabled": false, "id": "futureprovider"}
        ], "version": 1}
        """)

        let normalized = config.normalized()

        #expect(normalized.unknownProviders.map(\.id) == ["futureprovider"])
        #expect(normalized.providers.contains(where: { $0.id == .meta }))
        #expect(normalized.providers.contains(where: { $0.id == .codex }))
    }
}
