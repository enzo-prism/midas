import CZstdDecoder
import Foundation

/// Codex compresses older rollouts in place (`X.jsonl` becomes `X.jsonl.zst`). macOS has no zstd
/// decoder, so the bundled reference decoder turns an archive back into a private temporary file
/// for the existing parsers. The plain copy is deleted as soon as the read finishes; no decompressed
/// mirror of the transcripts is kept.
enum CodexRolloutArchive {
    static let archiveSuffix = ".jsonl.zst"

    enum ArchiveError: Error, Equatable {
        case cannotOpen
        case corrupt
        case cannotWrite
    }

    static func isArchive(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(self.archiveSuffix)
    }

    /// A plain or compressed Codex rollout.
    static func isRollout(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "jsonl" || self.isArchive(url)
    }

    /// The plain file an archive replaces.
    static func plainSibling(of archive: URL) -> URL {
        archive.deletingPathExtension()
    }

    /// Drops an archive whose plain file is also listed or still on disk, so a rollout is counted once.
    static func preferringPlainFiles(_ files: [URL]) -> [URL] {
        let plainPaths = Set(files.filter { !self.isArchive($0) }.map(\.path))
        return files.filter { file in
            guard self.isArchive(file) else { return true }
            let plain = self.plainSibling(of: file).path
            return !plainPaths.contains(plain) && !FileManager.default.fileExists(atPath: plain)
        }
    }

    /// Runs `body` with a readable plain file: the file itself, or a temporary decompressed copy of an
    /// archive that is removed afterwards. `maxOutputBytes` bounds the copy when only a prefix is needed.
    static func withPlainFile<Result>(
        _ url: URL,
        maxOutputBytes: Int64? = nil,
        checkCancellation: (() throws -> Void)? = nil,
        _ body: (URL) throws -> Result) throws -> Result
    {
        guard self.isArchive(url) else { return try body(url) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("midas-codex-rollouts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let plain = directory.appendingPathComponent(UUID().uuidString + ".jsonl", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: plain) }
        try self.decompress(
            archive: url,
            to: plain,
            maxOutputBytes: maxOutputBytes,
            checkCancellation: checkCancellation)
        return try body(plain)
    }

    /// Stream-decompresses `archive` into `destination` (created private to the user).
    static func decompress(
        archive: URL,
        to destination: URL,
        maxOutputBytes: Int64? = nil,
        checkCancellation: (() throws -> Void)? = nil) throws
    {
        guard let input = try? FileHandle(forReadingFrom: archive) else { throw ArchiveError.cannotOpen }
        defer { try? input.close() }
        guard FileManager.default.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]),
            let output = try? FileHandle(forWritingTo: destination)
        else { throw ArchiveError.cannotWrite }
        defer { try? output.close() }

        guard let stream = ZSTD_createDStream() else { throw ArchiveError.corrupt }
        defer { ZSTD_freeDStream(stream) }

        let inputCapacity = ZSTD_DStreamInSize()
        let outputCapacity = ZSTD_DStreamOutSize()
        let outputBuffer = UnsafeMutableRawPointer.allocate(byteCount: outputCapacity, alignment: 16)
        defer { outputBuffer.deallocate() }

        var written: Int64 = 0
        var lastResult = 0
        var sawInput = false
        while true {
            try checkCancellation?()
            guard let chunk = try? input.read(upToCount: inputCapacity), !chunk.isEmpty else { break }
            sawInput = true
            var reachedLimit = false
            try chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var inBuffer = ZSTD_inBuffer(src: bytes.baseAddress, size: bytes.count, pos: 0)
                while inBuffer.pos < inBuffer.size {
                    var outBuffer = ZSTD_outBuffer(dst: outputBuffer, size: outputCapacity, pos: 0)
                    lastResult = ZSTD_decompressStream(stream, &outBuffer, &inBuffer)
                    if ZSTD_isError(lastResult) != 0 { throw ArchiveError.corrupt }
                    guard outBuffer.pos > 0 else { continue }
                    var count = outBuffer.pos
                    if let maxOutputBytes {
                        count = min(count, Int(max(0, maxOutputBytes - written)))
                    }
                    do {
                        try output.write(contentsOf: Data(bytes: outputBuffer, count: count))
                    } catch {
                        throw ArchiveError.cannotWrite
                    }
                    written += Int64(count)
                    if let maxOutputBytes, written >= maxOutputBytes {
                        reachedLimit = true
                        return
                    }
                }
            }
            if reachedLimit { return }
        }
        // A frame that stopped mid-way means the archive was truncated.
        guard sawInput, lastResult == 0 else { throw ArchiveError.corrupt }
    }
}
