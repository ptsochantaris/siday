// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayFiles
import SidayPlayer
import Synchronization

// SidayKit works on bytes and reads no files. This is the part of loading that needs a file system:
// reading a tune from disk, and finding HVSC's song-length database for it.

/// Loads tunes from files.
struct TuneFiles: Sendable {
    var options = LoadOptions()
    /// A song-length database named by the user, tried before the one beside the tune.
    var songLengthsPath: String?
    /// The one siday keeps (see `KeptFiles`), tried after both.
    var keptSongLengths: SongLengthDatabase?
    /// How long files' songs were found to be by playing them through, kept between runs.
    var lengths: SongLengthsKept? = .standard

    func load(_ url: URL) throws -> any Renderer {
        guard let format = TuneFormat(url: url) else {
            throw TuneError.unsupported("unknown file type .\(url.pathExtension)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TuneError.unreadable(error.localizedDescription)
        }
        var options = options
        if format == .sid {
            options.songLengths = SongLengthFiles.find(explicitPath: songLengthsPath, near: url) ?? keptSongLengths
        }
        let bytes = [UInt8](data), companions = CompanionFiles.read(for: url, format: format).companions
        let key = lengths.map { _ in SongKeeper.lengthsKey(of: bytes, companions: companions) }
        if let lengths, let key { options.songMeasures = lengths.measures(under: key) }
        let renderer = try TuneLoader.load(bytes, format: format, path: url.standardizedFileURL.path, options: options,
                                           companions: companions)
        if let lengths, let key, let found = renderer.songMeasures, found != options.songMeasures { lengths.keep(found, under: key) }
        return renderer
    }
}

/// Where siday keeps what it can find again but would rather not: `$SIDAY_CACHE`, for one run, or its folder
/// in the user's caches.
func cacheFolder() -> URL? {
    let folder = ProcessInfo.processInfo.environment["SIDAY_CACHE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("siday")
    if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    return folder
}

/// How long files' songs were found to be by playing them through (`SongMeasures`), by `SongKeeper.lengthsKey`:
/// kept in a file in `cacheFolder`, a line for each, so that a file's songs are played through once.
final class SongLengthsKept: Sendable {
    static let standard: SongLengthsKept? = cacheFolder().map { SongLengthsKept(file: $0.appendingPathComponent("lengths.txt")) }

    private let file: URL
    private let kept: Mutex<[String: SongMeasures]>

    init(file: URL) {
        self.file = file
        var kept: [String: SongMeasures] = [:]
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                guard parts.count == 2, let bytes = Self.bytes(of: parts[1]), let measures = SongMeasures(bytes: bytes) else { continue }
                kept[String(parts[0])] = measures
            }
        }
        self.kept = Mutex(kept)
    }

    func measures(under key: String) -> SongMeasures? {
        kept.withLock { $0[key] }
    }

    func keep(_ measures: SongMeasures, under key: String) {
        kept.withLock { $0[key] = measures }
        let line = Data((key + "\t" + measures.bytes.map { String(format: "%02x", $0) }.joined() + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: file)
        }
    }

    private static func bytes(of hex: Substring) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
