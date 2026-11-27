import Foundation

extension AntigravityStatusProbe {
    /// Current desktop builds publish their connection information in a per-user registration.
    /// Send its session header only to a listening port owned by the registered desktop server.
    func registeredDesktopSnapshot(expectedEmail: String?) async throws -> AntigravityStatusSnapshot? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/daemon", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("hub_") && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let hub = try? JSONDecoder().decode(DesktopHub.self, from: data),
                  hub.pid > 0, (1...65535).contains(hub.httpsPort), !hub.csrfToken.isEmpty,
                  let process = try? await SubprocessRunner.run(
                      binary: "/bin/ps",
                      arguments: ["-p", String(hub.pid), "-o", "comm="],
                      environment: ProcessInfo.processInfo.environment,
                      timeout: self.timeout,
                      label: "antigravity-hub"),
                  Self.isRegisteredDesktopLanguageServer(
                      process.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let ports = try? await Self.listeningPorts(pid: hub.pid, timeout: self.timeout),
                  ports.contains(hub.httpsPort)
            else { continue }
            let endpoint = AntigravityConnectionEndpoint(
                scheme: "https", port: hub.httpsPort, csrfToken: hub.csrfToken, source: .languageServer)
            guard let snapshot = try? await Self.fetchSnapshot(
                context: RequestContext(endpoints: [endpoint], timeout: self.timeout),
                includeGeminiSummary: true),
                (try? GeminiAccountMatcher.validate(
                    reportedEmail: snapshot.accountEmail,
                    expectedEmail: expectedEmail)) != nil
            else { continue }
            return snapshot
        }
        try Task.checkCancellation()
        return nil
    }

    static func isRegisteredDesktopLanguageServer(_ commandPath: String) -> Bool {
        let lower = commandPath.lowercased()
        let isAntigravityApp = lower.contains("/antigravity") && lower.contains(".app/contents/resources/")
        let binaryName = URL(fileURLWithPath: commandPath).lastPathComponent.lowercased()
        return isAntigravityApp && binaryName.hasPrefix("language_server")
    }

    private struct DesktopHub: Decodable {
        let pid: Int
        let httpsPort: Int
        let csrfToken: String
    }
}
