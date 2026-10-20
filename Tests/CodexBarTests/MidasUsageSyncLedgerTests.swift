import Foundation
import Testing
@testable import CodexBarCore

struct MidasUsageSyncLedgerTests {
    private let now = Date(timeIntervalSince1970: 1_792_065_600)
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private var workspace: MidasUsageSyncWorkspace {
        MidasUsageSyncWorkspace(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            identitySalt: String(repeating: "a", count: 64),
            createdAt: self.now)
    }

    @Test func distinctDeviceEventsAddWithinTheirOwnProviders() throws {
        let local = self.publication(events: [
            self.event("local-codex", values: .init(tokens: 100, costUSD: 1)),
            self.event("local-claude", provider: .claude, values: .init(tokens: 50, costUSD: 0.5)),
        ])
        let remote = self.publication(device: self.second, events: [
            self.event("remote-codex", values: .init(tokens: 200, costUSD: 2)),
            self.event("remote-meta", provider: .meta, values: .init(tokens: 75, costUSD: 0.75)),
        ])
        let ledger = try self.ledger([local, remote])
        #expect(ledger.snapshots[.codex]?.last30DaysTokens == 300)
        #expect(ledger.snapshots[.codex]?.last30DaysCostUSD == 3)
        #expect(ledger.snapshots[.claude]?.last30DaysTokens == 50)
        #expect(ledger.snapshots[.meta]?.last30DaysTokens == 75)
        #expect(ledger.snapshots[.cursor] == nil)
        #expect(ledger.publications.map(\.deviceID) == [self.first, self.second])
    }

    @Test func copiedStreamingPrefixCannotEraseTheWholeCompletedRecord() throws {
        let complete = self.event("same-turn", at: self.now.addingTimeInterval(-60), values: .init(
            tokens: 200,
            requests: 1,
            costUSD: 3,
            tokenMix: .init(inputTokens: 150, outputTokens: 50),
            model: "gpt-5",
            estimatedRequests: 1))
        let prefix = self.event("same-turn", values: .init(
            tokens: 100,
            requests: 1,
            costUSD: 9,
            tokenMix: .init(inputTokens: 90, outputTokens: 10),
            model: "gpt-5",
            estimatedRequests: 1))
        let publications = [
            self.publication(events: [complete]),
            self.publication(device: self.second, events: [prefix, prefix]),
        ]
        for order in [publications, Array(publications.reversed())] {
            let snapshot = try #require(self.ledger(Array(order)).snapshots[.codex])
            #expect(snapshot.last30DaysTokens == 200)
            #expect(snapshot.last30DaysCostUSD == 3)
            #expect(snapshot.daily.first?.inputTokens == 150)
            #expect(snapshot.daily.first?.outputTokens == 50)
            #expect(snapshot.daily.first?.requestCount == 1)
            #expect(snapshot.daily.first?.modelBreakdowns?.first?.costUSD == 3)
        }
    }

    @Test func cursorSameAccountIsCountedOnceAndNewerCorrectionCanLowerTotals() throws {
        let stale = self.account("same-account", observedAt: self.now.addingTimeInterval(-60), values: .init(
            tokens: 100,
            requests: 10,
            costUSD: 9,
            provenance: .vendorMetered))
        let corrected = self.account("same-account", values: .init(
            tokens: 70,
            requests: 7,
            costUSD: 5,
            provenance: .vendorMetered))
        let anotherAccount = self.account("another-account", values: .init(
            tokens: 20,
            requests: 2,
            costUSD: 2,
            provenance: .vendorMetered))
        let publications = [
            self.publication(accounts: [stale]),
            self.publication(device: self.second, accounts: [corrected, anotherAccount]),
        ]
        for order in [publications, Array(publications.reversed())] {
            let snapshot = try #require(self.ledger(Array(order)).snapshots[.cursor])
            #expect(snapshot.last30DaysTokens == 90)
            #expect(snapshot.last30DaysRequests == 9)
            #expect(snapshot.last30DaysCostUSD == 7)
            #expect(snapshot.meteredCostUSD == 7)
            #expect(snapshot.costProvenance == .vendorMetered)
            #expect(snapshot.accountEmail == nil)
        }
    }

    @Test func providerEventsAndAccountDayReportsCannotCrossChannels() {
        let quotaLikeEvent = self.event("account-record", provider: .cursor)
        let wrongAccount = MidasUsageSyncAccountDay(
            accountScope: self.workspace.opaqueID(provider: .claude, components: ["account"]),
            provider: .claude,
            day: MidasUsageSyncPublication.day(self.now),
            observedAt: self.now,
            values: .init(tokens: 1, costUSD: 1))
        for publication in [
            self.publication(events: [quotaLikeEvent]),
            self.publication(accounts: [wrongAccount]),
        ] {
            #expect(throws: MidasUsageSyncError.invalidRecord) { try self.ledger([publication]) }
        }
    }

