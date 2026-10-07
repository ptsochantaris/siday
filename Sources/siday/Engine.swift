// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayKit
import Foundation
import Synchronization

enum Command {
    case next, previous, nextSubsong, previousSubsong, quit
}

struct NowPlaying {
    /// Incremented whenever a new tune or subsong starts.
    var generation = 0
    var header = ""
    var length = 0.0
    var index = 0
    /// Lines to print above the status line (skipped files and the like).
    var messages: [String] = []
    var finished = false
}

/// Owns the current tune on its own thread and keeps the audio ring full.
final class Engine: @unchecked Sendable {
    private let ring: SampleRing
    private let playlist: [URL]
    private let files: TuneFiles
    private let policy: PlaybackPolicy
    private let commands = Mutex<[Command]>([])
    /// The television the sound is played through, if any.
    private let television: TelevisionSet?
    let nowPlaying = Mutex(NowPlaying())

    init(ring: SampleRing, playlist: [URL], files: TuneFiles, policy: PlaybackPolicy, television: TelevisionSet?) {
        self.ring = ring
        self.playlist = playlist
        self.files = files
        self.policy = policy
        self.television = television
    }

    func send(_ command: Command) {
        commands.withLock { $0.append(command) }
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "siday.engine"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 4 << 20
        thread.start()
    }

    private func post(_ message: String) {
        nowPlaying.withLock { $0.messages.append(message) }
    }

    /// Throws away buffered audio and waits for the audio thread to acknowledge.
    private func flushRing() {
        ring.flush()
        var waited = 0
        while ring.isFlushing, waited < 300 {
            usleep(1000)
            waited += 1
        }
    }

    private func drainRing() {
        var waited = 0
        while ring.bufferedFrames > 0, waited < 1000 {
            usleep(1000)
            waited += 1
        }
        flushRing()
    }

    private func announce(_ session: TuneSession, index: Int, url: URL) {
        let renderer = session.renderer
        var header = "[\(index + 1)/\(playlist.count)] \(renderer.info.format)"
        let text = describe(renderer.info)
        header += "  " + (text.isEmpty ? url.lastPathComponent : "\(text)  (\(url.lastPathComponent))")
        if renderer.subsongCount > 1 {
            header += "  song \(renderer.currentSubsong + 1)/\(renderer.subsongCount)"
        }
        if !renderer.info.detail.isEmpty { header += "  · \(renderer.info.detail)" }
        nowPlaying.withLock {
            $0.generation += 1
            $0.header = header
            $0.length = session.displayLength
            $0.index = index
        }
    }

    private func run() {
        let block = 512
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
        defer { buffer.deallocate() }
        var index = 0
        var direction = 1
        var television = television.map { Television($0) }

        outer: while index >= 0, index < playlist.count {
            let url = playlist[index]
            let renderer: any Renderer
            do {
                renderer = try files.load(url)
            } catch {
                post("skipped \(url.lastPathComponent): \(error)")
                if index + direction < 0 { direction = 1 }
                index += direction
                continue
            }
            direction = 1
            var subsong = policy.firstSubsong(of: renderer)

            subsongs: while true {
                if renderer.subsongCount > 1 || subsong != renderer.currentSubsong {
                    renderer.select(subsong: subsong)
                }
                let session = TuneSession(renderer: renderer, policy: policy)
                flushRing()
                announce(session, index: index, url: url)

                while !session.finished {
                    for command in commands.withLock({ let c = $0; $0.removeAll(); return c }) {
                        switch command {
                        case .quit:
                            flushRing()
                            break outer
                        case .next:
                            index += 1
                            continue outer
                        case .previous:
                            direction = -1
                            index = max(0, index - 1)
                            continue outer
                        case .nextSubsong:
                            if subsong + 1 < renderer.subsongCount {
                                subsong += 1
                                continue subsongs
                            }
                        case .previousSubsong:
                            if subsong > 0 {
                                subsong -= 1
                                continue subsongs
                            }
                        }
                    }
                    if ring.writableFrames < block {
                        usleep(4000)
                        continue
                    }
                    let produced = session.render(into: buffer, frames: block)
                    television?.process(buffer, frames: produced)
                    if produced > 0 { ring.write(buffer, frames: produced) }
                }
                if session.end == .neverSounded {
                    post("silent: \(url.lastPathComponent)")
                }
                drainRing()
                if policy.allSubsongs, subsong + 1 < renderer.subsongCount {
                    subsong += 1
                    continue
                }
                break
            }
            index += 1
        }
        drainRing()
        nowPlaying.withLock { $0.finished = true }
    }
}
