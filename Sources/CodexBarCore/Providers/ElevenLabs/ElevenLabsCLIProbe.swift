import Foundation

/// Reads subscription usage through the official ElevenLabs CLI (`@elevenlabs/cli`).
///
/// The CLI keeps its OAuth session in its own Keychain entry (`elevenlabs:OAuth`, written by
/// `elevenlabs auth login`). Midas never reads that entry: it runs the CLI, which reads its own
/// item, so no Keychain prompt appears and no credential passes through Midas.
public struct ElevenLabsCLIProbe: Sendable {
    static let commandTimeout: TimeInterval = 60
    static let arguments = ["user", "subscription", "get", "--format", "json"]

    /// Serializes runs across Midas, its bundled CLI, and other tools that take the same lock.
    let runLock: ProviderCLIRunLock

    public init(runLock: ProviderCLIRunLock = .elevenLabs) {
        self.runLock = runLock
    }

    public func fetch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) async throws -> ElevenLabsUsageSnapshot
    {
        let loginPATH = LoginShellPathCache.shared.current
        guard let executable = BinaryLocator.resolveElevenLabsBinary(env: environment, loginPATH: loginPATH) else {
            throw ElevenLabsUsageError.cliNotInstalled
        }

        let commandArguments = Self.arguments
        let runEnvironment = Self.commandEnvironment(base: environment, loginPATH: loginPATH)
        let result: SubprocessResult
        do {
            result = try await self.runLock.run {
                try await SubprocessRunner.run(
                    binary: executable,
                    arguments: commandArguments,
                    environment: runEnvironment,
                    timeout: Self.commandTimeout,
                    standardInput: FileHandle.nullDevice,
                    acceptedNonZeroExitCodes: Set(1...255),
                    label: "elevenlabs-subscription")
            }
        } catch let error as SubprocessRunnerError {
            throw ElevenLabsUsageError.cliFailed(error.localizedDescription)
        } catch let error as ProviderCLIRunLockError {
            throw ElevenLabsUsageError.cliFailed(error.localizedDescription)
        }

        return try Self.parse(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            updatedAt: now)
    }

    /// The CLI is a Node script (`#!/usr/bin/env node`), so it needs the login-shell PATH to find
    /// `node`. API keys Midas injects for the API source are removed so the CLI uses its own session.
    static func commandEnvironment(base: [String: String], loginPATH: [String]?) -> [String: String] {
        var environment = base
        for key in ElevenLabsSettingsReader.apiKeyEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        environment["NO_COLOR"] = "1"
        environment["PATH"] = PathBuilder.effectivePATH(
            purposes: [.nodeTooling],
            env: base,
            loginPATH: loginPATH)
        return environment
    }

    static func parse(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        updatedAt: Date) throws -> ElevenLabsUsageSnapshot
    {
        for output in [stdout, stderr] {
            if let failure = failure(in: output) {
                throw failure
            }
        }

        if exitCode == 0, let body = jsonObjectText(in: stdout) {
            return try ElevenLabsUsageFetcher.parseSnapshot(data: Data(body.utf8), updatedAt: updatedAt)
        }

        let message = Self.firstLine(of: stderr) ?? Self.firstLine(of: stdout)
        if let message, Self.looksSignedOut(message) {
            throw ElevenLabsUsageError.cliSignedOut
        }
        if exitCode == 0 {
            throw ElevenLabsUsageError.parseFailed("The ElevenLabs CLI returned no subscription data.")
        }
        throw ElevenLabsUsageError.cliFailed(message ?? "exit code \(exitCode)")
    }

    /// `{"error":{"code":401,"message":"…","reason":"authError"}}`
    private static func failure(in output: String) -> ElevenLabsUsageError? {
        guard let text = self.jsonObjectText(in: output),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let error = object["error"]
        else { return nil }

        guard let details = error as? [String: Any] else {
            let message = (error as? String) ?? "Unknown error"
            return self.looksSignedOut(message) ? .cliSignedOut : .cliFailed(message)
        }
        let code = (details["code"] as? Int) ?? Int((details["code"] as? String) ?? "")
        let reason = (details["reason"] as? String) ?? ""
        let message = (details["message"] as? String) ?? (details["detail"] as? String) ?? reason
        if code == 401 || code == 403 || reason.lowercased().hasPrefix("auth") || self.looksSignedOut(message) {
            return .cliSignedOut
        }
        return .cliFailed(message.isEmpty ? "HTTP \(code.map(String.init) ?? "error")" : message)
    }

    private static func looksSignedOut(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("auth login") || lowered.contains("not logged in") ||
            lowered.contains("credentials are missing") || lowered.contains("unauthorized")
    }

    /// The CLI can print notices around its JSON; take the outermost object.
    private static func jsonObjectText(in output: String) -> String? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(output[start...end])
    }

    private static func firstLine(of output: String) -> String? {
        let line = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return line.count > 240 ? String(line.prefix(240)) + "…" : line
    }
}
