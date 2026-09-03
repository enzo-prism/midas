import Foundation

public struct CostUsageCacheMaintenanceResult: Equatable, Sendable {
    public let removedPaths: [String]
    public let failedRemovals: [String: String]

    public init(removedPaths: [String], failedRemovals: [String: String]) {
        self.removedPaths = removedPaths
        self.failedRemovals = failedRemovals
    }
}

public enum CostUsageCacheMaintenance {
    public static func pruneStaleArtifacts(
        cacheRoot: URL? = nil,
        fileManager: FileManager = .default)
        -> CostUsageCacheMaintenanceResult
    {
        let root = cacheRoot ?? self.defaultCacheRoot(fileManager: fileManager)
        let directory = root.appendingPathComponent("cost-usage", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else {
            return CostUsageCacheMaintenanceResult(removedPaths: [], failedRemovals: [:])
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [])
        } catch {
            return CostUsageCacheMaintenanceResult(
                removedPaths: [],
                failedRemovals: [directory.path: error.localizedDescription])
        }

        let currentArtifactNames = self.currentArtifactNames()
        var removedPaths: [String] = []
        var failedRemovals: [String: String] = [:]
        for entry in entries {
            let name = entry.lastPathComponent
            guard self.shouldPruneArtifact(name: name, currentArtifactNames: currentArtifactNames) else {
                continue
            }
            do {
                try fileManager.removeItem(at: entry)
                removedPaths.append(entry.path)
            } catch {
                failedRemovals[entry.path] = error.localizedDescription
            }
        }

        return CostUsageCacheMaintenanceResult(
            removedPaths: removedPaths.sorted(),
            failedRemovals: failedRemovals)
    }

    private static func defaultCacheRoot(fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    private static func currentArtifactNames() -> Set<String> {
        var names = Set(UsageProvider.allCases.map { CostUsageCacheIO.cacheFileName(provider: $0) })
        names.insert(PiSessionCostCacheIO.cacheFileName())
        return names
    }

    private static func shouldPruneArtifact(name: String, currentArtifactNames: Set<String>) -> Bool {
        if name.hasPrefix(".tmp-") {
            return true
        }
        guard !currentArtifactNames.contains(name) else {
            return false
        }
        return self.isVersionedCostUsageArtifact(name)
    }

    private static func isVersionedCostUsageArtifact(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = String(name.dropLast(".json".count))
        guard let marker = stem.range(of: "-v", options: .backwards) else { return false }
        let version = stem[marker.upperBound...]
        return !version.isEmpty && version.allSatisfy(\.isNumber)
    }
}
