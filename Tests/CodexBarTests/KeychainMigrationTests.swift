import CodexBarCore
import Testing
@testable import CodexBar

struct KeychainMigrationTests {
    @Test
    func `migration list covers known keychain items`() {
        let items = Set(KeychainMigration.itemsToMigrate.map(\.label))
        // Accessibility migration targets Midas-owned items; legacy CodexBar items are adopted lazily.
        let service = MidasIdentity.keychainService
        let expected: Set = [
            "\(service):codex-cookie",
            "\(service):claude-cookie",
            "\(service):cursor-cookie",
            "\(service):factory-cookie",
            "\(service):minimax-cookie",
            "\(service):minimax-api-token",
            "\(service):augment-cookie",
            "\(service):copilot-api-token",
            "\(service):zai-api-token",
            "\(service):synthetic-api-key",
        ]
        #expect(!service.contains("steipete"))

        let missing = expected.subtracting(items)
        #expect(missing.isEmpty, "Missing migration entries: \(missing.sorted())")
    }
}
