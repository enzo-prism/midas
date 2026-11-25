import CodexBarCore
import Foundation

/// Suno has one source, the signed-in `suno` CLI, so it needs no settings fields. It stays available
/// once enabled so a missing or signed-out CLI shows setup guidance instead of hiding the provider.
struct SunoProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .suno
}