    @Test func newestPublicationReplacesThatDeviceRatherThanAddingBothVersions() throws {
        let old = self.publication(at: self.now.addingTimeInterval(-60), events: [
            self.event("old", at: self.now.addingTimeInterval(-60), values: .init(tokens: 100, costUSD: 1)),
        ])
        let fresh = self.publication(events: [self.event("fresh", values: .init(tokens: 200, costUSD: 2))])
        let peer = self.publication(device: self.second, events: [
            self.event("peer", values: .init(tokens: 50, costUSD: 0.5)),
        ])
        for order in [[old, fresh, peer], [peer, fresh, old]] {
            let ledger = try self.ledger(order)
            #expect(ledger.publications == [fresh, peer])
            #expect(ledger.snapshots[.codex]?.last30DaysTokens == 250)
            #expect(ledger.snapshots[.codex]?.last30DaysCostUSD == 2.5)
        }
    }

    @Test func duplicateDevicePublicationsDoNotConsumeTheCombinedRecordCap() throws {
        // Four copies exceed the combined cap before device selection, but only one is current.
        let rows = Array(repeating: self.event("same-event"), count: 63000)
        let publications = (0..<4).map { offset in
            self.publication(at: self.now.addingTimeInterval(Double(offset - 3)), events: rows)
        }
        let ledger = try self.ledger(publications)
        #expect(ledger.publications.count == 1)
        #expect(ledger.snapshots[.codex]?.last30DaysTokens == 100)
    }

    @Test func distinctDevicesStillEnforceTheCombinedRecordCap() throws {
        let rows = Array(repeating: self.event("same-event"), count: 84000)
        let third = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let publications = [self.first, self.second, third].map { self.publication(device: $0, events: rows) }
        #expect(throws: MidasUsageSyncError.limitExceeded) { try self.ledger(publications) }
    }

