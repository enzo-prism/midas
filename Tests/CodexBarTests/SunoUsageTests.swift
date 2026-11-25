import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct SunoUsageTests {
    /// Shape captured from `suno credits --json --no-browser --quiet` (suno 0.10.1) on a Pro plan,
    /// with the long feature and model lists shortened.
    private static let creditsEnvelope = #"""
    {"version":"1","status":"success","data":{"credits":0,"total_credits_left":2030,"monthly_usage":470,
    "monthly_limit":2500,"is_active":true,"plan":{"name":"Pro Plan","plan_key":"pro",
    "usage_plan_features":[{"name":"commercial_rights"}]},"models":[{"name":"v6","can_use":true}],
    "period":"month","renews_on":"2026-12-09T17:20:35Z","download_usage":{"current_period_downloads_used":20,
    "current_period_downloads_limit":20,"additional_download_remaining":0,
    "current_period_download_top_ups_purchased":0,"current_period_download_top_up_purchase_limit":30}}}
    """#

    private static let renewsAt = ISO8601DateFormatter().date(from: "2026-12-09T17:20:35Z")!

    @Test
    func `parses credits, downloads and plan`() throws {
        let snapshot = try SunoCreditsParser.parse(
            stdout: Self.creditsEnvelope,
            stderr: "",
            exitCode: 0,
            updatedAt: Date(timeIntervalSince1970: 1))

        #expect(snapshot.displayPlan == "Pro")
        #expect(snapshot.creditsUsed == 470)
        #expect(snapshot.creditLimit == 2500)
        #expect(snapshot.planCreditsLeft == 2030)
        #expect(snapshot.totalCreditsLeft == 2030)
        #expect(snapshot.topUpCredits == 0)
        #expect(snapshot.downloadsUsed == 20)
        #expect(snapshot.downloadLimit == 20)
        #expect(snapshot.renewsAt == Self.renewsAt)
    }

    @Test
    func `maps to credit and download windows`() throws {
        let usage = try SunoCreditsParser.parse(
            stdout: Self.creditsEnvelope,
            stderr: "",
            exitCode: 0,
            updatedAt: Date(timeIntervalSince1970: 1)).toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 18.8)
        #expect(usage.primary?.resetDescription == "470 / 2,500 credits")
        #expect(usage.primary?.resetsAt == Self.renewsAt)
        // November 9 → December 9 is 30 days.
        #expect(usage.primary?.windowMinutes == 30 * 24 * 60)
        #expect(usage.secondary?.usedPercent == 100)
        #expect(usage.secondary?.resetDescription == "20 / 20 downloads")
        #expect(usage.subscriptionRenewsAt == Self.renewsAt)
        #expect(usage.loginMethod(for: .suno) == "Pro")
        #expect(usage.identity(for: .suno)?.accountEmail == nil)
    }

    @Test
    func `shows top-up credits, extra downloads and an inactive plan`() {
        let snapshot = SunoUsageSnapshot(
            planName: "Premier Plan",
            isActive: false,
            period: "month",
            creditsUsed: 9000,
            creditLimit: 10000,
            totalCreditsLeft: 1500,
            topUpCredits: 500,
            downloadsUsed: 3,
            downloadLimit: 50,
            additionalDownloadsRemaining: 10,
            renewsAt: nil,
            updatedAt: Date())
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.displayPlan == "Premier · Inactive")
        #expect(usage.primary?.resetDescription == "9,000 / 10,000 credits · +500 top-up")
        #expect(usage.secondary?.resetDescription == "3 / 50 downloads · +10 extra")
        #expect(usage.primary?.windowMinutes == nil)
    }

    @Test
    func `period length follows the calendar month that ends at renewal`() throws {
        let marchFirst = try #require(ISO8601DateFormatter().date(from: "2027-03-01T00:00:00Z"))
        #expect(SunoUsageSnapshot.periodMinutes(period: "month", endingAt: marchFirst) == 28 * 24 * 60)
        #expect(SunoUsageSnapshot.periodMinutes(period: "day", endingAt: nil) == 24 * 60)
        #expect(SunoUsageSnapshot.periodMinutes(period: "unknown", endingAt: marchFirst) == nil)
    }

    @Test
    func `auth failure envelope on stderr means signed out`() {
        let stderr = #"""
        {"version":"1","status":"error","error":{"code":"auth_expired","message":"Token validation failed",
        "suggestion":"Run `suno auth --refresh`"}}
        """#
        #expect(throws: SunoUsageError.signedOut("auth_expired")) {
            try SunoCreditsParser.parse(stdout: "", stderr: stderr, exitCode: 2, updatedAt: Date())
        }
    }

    @Test
    func `exit codes without an envelope map to the CLI contract`() {
        #expect(throws: SunoUsageError.signedOut(nil)) {
            try SunoCreditsParser.parse(stdout: "", stderr: "", exitCode: 2, updatedAt: Date())
        }
        #expect(throws: SunoUsageError.rateLimited) {
            try SunoCreditsParser.parse(stdout: "", stderr: "", exitCode: 4, updatedAt: Date())
        }
        #expect(throws: SunoUsageError.cliFailed("connection reset")) {
            try SunoCreditsParser.parse(stdout: "", stderr: "connection reset\n", exitCode: 1, updatedAt: Date())
        }
    }

    @Test
    func `rejects a success envelope without an allowance`() {
        #expect(throws: SunoUsageError.parseFailed("Suno did not report a credit allowance.")) {
            try SunoCreditsParser.parse(
                stdout: #"{"version":"1","status":"success","data":{"credits":10}}"#,
                stderr: "",
                exitCode: 0,
                updatedAt: Date())
        }
    }

    @Test
    func `runs the CLI read-only without a browser`() async throws {
        let script = try FakeCLI.make(name: "suno", body: """
        if [ "$*" != "credits --json --no-browser --quiet" ]; then
          echo '{"version":"1","status":"error","error":{"code":"bad_args","message":"unexpected args"}}' >&2
          exit 3
        fi
        cat <<'JSON'
        \(Self.creditsEnvelope)
        JSON
        """)
        defer { script.remove() }

        let snapshot = try await SunoCLIProbe().fetch(
            environment: ["SUNO_CLI_PATH": script.path, "PATH": "/usr/bin:/bin"],
            now: Date(timeIntervalSince1970: 7))
        #expect(snapshot.creditsUsed == 470)
        #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 7))
    }

    @Test
    func `descriptor uses the CLI and stays off by default`() {
        let descriptor = SunoProviderDescriptor.descriptor
        #expect(descriptor.metadata.displayName == "Suno")
        #expect(descriptor.metadata.defaultEnabled == false)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .cli])
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-suno")
        #expect(ProviderDescriptorRegistry.descriptor(for: .suno).id == .suno)
    }
}
