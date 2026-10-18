import Darwin
import Foundation
import Testing
@testable import CodexBarCore

struct MidasUsageHubClientTests {
    private let now = Date(timeIntervalSince1970: 1_789_171_200)

    @Test func endpointRequiresPrivateHTTPSOrLoopback() throws {
        for endpoint in [
            "https://mini.tail123.ts.net", "http://127.0.0.1:8766", "http://localhost:123", "http://[::1]:8766",
        ] {
            try self.connection(endpoint: endpoint).validate()
        }
        for endpoint in [
            "http://mini.tail123.ts.net", "https://example.com", "https://ts.net", "https://a.ts.net.evil.test",
            "http://192.168.1.2:8766", "https://token@a.ts.net", "https://a.ts.net/?credential=x",
            "https://a.ts.net/#token", "https://a.ts.net/other",
            "https://a.ts.net:0", "https://a.ts.net:65536",
        ] {
            #expect(throws: MidasUsageHubError.invalidConnection) { try self.connection(endpoint: endpoint).validate() }
        }
    }

    @Test func credentialAndDeviceNameRejectHeaderInjection() {
        let base = self.connection()
        let invalid = MidasUsageHubConnection(
            endpoint: base.endpoint,
            deviceID: base.deviceID,
            deviceName: base.deviceName,
            credential: "Bearer \r\n" + String(repeating: "a", count: 40))
        #expect(throws: MidasUsageHubError.invalidConnection) { try invalid.validate() }
        let invalidName = MidasUsageHubConnection(
            endpoint: base.endpoint,
            deviceID: base.deviceID,
            deviceName: "Mac\nmini",
            credential: base.credential)
        #expect(throws: MidasUsageHubError.invalidConnection) { try invalidName.validate() }
    }

