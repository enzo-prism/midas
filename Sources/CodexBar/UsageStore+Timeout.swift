import Foundation

extension UsageStore {
    nonisolated static func runWithTimeout(
        seconds: Double,
        operation: @escaping @Sendable () async -> String) async -> String
    {
        await UsageStoreProbeTimeout.run(seconds: seconds, operation: operation)
    }
}
