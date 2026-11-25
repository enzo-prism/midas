import Foundation

/// Antigravity wraps the Cloud Code response in "response" on its local RPC.
struct GeminiQuotaSummary: Decodable, Sendable {
    struct Envelope: Decodable {
        let response: GeminiQuotaSummary
    }

    struct Group: Decodable {
        let buckets: [Bucket]?
    }

    struct Bucket: Decodable {
        let bucketId: String?
        let remainingFraction: Double?
        let resetTime: String?
        let disabled: Bool?
    }

    let groups: [Group]?
    let buckets: [Bucket]?

    var fiveHour: RateWindow? {
        self.window(id: "gemini-5h", minutes: 300)
    }

    var weekly: RateWindow? {
        self.window(id: "gemini-weekly", minutes: 10080)
    }

    var hasReading: Bool {
        self.fiveHour != nil || self.weekly != nil
    }

    private func window(id: String, minutes: Int) -> RateWindow? {
        let candidates = (self.groups ?? []).flatMap { $0.buckets ?? [] } + (self.buckets ?? [])
        guard let bucket = candidates.first(where: {
            $0.bucketId == id && $0.disabled != true && $0.remainingFraction.map { (0...1).contains($0) } == true
        }), let fraction = bucket.remainingFraction else { return nil }
        return RateWindow(
            usedPercent: 100 - fraction * 100,
            windowMinutes: minutes,
            resetsAt: bucket.resetTime.flatMap(AntigravityStatusProbe.parseDate),
            resetDescription: nil)
    }
}
