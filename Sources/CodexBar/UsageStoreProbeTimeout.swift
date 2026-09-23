import Foundation

/// Runs a debug-probe operation with a timeout, returning a timeout message when the deadline wins.
/// Pure extraction of `UsageStore.runWithTimeout` so probe timeouts are unit-testable in isolation.
enum UsageStoreProbeTimeout {
    nonisolated static func run(
        seconds: Double,
        operation: @escaping @Sendable () async -> String) async -> String
    {
        await withTaskGroup(of: String?.self) { group -> String in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next()?.flatMap(\.self)
            group.cancelAll()
            return result ?? "Probe timed out after \(Int(seconds))s"
        }
    }
}