    @Test func connectionFileRoundTripsPrivatelyAndNeverOverwrites() throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("connection.json")
        let connection = self.connection()
        try MidasUsageHubConnectionFile.save(connection, to: file)
        #expect(try MidasUsageHubConnectionFile.load(at: file) == connection)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(throws: MidasUsageHubError.unsafeConnectionFile) {
            try MidasUsageHubConnectionFile.save(connection, to: file)
        }
        #expect(try MidasUsageHubConnectionFile.load(at: file) == connection)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: MidasUsageHubError.unsafeConnectionFile) { try MidasUsageHubConnectionFile.load(at: file) }
    }

    @Test func connectionFileRejectsFinalAndParentSymlinks() throws {
        let folder = try self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = folder.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = real.appendingPathComponent("connection.json")
        try MidasUsageHubConnectionFile.save(self.connection(), to: file)
        let linkedFile = real.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: file)
        #expect(throws: MidasUsageHubError.unsafeConnectionFile) {
            try MidasUsageHubConnectionFile.load(at: linkedFile)
        }
        let linkedFolder = folder.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: real)
        #expect(throws: MidasUsageHubError.unsafeConnectionFile) {
            try MidasUsageHubConnectionFile.load(at: linkedFolder.appendingPathComponent("connection.json"))
        }
    }

    @Test func exchangeValidatesAllPeersAndAcknowledgement() throws {
        let connection = self.connection()
        let workspace = MidasUsageSyncWorkspace(createdAt: self.now)
        let local = self.publication(workspace: workspace, connection: connection)
        let response = MidasUsageHubExchange(
            workspace: workspace,
            publications: [local],
            publicationSucceeded: true,
            unavailableFiles: 0,
            rejectedFiles: 0)
        let validated = try MidasUsageHubClient.validatedExchange(
            JSONEncoder().encode(response), connection: connection, workspace: workspace, local: local, now: self.now)
        #expect(validated == response)
        let missing = MidasUsageHubExchange(
            workspace: workspace,
            publications: [],
            publicationSucceeded: true,
            unavailableFiles: 0,
            rejectedFiles: 0)
        #expect(throws: MidasUsageHubError.invalidResponse) {
            try MidasUsageHubClient.validatedExchange(
                JSONEncoder().encode(missing),
                connection: connection,
                workspace: workspace,
                local: local,
                now: self.now)
        }
        let duplicates = MidasUsageHubExchange(
            workspace: workspace,
            publications: [local, local],
            publicationSucceeded: true,
            unavailableFiles: 0,
            rejectedFiles: 0)
        #expect(throws: MidasUsageHubError.invalidResponse) {
            try MidasUsageHubClient.validatedExchange(
                JSONEncoder().encode(duplicates),
                connection: connection,
                workspace: workspace,
                local: local,
                now: self.now)
        }
    }

    @Test func exchangeRejectsChangedWorkspaceAndFuturePeer() throws {
        let connection = self.connection()
        let workspace = MidasUsageSyncWorkspace(createdAt: self.now)
        let changed = MidasUsageSyncWorkspace(id: workspace.id, createdAt: self.now)
        let wrong = MidasUsageHubExchange(
            workspace: changed, publications: [], publicationSucceeded: false, unavailableFiles: 0, rejectedFiles: 0)
        #expect(throws: MidasUsageSyncError.wrongWorkspace) {
            try MidasUsageHubClient.validatedExchange(
                JSONEncoder().encode(wrong), connection: connection, workspace: workspace, local: nil, now: self.now)
        }
        let future = MidasUsageSyncPublication(
            workspaceID: workspace.id,
            deviceID: UUID(),
            deviceName: "Peer",
            publishedAt: self.now.addingTimeInterval(301))
        let response = MidasUsageHubExchange(
            workspace: workspace,
            publications: [future],
            publicationSucceeded: false,
            unavailableFiles: 0,
            rejectedFiles: 0)
        #expect(throws: MidasUsageSyncError.invalidRecord) {
            try MidasUsageHubClient.validatedExchange(
                JSONEncoder().encode(response), connection: connection, workspace: workspace, local: nil, now: self.now)
        }
    }

    @Test func localOwnerMismatchFailsBeforeNetworkIO() async {
        let connection = self.connection()
        let workspace = MidasUsageSyncWorkspace(createdAt: self.now)
        let wrong = MidasUsageSyncPublication(
            workspaceID: workspace.id, deviceID: UUID(), deviceName: "Peer", publishedAt: self.now)
        await #expect(throws: MidasUsageHubError.invalidConnection) {
            try await MidasUsageHubClient.exchange(
                connection: connection, workspace: workspace, local: wrong, now: self.now)
        }
    }

    @Test func compactPeerWireJSONStillEnforcesTheCanonicalPublicationByteLimit() throws {
        let connection = self.connection()
        let workspace = MidasUsageSyncWorkspace(createdAt: self.now)
        let empty = self.publication(workspace: workspace, connection: connection)
        let row = MidasUsageSyncEvent(
            id: String(repeating: "0", count: 64),
            provider: .codex,
            day: MidasUsageSyncPublication.day(self.now),
            observedAt: self.now,
            values: .init(tokens: nil, costUSD: nil, provenance: .unknown, model: String(repeating: "/", count: 160)))
        let canonicalRow = try JSONEncoder().encode(row)
        let canonicalText = try #require(String(bytes: canonicalRow, encoding: .utf8))
        let compactRow = Data(canonicalText.replacingOccurrences(of: #"\/"#, with: "/").utf8)
        #expect(compactRow.count < canonicalRow.count)
        let count = MidasUsageSyncPublication.maximumFileBytes / (canonicalRow.count + 1) + 1
        #expect(count <= MidasUsageSyncPublication.maximumRecords)

        let response = MidasUsageHubExchange(
            workspace: workspace,
            publications: [empty],
            publicationSucceeded: false,
            unavailableFiles: 0,
            rejectedFiles: 0)
        let header = try #require(String(bytes: JSONEncoder().encode(response), encoding: .utf8))
        let insertion = try #require(header.range(of: #""events":[]"#))
        var wire = Data(header[..<insertion.lowerBound].utf8)
        wire.reserveCapacity(header.utf8.count + count * (compactRow.count + 1))
        wire.append(contentsOf: #""events":["#.utf8)
        for index in 0..<count {
            if index > 0 { wire.append(44) }
            wire.append(compactRow)
        }
        wire.append(93)
        wire.append(contentsOf: header[insertion.upperBound...].utf8)
        // Even the full envelope is below the per-publication wire limit. The
        // rejection must come from canonical peer sizing, not the input codec.
        #expect(wire.count < MidasUsageSyncPublication.maximumFileBytes)
        #expect(throws: MidasUsageHubError.responseTooLarge) {
            try MidasUsageHubClient.validatedExchange(
                wire,
                connection: connection,
                workspace: workspace,
                local: nil,
                now: self.now)
        }
    }

    private func connection(endpoint: String = "https://mini.tail123.ts.net") -> MidasUsageHubConnection {
        MidasUsageHubConnection(
            endpoint: URL(string: endpoint)!,
            deviceID: UUID(),
            deviceName: "Mac mini",
            credential: String(repeating: "a", count: 43))
    }

    private func publication(
        workspace: MidasUsageSyncWorkspace, connection: MidasUsageHubConnection) -> MidasUsageSyncPublication
    {
        MidasUsageSyncPublication(
            workspaceID: workspace.id,
            deviceID: connection.deviceID,
            deviceName: connection.deviceName,
            publishedAt: self.now)
    }

    private func folder() throws -> URL {
        // Foundation abbreviates /private/var to the /var symlink, which strict no-follow IO must reject.
        guard let path = Darwin.realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw POSIXError(.ENOENT)
        }
        defer { Darwin.free(path) }
        let folder = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("midas-hub-client-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }
}
