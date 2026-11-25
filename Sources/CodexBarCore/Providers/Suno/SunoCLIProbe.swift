import Foundation

/// Reads credit and download usage through the `suno` CLI (`suno credits`).
///
/// Midas never touches the CLI's session file. It runs one read-only command with `--no-browser`,
/// so the CLI cannot open Chrome or read browser cookies (no Keychain prompt), and `--quiet` keeps
/// update notices out of the JSON.
public struct SunoCLIProbe: Sendable {
    static let commandTimeout: TimeInterval = 30
    static let arguments = ["credits", "--json", "--no-browser", "--quiet"]

    public init() {}

    public func fetch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) async throws -> SunoUsageSnapshot
    {
        let loginPATH = LoginShellPathCache.shared.current
        guard let executable = BinaryLocator.resolveSunoBinary(env: environment, loginPATH: loginPATH) else {
            throw SunoUsageError.cliNotInstalled
        }

        var commandEnvironment = environment
        commandEnvironment["NO_COLOR"] = "1"
        commandEnvironment["PATH"] = PathBuilder.effectivePATH(
            purposes: [.tty],
            env: environment,
            loginPATH: loginPATH)

        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(
                binary: executable,
                arguments: Self.arguments,
                environment: commandEnvironment,
                timeout: Self.commandTimeout,
                standardInput: FileHandle.nullDevice,
                acceptedNonZeroExitCodes: Set(1...255),
                label: "suno-credits")
        } catch let error as SubprocessRunnerError {
            throw SunoUsageError.cliFailed(error.localizedDescription)
        }

        return try SunoCreditsParser.parse(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            updatedAt: now)
    }
}
