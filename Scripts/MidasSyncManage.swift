import Foundation

// The app invokes this signed helper with a fixed action; no shell is involved.
let allowed: Set<String> = ["doctor", "check", "restart", "upgrade", "pairing-list", "pairing-approve", "pairing-deny"]
let arguments = Array(CommandLine.arguments.dropFirst())
guard let action = arguments.first, allowed.contains(action) else {
    FileHandle.standardError.write(Data("Midas sync management requires a supported action.\n".utf8))
    exit(2)
}

let ownURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let resources = ownURL.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/MidasSync", isDirectory: true)
let runtime = resources.appendingPathComponent("runtime", isDirectory: true)
let interpreter = runtime.appendingPathComponent("bin/python3").resolvingSymlinksInPath()
let script = resources.appendingPathComponent("midas_sync_manage.py")
guard interpreter.path.hasPrefix(runtime.resolvingSymlinksInPath().path + "/"),
      FileManager.default.isExecutableFile(atPath: interpreter.path),
      FileManager.default.fileExists(atPath: script.path)
else {
    print("{\"schemaVersion\":1,\"status\":\"needs_attention\",\"code\":\"bundled_runtime_unavailable\"}")
    exit(2)
}

let process = Process()
process.executableURL = interpreter
process.arguments = ["-I", "-B", script.path] + arguments
var environment = ProcessInfo.processInfo.environment
environment.removeValue(forKey: "PYTHONPATH")
environment.removeValue(forKey: "PYTHONHOME")
environment.removeValue(forKey: "PYTHONSTARTUP")
environment["PYTHONDONTWRITEBYTECODE"] = "1"
process.environment = environment
process.standardInput = FileHandle.nullDevice
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError
do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    print("{\"schemaVersion\":1,\"status\":\"needs_attention\",\"code\":\"helper_launch_failed\"}")
    exit(2)
}