    @Test func permutationsProduceIdenticalMonetaryAndModelTotals() throws {
        let rows = [
            self.event("large", values: .init(tokens: 100, costUSD: 100_000_000, model: "gpt-5")),
            self.event("small-one", values: .init(tokens: 1, costUSD: 0.00000001, model: "gpt-5")),
            self.event("small-two", values: .init(tokens: 1, costUSD: 0.00000001, model: "gpt-5")),
        ]
        let third = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let publications = zip([self.first, self.second, third], rows).map {
            self.publication(device: $0.0, events: [$0.1])
        }
        let baseline = try self.ledger(publications).snapshots
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            #expect(try self.ledger(order.map { publications[$0] }).snapshots == baseline)
            let combined = self.publication(events: order.map { rows[$0] })
            #expect(try self.ledger([combined]).snapshots == baseline)
        }
        #expect(baseline[.codex]?.daily.first?.totalTokens == 102)
        #expect(baseline[.codex]?.daily.first?.modelBreakdowns?.count == 1)
    }

    @Test func equalTimestampConflictsChooseOneRecordDeterministically() throws {
        let one = self.event("conflict", values: .init(tokens: 100, costUSD: 1, model: "gpt-5"))
        let two = self.event("conflict", values: .init(tokens: 100, costUSD: 2, model: "gpt-5"))
        let forward = try self.ledger([
            self.publication(events: [one]),
            self.publication(device: self.second, events: [two]),
        ])
        let reversed = try self.ledger([
            self.publication(device: self.second, events: [two]),
            self.publication(events: [one]),
        ])
        #expect(forward.snapshots == reversed.snapshots)
        #expect(forward.snapshots[.codex]?.last30DaysTokens == 100)
        #expect([1.0, 2.0].contains(forward.snapshots[.codex]?.last30DaysCostUSD ?? -1))
    }

    @Test func mixedSourcesKeepUnpricedCoverageAndOnlyKnownSubtotals() throws {
        let rows = [
            self.account("metered", values: .init(
                tokens: 100,
                requests: 1,
                costUSD: 2,
                provenance: .vendorMetered)),
            self.account("estimated", values: .init(
                tokens: 200,
                requests: 1,
                costUSD: 3,
                provenance: .listPriceEstimate,
                estimatedRequests: 1)),
            self.account("unknown", values: .init(
                tokens: 50,
                requests: 3,
                costUSD: nil,
                provenance: .unknown,
                unpricedRequests: 3)),
        ]
        let snapshot = try #require(self.ledger([self.publication(accounts: rows)]).snapshots[.cursor])
        #expect(snapshot.last30DaysTokens == 350)
        #expect(snapshot.last30DaysCostUSD == 5)
        #expect(snapshot.last30DaysRequests == 5)
        #expect(snapshot.costProvenance == .mixed)
        #expect(snapshot.meteredCostUSD == nil)
        #expect(snapshot.daily.first?.unpricedRequestCount == 3)
        #expect(snapshot.daily.first?.estimatedRequestCount == 1)
        #expect(snapshot.daily.first?.coverageCounts.total == 5)
    }

    @Test func unknownMeasurementsStayUnavailableAndRecordedZeroStaysZero() throws {
        let unknown = try #require(self.ledger([self.publication(events: [self.event(
            "unknown",
            values: .init(tokens: nil, costUSD: nil, provenance: .unknown))])]).snapshots[.codex])
        #expect(unknown.last30DaysTokens == nil)
        #expect(unknown.last30DaysCostUSD == nil)
        #expect(unknown.last30DaysRequests == nil)
        #expect(unknown.costProvenance == .unknown)
        #expect(unknown.daily.first?.unpricedRequestCount == 1)

        let zero = try #require(self.ledger([self.publication(events: [self.event(
            "zero",
            values: .init(tokens: 0, requests: 0, costUSD: 0))])]).snapshots[.codex])
        #expect(zero.last30DaysTokens == 0)
        #expect(zero.last30DaysCostUSD == 0)
        #expect(zero.last30DaysRequests == 0)
        #expect(zero.daily.first?.unpricedRequestCount == 0)
    }

    @Test func midnightAndMonthBoundariesUseUTC() throws {
        let now = try self.date("2026-10-01T00:30:00Z")
        let before = try self.date("2026-09-30T23:59:59Z")
        let after = try self.date("2026-10-01T00:00:00Z")
        let publication = self.publication(at: now, events: [
            self.event("before", at: before, values: .init(tokens: 9, costUSD: 0.9)),
            self.event("after", at: after, values: .init(tokens: 11, costUSD: 1.1)),
        ])
        let snapshot = try #require(self.ledger([publication], now: now).snapshots[.codex])
        #expect(snapshot.daily.map(\.date) == ["2026-09-30", "2026-10-01"])
        #expect(snapshot.sessionTokens == 11)
        #expect(snapshot.sessionCostUSD == 1.1)
        #expect(snapshot.last30DaysTokens == 20)
    }

    @Test func rollingHistoryIncludesTheEntire365thUTCDay() throws {
        let firstDay = self.now.addingTimeInterval(-364 * 86400)
        let oldDay = self.now.addingTimeInterval(-365 * 86400)
        let publication = self.publication(events: [
            self.event("too-old", at: oldDay, values: .init(tokens: 1, costUSD: 1)),
            self.event("cutoff", at: firstDay.addingTimeInterval(-3600), values: .init(tokens: 2, costUSD: 2)),
            self.event("today", values: .init(tokens: 3, costUSD: 3)),
        ])
        let snapshot = try #require(self.ledger([publication]).snapshots[.codex])
        #expect(snapshot.daily.map(\.date) == [
            MidasUsageSyncPublication.day(firstDay),
            MidasUsageSyncPublication.day(self.now),
        ])
        #expect(snapshot.last30DaysTokens == 5)
        #expect(snapshot.last30DaysCostUSD == 5)
        #expect(snapshot.historyDays == 365)
    }

    @Test func permittedClockSkewDoesNotShowTomorrowsUsageToday() throws {
        let now = try self.date("2026-10-15T23:59:50Z")
        let later = now.addingTimeInterval(20)
        let publication = self.publication(at: now, events: [
            self.event("today", at: now, values: .init(tokens: 3, costUSD: 3)),
            self.event("tomorrow", at: later, values: .init(tokens: 99, costUSD: 99)),
        ])
        let today = try #require(self.ledger([publication], now: now).snapshots[.codex])
        #expect(today.daily.map(\.date) == ["2026-10-15"])
        #expect(today.last30DaysTokens == 3)
        let tomorrow = try #require(self.ledger([publication], now: later).snapshots[.codex])
        #expect(tomorrow.daily.map(\.date) == ["2026-10-15", "2026-10-16"])
        #expect(tomorrow.last30DaysTokens == 102)
    }

    @Test func retainedLocalHistorySurvivesLogRemovalAndExpiresOldDays() {
        let cutoff = self.now.addingTimeInterval(-364 * 86400)
        let retained = self.event("retained", at: cutoff)
        let old = self.event("expired", at: self.now.addingTimeInterval(-365 * 86400))
        let previous = self.publication(at: self.now.addingTimeInterval(-60), events: [retained, old])
        let fresh = self.publication(events: [self.event("new")], excluded: 2)
        let merged = MidasUsageSyncLedger.retainingLocalHistory(previous: previous, fresh: fresh)
        #expect(Set(merged.events.map(\.id)) == Set([retained.id, fresh.events[0].id]))
        #expect(merged.publishedAt == self.now)
        #expect(merged.excludedRecords == 2)
    }

    @Test func oversizedHistoryRollsOlderDaysIntoDeviceTotalsWithoutChangingTheLedger() throws {
        let day: TimeInterval = 86400
        var events: [MidasUsageSyncEvent] = []
        for offset in 0..<6 {
            for index in 0..<20 {
                let model = index.isMultiple(of: 2) ? "gpt-5.5" : nil
                let cost: Double? = index.isMultiple(of: 3) ? nil : Double(index) / 10
                events.append(self.event(
                    "event-\(offset)-\(index)",
                    provider: index.isMultiple(of: 5) ? .claude : .codex,
                    at: self.now.addingTimeInterval(-Double(offset) * day - Double(index)),
                    values: .init(
                        tokens: 100 + index,
                        requests: index.isMultiple(of: 4) ? nil : 1,
                        costUSD: cost,
                        tokenMix: .init(inputTokens: 60 + index, outputTokens: 40, cacheReadTokens: 10),
                        provenance: cost == nil ? .unknown : .listPriceEstimate,
                        model: model,
                        unpricedRequests: cost == nil ? 1 : 0,
                        estimatedRequests: cost == nil ? 0 : 1)))
            }
        }
        let fresh = self.publication(events: events)
        let full = MidasUsageSyncLedger.retainingLocalHistory(previous: nil, fresh: fresh)
        #expect(full.events.count == events.count)
        let todayBytes = try events.filter { $0.day == MidasUsageSyncPublication.day(self.now) }
            .reduce(0) { try $0 + JSONEncoder().encode($1).count + 1 }
        // Room for today's events and every day's rollups, but not a second day of individual events.
        let rollupBytes = try MidasUsageSyncRollup.rollUp(events, deviceID: self.first)
            .reduce(0) { try $0 + JSONEncoder().encode($1).count + 1 }
        let budget = 4096 + todayBytes + rollupBytes + 256
        let limited = MidasUsageSyncLedger.retainingLocalHistory(
            previous: nil, fresh: fresh, maximumBytes: budget)
        #expect(limited.events.count < events.count)
        #expect(limited.excludedRecords == 0)
        let rollups = limited.events.filter { MidasUsageSyncRollup.isRollup($0, deviceID: self.first) }
        #expect(!rollups.isEmpty)
        // Every provider day is either individual events or rollups, and newer days stay individual.
        let rolledDays = Set(rollups.map(\.day))
        let individualDays = Set(limited.events.filter { !rollups.contains($0) }.map(\.day))
        #expect(rolledDays.isDisjoint(with: individualDays))
        #expect(individualDays.contains(MidasUsageSyncPublication.day(self.now)))
        #expect((rolledDays.max() ?? "") < (individualDays.min() ?? ""))
        try limited.validate(workspaceID: self.workspace.id, now: self.now)
        let expected = try self.ledger([full]).snapshots
        let actual = try self.ledger([limited]).snapshots
        for provider in [UsageProvider.codex, .claude] {
            let lhs = try #require(expected[provider])
            let rhs = try #require(actual[provider])
            #expect(lhs.last30DaysTokens == rhs.last30DaysTokens)
            #expect(lhs.last30DaysRequests == rhs.last30DaysRequests)
            #expect(abs((lhs.last30DaysCostUSD ?? 0) - (rhs.last30DaysCostUSD ?? 0)) < 0.000001)
            #expect(lhs.daily.map(\.date) == rhs.daily.map(\.date))
            #expect(lhs.daily.map(\.unpricedRequestCount) == rhs.daily.map(\.unpricedRequestCount))
            #expect(lhs.daily.map(\.estimatedRequestCount) == rhs.daily.map(\.estimatedRequestCount))
            #expect(lhs.daily.map(\.totalTokens) == rhs.daily.map(\.totalTokens))
            #expect(lhs.daily.map { $0.modelBreakdowns?.map(\.totalTokens) }
                == rhs.daily.map { $0.modelBreakdowns?.map(\.totalTokens) })
        }

        // A later sync whose source logs still contain the old day keeps it rolled up, counted once.
        let next = self.publication(at: self.now.addingTimeInterval(60), events: events)
        let again = MidasUsageSyncLedger.retainingLocalHistory(
            previous: limited, fresh: next, maximumBytes: budget)
        #expect(try self.ledger([again], now: self.now.addingTimeInterval(60)).snapshots[.codex]?.last30DaysTokens
            == expected[.codex]?.last30DaysTokens)
        // After those logs roll off, the retained rollups still carry the old days.
        let today = events.filter { $0.day == MidasUsageSyncPublication.day(self.now) }
        let rolledOff = MidasUsageSyncLedger.retainingLocalHistory(
            previous: again,
            fresh: self.publication(at: self.now.addingTimeInterval(120), events: today),
            maximumBytes: budget)
        #expect(try self.ledger([rolledOff], now: self.now.addingTimeInterval(120)).snapshots[.codex]?
            .last30DaysTokens == expected[.codex]?.last30DaysTokens)
    }

    @Test func rollupsFromTwoDevicesAddInsteadOfReplacingEachOther() throws {
        let values = MidasUsageSyncValues(tokens: 500, requests: 5, costUSD: 2, model: "gpt-5.5")
        let firstRollup = MidasUsageSyncRollup.rollUp([self.event("a", values: values)], deviceID: self.first)
        let secondRollup = MidasUsageSyncRollup.rollUp([self.event("b", values: values)], deviceID: self.second)
        #expect(firstRollup.map(\.id) != secondRollup.map(\.id))
        let ledger = try self.ledger([
            self.publication(events: firstRollup),
            self.publication(device: self.second, events: secondRollup),
        ])
        #expect(ledger.snapshots[.codex]?.last30DaysTokens == 1000)
        #expect(ledger.snapshots[.codex]?.last30DaysRequests == 10)
    }

    @Test func rolledDayKeepsItsMostCompleteVersionInsteadOfAddingVersions() {
        let complete = MidasUsageSyncRollup.rollUp(
            [self.event("a"), self.event("b"), self.event("c")], deviceID: self.first)
        let partial = [self.event("a")]
        let previous = self.publication(at: self.now.addingTimeInterval(-60), events: complete)
        let merged = MidasUsageSyncLedger.retainingLocalHistory(
            previous: previous, fresh: self.publication(events: partial))
        #expect(merged.events == complete)
        let grown = [self.event("a"), self.event("b"), self.event("c"), self.event("d")]
        let regrown = MidasUsageSyncLedger.retainingLocalHistory(
            previous: previous, fresh: self.publication(events: grown))
        #expect(regrown.events.count == 1)
        #expect(regrown.events.first?.values.tokens == 400)
        #expect(MidasUsageSyncRollup.isRollup(regrown.events[0], deviceID: self.first))
    }

    @Test func retainedHistoryDoesNotLeakBetweenDevicesOrWorkspaces() {
        let fresh = self.publication(events: [self.event("new")])
        let otherDevice = self.publication(device: self.second, events: [self.event("other")])
        let otherWorkspace = MidasUsageSyncPublication(
            workspaceID: UUID(),
            deviceID: self.first,
            deviceName: "Other workspace",
            publishedAt: self.now,
            events: [self.event("private-other")])
        for previous in [otherDevice, otherWorkspace] {
            let retained = MidasUsageSyncLedger.retainingLocalHistory(previous: previous, fresh: fresh)
            #expect(retained.events == fresh.events)
            #expect(retained.workspaceID == fresh.workspaceID)
        }
    }

    @Test func workspaceHashesAreStableScopedAndDoNotContainPrivateSourceIdentifiers() throws {
        let components = ["secret-account@example.test", "/private/Secret Project", "secret-session-id"]
        let id = self.workspace.opaqueID(provider: .codex, components: components)
        let roundTrip = try JSONDecoder().decode(
            MidasUsageSyncWorkspace.self,
            from: JSONEncoder().encode(self.workspace))
        #expect(roundTrip.opaqueID(provider: .codex, components: components) == id)
        #expect(self.workspace.opaqueID(provider: .claude, components: components) != id)
        let otherSalt = MidasUsageSyncWorkspace(
            id: self.workspace.id,
            identitySalt: String(repeating: "b", count: 64),
            createdAt: self.now)
        #expect(otherSalt.opaqueID(provider: .codex, components: components) != id)
        #expect(self.workspace.opaqueID(provider: .codex, components: ["a:b", "c"])
            != self.workspace.opaqueID(provider: .codex, components: ["a", "b:c"]))
        #expect(id.count == 64)
        let event = MidasUsageSyncEvent(
            id: id,
            provider: .codex,
            day: MidasUsageSyncPublication.day(self.now),
            observedAt: self.now,
            values: .init(tokens: 100, costUSD: 1, model: "gpt-5"))
        let data = try JSONEncoder().encode(self.publication(events: [event]))
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(components.allSatisfy { !json.contains($0) })
        #expect(!json.contains("accountEmail"))
        #expect(!json.contains("conversation"))
    }

    @Test func unsupportedSchemasAndInvalidWorkspaceMetadataAreRejected() {
        let invalid = [
            MidasUsageSyncWorkspace(schemaVersion: 2),
            MidasUsageSyncWorkspace(identitySalt: String(repeating: "a", count: 31)),
            MidasUsageSyncWorkspace(identitySalt: String(repeating: "a", count: 257)),
            MidasUsageSyncWorkspace(createdAt: Date(timeIntervalSince1970: .infinity)),
        ]
        for workspace in invalid {
            #expect(throws: (any Error).self) { try workspace.validate() }
        }
        var publication = self.publication()
        publication.schemaVersion = 2
        #expect(throws: MidasUsageSyncError.unsupportedSchema) { try self.ledger([publication]) }
        #expect(throws: MidasUsageSyncError.wrongWorkspace) {
            try MidasUsageSyncLedger(publications: [self.publication()], workspaceID: UUID(), now: self.now)
        }
    }

    @Test func numericSafetyBoundsRejectCorruptOrUnrepresentableMeasurements() {
        var negativeMix = CostUsageTokenMix()
        negativeMix.inputTokens = -1
        let invalid = [
            MidasUsageSyncValues(tokens: -1, costUSD: 1),
            MidasUsageSyncValues(tokens: Int.max, costUSD: 1),
            MidasUsageSyncValues(tokens: 1_000_000_000_001, costUSD: 1),
            MidasUsageSyncValues(tokens: 1, requests: Int.max, costUSD: 1),
            MidasUsageSyncValues(tokens: 1, costUSD: -.infinity),
            MidasUsageSyncValues(tokens: 1, costUSD: .nan),
            MidasUsageSyncValues(tokens: 1, costUSD: -1),
            MidasUsageSyncValues(tokens: 1, costUSD: Double.greatestFiniteMagnitude),
            MidasUsageSyncValues(tokens: 1, costUSD: 1_000_000_001),
            MidasUsageSyncValues(tokens: 1, costUSD: 1, apiEquivalentCostUSD: .infinity),
            MidasUsageSyncValues(tokens: 1, costUSD: 1, tokenMix: negativeMix),
            MidasUsageSyncValues(tokens: 1, costUSD: 1, unpricedRequests: Int.max),
            MidasUsageSyncValues(tokens: 1, costUSD: 1, estimatedRequests: -1),
        ]
        for values in invalid {
            #expect(throws: MidasUsageSyncError.invalidRecord) { try values.validate() }
            #expect(throws: MidasUsageSyncError.invalidRecord) {
                try self.ledger([self.publication(events: [self.event("invalid", values: values)])])
            }
        }
    }

    @Test func acceptedMaximumMeasurementsCanBeAggregatedWithoutOverflow() throws {
        let maximum = MidasUsageSyncValues(
            tokens: 1_000_000_000_000,
            requests: 1_000_000_000_000,
            costUSD: 1_000_000_000,
            tokenMix: .init(inputTokens: 1_000_000_000_000),
            unpricedRequests: 1_000_000_000_000,
            estimatedRequests: 1_000_000_000_000)
        try maximum.validate()
        let snapshot = try #require(self.ledger([self.publication(events: [
            self.event("max-one", values: maximum),
            self.event("max-two", values: maximum),
        ])]).snapshots[.codex])
        #expect(snapshot.last30DaysTokens == 2_000_000_000_000)
        #expect(snapshot.last30DaysCostUSD == 2_000_000_000)
        #expect(snapshot.daily.first?.coverageCounts.total == 4_000_000_000_000)
    }

    @Test func invalidDatesIdentitiesAndMetadataAreRejected() throws {
        #expect(MidasUsageSyncPublication.isDay("2024-02-29"))
        for day in ["2026-02-29", "2026-04-31", "2026-00-01", "2026-01-00", "2026-1-01", "bad-date!!"] {
            #expect(!MidasUsageSyncPublication.isDay(day))
            let event = MidasUsageSyncEvent(
                id: self.event("id").id,
                provider: .codex,
                day: day,
                observedAt: self.now,
                values: .init(tokens: 1, costUSD: 1))
            #expect(throws: MidasUsageSyncError.invalidRecord) { try self.ledger([self.publication(events: [event])]) }
        }
        let mismatch = MidasUsageSyncEvent(
            id: self.event("id").id,
            provider: .codex,
            day: "2026-10-14",
            observedAt: self.now,
            values: .init(tokens: 1, costUSD: 1))
        #expect(throws: MidasUsageSyncError.invalidRecord) { try self.ledger([self.publication(events: [mismatch])]) }
        for id in ["secret-source-id", String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
            let event = MidasUsageSyncEvent(
                id: id,
                provider: .codex,
                day: MidasUsageSyncPublication.day(self.now),
                observedAt: self.now,
                values: .init(tokens: 1, costUSD: 1))
            #expect(throws: MidasUsageSyncError.invalidRecord) { try self.ledger([self.publication(events: [event])]) }
        }
        for label in ["", "Private\nMac", String(repeating: "a", count: 81)] {
            let publication = MidasUsageSyncPublication(
                workspaceID: self.workspace.id,
                deviceID: self.first,
                deviceName: label,
                publishedAt: self.now)
            #expect(throws: MidasUsageSyncError.invalidRecord) { try self.ledger([publication]) }
        }
        #expect(throws: MidasUsageSyncError.invalidRecord) {
            try self.ledger([self.publication(at: self.now.addingTimeInterval(301))])
        }
        #expect(throws: MidasUsageSyncError.invalidRecord) { try self.ledger([self.publication(excluded: -1)]) }
        for model in ["bad\nmodel", String(repeating: "a", count: 161)] {
            #expect(throws: MidasUsageSyncError.invalidRecord) {
                try MidasUsageSyncValues(tokens: 1, costUSD: 1, model: model).validate()
            }
        }
    }

    @Test func cursorReportDayIsIndependentOfTheLaterFetchTimestamp() throws {
        let row = self.account("account", day: "2026-10-01", values: .init(
            tokens: 40,
            requests: 4,
            costUSD: 2,
            provenance: .vendorMetered))
        let snapshot = try #require(self.ledger([self.publication(accounts: [row])]).snapshots[.cursor])
        #expect(snapshot.daily.map(\.date) == ["2026-10-01"])
        #expect(snapshot.sessionTokens == nil)
        #expect(snapshot.last30DaysTokens == 40)
    }

    @Test func otherDevicePublicationsDoNotMakeAnOfflineProviderAppearFresh() throws {
        let old = self.now.addingTimeInterval(-3600)
        let spark = self.publication(at: old, events: [self.event(
            "spark", provider: .localInference, at: old, values: .init(tokens: 8, costUSD: nil, unpricedRequests: 1))])
        let mac = self.publication(device: self.second, events: [self.event("mac")])
        let stale = try self.ledger([spark, mac])
        #expect(stale.snapshots[.localInference]?.updatedAt == old)
        #expect(stale.snapshots[.codex]?.updatedAt == self.now)
        let refreshedSpark = self.publication(events: spark.events)
        #expect(try self.ledger([refreshedSpark, mac]).snapshots[.localInference]?.updatedAt == self.now)
    }

    @Test func localModelCacheMixMustBeCompleteAcrossEveryRecord() throws {
        let complete = self.event("cache-known", provider: .localInference, values: .init(
            tokens: 100,
            costUSD: nil,
            tokenMix: .init(inputTokens: 80, outputTokens: 20, cacheReadTokens: 40),
            model: DGXSparkPricing.modelID,
            unpricedRequests: 1))
        let incomplete = self.event("cache-unknown", provider: .localInference, values: .init(
            tokens: 100,
            costUSD: nil,
            tokenMix: .init(inputTokens: 80, outputTokens: 20),
            model: DGXSparkPricing.modelID,
            unpricedRequests: 1))
        let raw = try #require(self.ledger([self.publication(events: [complete, incomplete])])
            .snapshots[.localInference])
        #expect(raw.daily.first?.modelBreakdowns?.first?.cacheReadTokens == nil)
        #expect(raw.daily.first?.cacheReadTokens == nil)
        #expect(raw.last30DaysTokens == 200)
        #expect(DGXSparkPricing.project(snapshot: raw, now: self.now).last30DaysCostUSD == nil)
        let knownOnly = try #require(self.ledger([self.publication(events: [complete])])
            .snapshots[.localInference])
        #expect(knownOnly.daily.first?.modelBreakdowns?.first?.cacheReadTokens == 40)
        #expect(DGXSparkPricing.project(snapshot: knownOnly, now: self.now).last30DaysCostUSD != nil)
        let invalidCache = self.event("cache-invalid", provider: .localInference, values: .init(
            tokens: 100,
            costUSD: nil,
            tokenMix: .init(inputTokens: 80, outputTokens: 20, cacheReadTokens: 81),
            model: DGXSparkPricing.modelID,
            unpricedRequests: 1))
        let invalid = try #require(self.ledger([self.publication(events: [complete, invalidCache])])
            .snapshots[.localInference])
        #expect(invalid.daily.first?.modelBreakdowns?.first?.cacheReadTokens == nil)
        #expect(invalid.daily.first?.cacheReadTokens == nil)
        #expect(DGXSparkPricing.project(snapshot: invalid, now: self.now).last30DaysCostUSD == nil)
    }

    @Test func streamingDayAndModelTotalsPreserveUnknownsZeroesAndCoverage() throws {
        let previousDay = self.now.addingTimeInterval(-86400)
        let first = self.event("first-model", at: previousDay, values: .init(
            tokens: 150,
            requests: 2,
            costUSD: 1.25,
            apiEquivalentCostUSD: 2.5,
            tokenMix: .init(
                inputTokens: 100,
                outputTokens: 20,
                cacheReadTokens: 10,
                cacheCreationTokens: 20,
                reasoningTokens: 10),
            model: "gpt-5",
            estimatedRequests: 2))
        let second = self.event("same-model-unknown", at: previousDay, values: .init(
            tokens: 50,
            requests: 1,
            costUSD: nil,
            tokenMix: .init(outputTokens: 50),
            provenance: .unknown,
            model: "gpt-5",
            unpricedRequests: 1))
        let unnamed = self.event("unnamed", at: previousDay, values: .init(
            tokens: 7, costUSD: 0.25, provenance: .vendorMetered))
        let zero = self.event("other-model-zero", values: .init(
            tokens: 0,
            requests: 0,
            costUSD: 0,
            apiEquivalentCostUSD: 0,
            tokenMix: .init(inputTokens: 0, outputTokens: 0),
            model: "gpt-5-mini"))
        let rows = [first, second, unnamed, zero]
        let snapshot = try #require(self.ledger([
            self.publication(events: rows),
            self.publication(device: self.second, events: Array(rows.reversed())),
        ]).snapshots[.codex])
        #expect(snapshot.last30DaysTokens == 207)
        #expect(snapshot.last30DaysRequests == 3)
        #expect(snapshot.last30DaysCostUSD == 1.5)
        #expect(snapshot.last30DaysAPIEquivalentCostUSD == 2.5)
        #expect(snapshot.costProvenance == .mixed)
        #expect(snapshot.sessionTokens == 0)
        #expect(snapshot.sessionCostUSD == 0)
        let day = try #require(snapshot.daily.first)
        #expect(day.inputTokens == 100)
        #expect(day.outputTokens == 70)
        #expect(day.cacheReadTokens == 10)
        #expect(day.cacheCreationTokens == 20)
        #expect(day.reasoningTokens == 10)
        #expect(day.unpricedRequestCount == 1)
        #expect(day.estimatedRequestCount == 2)
        #expect(day.modelsUsed == ["gpt-5"])
        let model = try #require(day.modelBreakdowns?.first)
        #expect(model.totalTokens == 200)
        #expect(model.requestCount == 3)
        #expect(model.costUSD == 1.25)
        #expect(model.inputTokens == 100)
        #expect(model.outputTokens == 70)
        #expect(model.cacheReadTokens == 10)
        #expect(model.cacheCreationTokens == 20)
        #expect(model.reasoningTokens == 10)
        #expect(snapshot.daily.last?.modelBreakdowns?.first?.inputTokens == 0)
    }

    @Test func identicalCopiesAndEqualTimestampCorrectionsKeepCanonicalSelectionDuringRetention() throws {
        let original = self.event("equal-time", values: .init(tokens: 100, costUSD: 1, model: "gpt-5"))
        let correction = self.event("equal-time", values: .init(tokens: 100, costUSD: 2, model: "gpt-5"))
        let originalAccount = self.account("same-account", values: .init(tokens: 20, costUSD: 3))
        let correctedAccount = self.account("same-account", values: .init(tokens: 20, costUSD: 4))
        let one = self.publication(events: [original, original], accounts: [originalAccount, originalAccount])
        let two = self.publication(events: [correction, correction], accounts: [correctedAccount, correctedAccount])
        let forward = MidasUsageSyncLedger.retainingLocalHistory(previous: one, fresh: two)
        let backward = MidasUsageSyncLedger.retainingLocalHistory(previous: two, fresh: one)
        #expect(forward.events == backward.events)
        #expect(forward.accountDays == backward.accountDays)
        #expect(forward.events.count == 1)
        #expect(forward.accountDays.count == 1)
        let ledger = try self.ledger([forward, forward])
        #expect(ledger.snapshots[.codex]?.last30DaysTokens == 100)
        #expect(ledger.snapshots[.cursor]?.last30DaysTokens == 20)
    }

    private func ledger(_ publications: [MidasUsageSyncPublication], now: Date? = nil) throws -> MidasUsageSyncLedger {
        try MidasUsageSyncLedger(publications: publications, workspaceID: self.workspace.id, now: now ?? self.now)
    }

    private func publication(
        device: UUID? = nil,
        at: Date? = nil,
        events: [MidasUsageSyncEvent] = [],
        accounts: [MidasUsageSyncAccountDay] = [],
        excluded: Int = 0) -> MidasUsageSyncPublication
    {
        MidasUsageSyncPublication(
            workspaceID: self.workspace.id,
            deviceID: device ?? self.first,
            deviceName: "Synthetic Mac",
            publishedAt: at ?? self.now,
            events: events,
            accountDays: accounts,
            excludedRecords: excluded)
    }

    private func event(
        _ component: String,
        provider: UsageProvider = .codex,
        at: Date? = nil,
        values: MidasUsageSyncValues = .init(tokens: 100, costUSD: 1)) -> MidasUsageSyncEvent
    {
        let date = at ?? self.now
        return MidasUsageSyncEvent(
            id: self.workspace.opaqueID(provider: provider, components: [component]),
            provider: provider,
            day: MidasUsageSyncPublication.day(date),
            observedAt: date,
            values: values)
    }

    private func account(
        _ component: String,
        day: String? = nil,
        observedAt: Date? = nil,
        values: MidasUsageSyncValues = .init(tokens: 100, requests: 1, costUSD: 1, provenance: .vendorMetered))
        -> MidasUsageSyncAccountDay
    {
        MidasUsageSyncAccountDay(
            accountScope: self.workspace.opaqueID(provider: .cursor, components: [component]),
            provider: .cursor,
            day: day ?? MidasUsageSyncPublication.day(self.now),
            observedAt: observedAt ?? self.now,
            values: values)
    }

    private func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }
}
