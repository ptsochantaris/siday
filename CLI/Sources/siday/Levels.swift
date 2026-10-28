// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayFiles
import SidayPlayer
import Synchronization

/// How loud each song is, for levelling (see `SongLevel`): found by playing the song through,
/// unheard, on a thread of its own, the song being heard first and then the one after it, and kept
/// in a file between runs so that a song is measured only once.
final class Levels: @unchecked Sendable {
    /// A song of a file; with no number, the one the file is started at.
    struct Song: Hashable {
        let url: URL
        let number: Int?
    }

    private struct State {
        /// What is wanted, the first first: what is being heard, and what is to come next.
        var wanted: [Song] = []
        /// What has been found in this run, by file and song number.
        var found: [Song: SongLevel] = [:]
        /// What has been found so far of a song that is being measured: see `SongMeasurement.provisional`.
        var provisional: [Song: SongLevel] = [:]
        /// Songs that could not be measured, so as not to try again.
        var failed: Set<Song> = []
        /// The levels kept from earlier runs and found in this one, by `SongLevel.key`.
        var kept: [String: SongLevel] = [:]
    }

    private let files: TuneFiles
    private let policy: PlaybackPolicy
    private let state = Mutex(State())
    private let wake = DispatchSemaphore(value: 0)
    private let keptFile: URL?

    init(files: TuneFiles, policy: PlaybackPolicy) {
        self.files = files
        self.policy = policy
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("siday")
        keptFile = folder?.appendingPathComponent("levels.txt")
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var kept: [String: SongLevel] = [:]
        if let keptFile, let text = try? String(contentsOf: keptFile, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                if parts.count == 2, let level = SongLevel(text: String(parts[1])) { kept[String(parts[0])] = level }
            }
        }
        state.withLock { $0.kept = kept }
    }

    /// Starts the thread that measures songs as they are asked for.
    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "siday.levels"
        thread.qualityOfService = .utility
        thread.stackSize = 4 << 20
        thread.start()
    }

    /// Says which songs are wanted now, the first first. Any other that was being measured is left.
    func want(_ songs: [Song]) {
        state.withLock { $0.wanted = songs }
        wake.signal()
    }

    /// What was found for a song, if it has been measured.
    func level(of url: URL, song: Int) -> SongLevel? {
        state.withLock { $0.found[Song(url: url, number: song)] }
    }

    /// What has been found so far of a song that is still being measured, or of one that has been.
    func provisionalLevel(of url: URL, song: Int) -> SongLevel? {
        let song = Song(url: url, number: song)
        return state.withLock { $0.found[song] ?? $0.provisional[song] }
    }

    /// Measures a song at once, on the thread that asks, if it has not been already; nil if it
    /// cannot be loaded.
    func measure(_ url: URL, song: Int) -> SongLevel? {
        if let level = level(of: url, song: song) { return level }
        return measure(Song(url: url, number: song), stillWanted: { true })
    }

    private func run() {
        while true {
            // (A file's first song is found under its number and under none.)
            let next = state.withLock { state in
                state.wanted.first { !state.failed.contains($0) && state.found[$0] == nil }
            }
            guard let next else {
                wake.wait()
                continue
            }
            if measure(next, stillWanted: { self.state.withLock { $0.wanted.contains(next) } }) == nil,
               state.withLock({ $0.wanted.contains(next) }) {
                state.withLock { _ = $0.failed.insert(next) }
            }
        }
    }

    /// Loads a song and plays it through to measure it, a little at a time, for as long as it is
    /// still wanted. What is found is kept.
    private func measure(_ song: Song, stillWanted: () -> Bool) -> SongLevel? {
        guard let data = try? Data(contentsOf: song.url), let renderer = try? files.load(song.url) else { return nil }
        let number = song.number ?? policy.firstSubsong(of: renderer)
        let found = Song(url: song.url, number: number)
        if let level = state.withLock({ $0.found[found] }) {
            if song.number == nil { state.withLock { $0.found[song] = level } }
            return level
        }
        if renderer.subsongCount > 1 || number != renderer.currentSubsong { renderer.select(subsong: number) }
        var options = files.options
        // (What is found for a SID tune's length depends on whether there is a database of them.)
        if TuneFormat(url: song.url) == .sid {
            options.songLengths = SongLengthFiles.find(explicitPath: files.songLengthsPath, near: song.url) ?? files.keptSongLengths
        }
        let key = SongLevel.key(of: [UInt8](data), companions: CompanionFiles.read(for: song.url, format: TuneFormat(url: song.url) ?? .mod).companions,
                                song: number, options: options, policy: policy, playedOn: SongLevel.playedOn(renderer, options: options))
        var level = state.withLock { $0.kept[key] }
        if level == nil {
            let measurement = SongMeasurement(renderer: renderer, policy: policy)
            while level == nil {
                guard stillWanted() else { return nil }
                level = measurement.measure(frames: outputSampleRate)
                if level == nil, let provisional = measurement.provisional { state.withLock { $0.provisional[found] = provisional } }
            }
            state.withLock { _ = $0.provisional.removeValue(forKey: found) }
            if let level { keep(level, as: key) }
        }
        state.withLock {
            $0.found[found] = level
            if song.number == nil { $0.found[song] = level }
        }
        return level
    }

    private func keep(_ level: SongLevel, as key: String) {
        state.withLock { $0.kept[key] = level }
        guard let keptFile else { return }
        let line = Data((key + "\t" + level.text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: keptFile) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: keptFile)
        }
    }
}
