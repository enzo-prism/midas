import CodexBarCore
import Commander
import Foundation

struct UsageSyncCollectorOptions: CommanderParsable {
    @Option(name: .long("config"), help: "Owner-only device connection JSON file")
    var config: String?

    @Option(name: .long("state-root"), help: "Private internal persistent state directory")
    var stateRoot: String?

    @Option(name: .long("interval"), help: "Seconds between collection cycles, 30...86400 (default 180)")
    var interval: Int?

    @Flag(name: .long("once"), help: "Collect once and exit")
    var once = false

    @Option(name: .long("providers"), help: "Supported numeric log providers: codex,claude,meta")
    var providers: String?

    @Option(name: .long("codex-root"), help: "Override Codex sessions directory")
    var codexRoot: String?

    @Option(name: .long("codex-additional-root"), help: "Additional Codex sessions directory (repeatable)")
    var codexAdditionalRoot: String?

    @Option(name: .long("claude-root"), help: "Override Claude projects directory (repeatable)")
    var claudeRoot: String?

    @Option(name: .long("meta-root"), help: "Override Meta sessions directory")
    var metaRoot: String?

    @Option(name: .long("trace-database"), help: "Override Codex priority trace database")
    var traceDatabase: String?

    @Flag(name: .long("refresh"), help: "Rescan numeric sources instead of reusing the scan cache")
    var refresh = false
}

extension CodexBarCLI {
    static func runUsageSyncCollect(_ values: ParsedValues) async {
        guard let path = values.options["config"]?.last,
              let interval = Int(values.options["interval"]?.last ?? "180"),
              (30...86400).contains(interval)
        else {
            writeStderr("Midas collector requires --config and an interval between 30 and 86400 seconds.\n")
            platformExit(1)
        }
        do {
            let configurationURL = URL(fileURLWithPath: path)
            let providers = try MidasUsageCollector.parseProviders(values.options["providers"]?.last)
            let stateRoot = values.options["stateRoot"]?.last.map { URL(fileURLWithPath: $0) }
                ?? MidasUsageCollector.defaultStateRoot()
            let options = MidasUsageCollector.Options(
                stateRoot: stateRoot,
                providers: providers,
                export: MidasUsageSyncExporter.Options(
                    codexSessionsRoot: values.options["codexRoot"]?.last.map { URL(fileURLWithPath: $0) },
                    codexAdditionalSessionsRoots: (values.options["codexAdditionalRoot"] ?? [])
                        .map { URL(fileURLWithPath: $0) },
                    claudeProjectsRoots: values.options["claudeRoot"]?.map { URL(fileURLWithPath: $0) },
                    metaSessionsRoot: values.options["metaRoot"]?.last.map { URL(fileURLWithPath: $0) },
                    cacheRoot: stateRoot.appendingPathComponent("scan-cache", isDirectory: true),
                    codexTraceDatabaseURL: values.options["traceDatabase"]?.last.map { URL(fileURLWithPath: $0) },
                    forceRescan: values.flags.contains("refresh")))
            let collector = MidasUsageCollector(options: options)
            repeat {
                do {
                    // Reload every cycle so revoking/replacing a device credential does not require a restart.
                    let connection = try MidasUsageHubConnectionFile.load(at: configurationURL)
                    let status = try await collector.collect(connection: connection)
                    Self.printJSON(status, pretty: false)
                    if values.flags.contains("once") {
                        Self.platformExit(status.publicationSucceeded ? 0 : 2)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Never render raw URLs, headers, configuration contents, provider paths, or credentials.
                    Self.writeStderr("Midas collector could not complete a cycle; retained state is unchanged.\n")
                    if values.flags.contains("once") { Self.platformExit(1) }
                }
                try await Task.sleep(for: .seconds(interval))
            } while !Task.isCancelled
        } catch {
            Self.writeStderr("Midas collector configuration is invalid; see usage-sync --help.\n")
            Self.platformExit(1)
        }
    }
}
