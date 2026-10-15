import CodexBarCore
import Dispatch
import Foundation

/// Sheds discardable memory when the system reports memory pressure.
///
/// Midas is a long-lived menu bar process whose footprint is dominated by transient
/// scan allocations and offscreen WebViews. Neither is needed between refreshes, so a
/// pressure warning drops both instead of waiting for the kernel to compress pages.
@MainActor
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()

    private var source: DispatchSourceMemoryPressure?

    func start() {
        guard self.source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                OpenAIDashboardFetcher.evictAllCachedWebViews()
            }
            MemoryPressureRelief.releaseFreeMallocPages()
        }
        source.activate()
        self.source = source
    }
}
