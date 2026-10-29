// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayPlayer
import Foundation
import Synchronization

enum Command {
    case next, previous, nextSubsong, previousSubsong, quit
    /// Leave a voice out, by its number from 0, or bring it back.
    case mute(Int)
    /// Hear a voice alone, or, if it is already heard alone, bring the others back.
    case solo(Int)
}

/// The voices a listener asks to leave out, from the start of every tune.
struct LeftOut: Sendable {
    /// Voice numbers from 0.
    var voices: Set<Int> = []
    var alone: Int?

    /// For a tune of so many voices: true for each that is left out.
    func marks(_ count: Int) -> [Bool] {
        if let alone, alone < count { return (0 ..< count).map { $0 != alone } }
        return (0 ..< count).map { voices.contains($0) }
    }

    /// What pressing a voice's key does to the voices left out: `solo` to hear it alone, or, if it
    /// is so already, all of them again; otherwise to leave it out, or bring it back.
    static func pressed(_ voice: Int, solo: Bool, in marks: [Bool]) -> [Bool] {
        guard marks.indices.contains(voice) else { return marks }
        var marks = marks
        if solo {
            let alone = marks.indices.allSatisfy { marks[$0] == ($0 != voice) }
            marks = marks.indices.map { !alone && $0 != voice }
        } else {
            marks[voice].toggle()
        }
        return marks
    }
}

struct NowPlaying {
    /// Incremented whenever a new tune or subsong starts.
    var generation = 0
    var header = ""
    /// What the tune asks for that is not played as it asks, to be printed under the header.
    var shortfalls: [String] = []
    var length = 0.0
    var index = 0
    /// Lines to print above the status line (skipped files and the like).
    var messages: [String] = []
    var finished = false
    /// How loud each voice of the tune has been since this was last read, from 0 to 1, and which of
    /// them are left out.
    var levels: [Float] = []
    var muted: [Bool] = []
    /// How far the song is turned up or down to be as loud as the rest, in dB, once that is known,
    /// when tunes are levelled.
    var levelChange: Double?
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
    /// The voices left out of every tune from its start.
    private let leftOut: LeftOut
    /// How far songs are brought to the same loudness, and what measures them, if they are.
    private let levelling: Levelling
    private let levels: Levels?
    let nowPlaying = Mutex(NowPlaying())

    init(ring: SampleRing, playlist: [URL], files: TuneFiles, policy: PlaybackPolicy, television: TelevisionSet?, leftOut: LeftOut = LeftOut(),
         levelling: Levelling = .off, levels: Levels? = nil) {
        self.ring = ring
        self.playlist = playlist
        self.files = files
        self.policy = policy
        self.television = television
        self.leftOut = leftOut
        self.levelling = levelling
        self.levels = levelling == .off ? nil : levels
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
            $0.shortfalls = renderer.info.shortfalls
            $0.length = session.displayLength
            $0.index = index
            $0.levels = [Float](repeating: 0, count: renderer.channelCount)
            $0.levelChange = nil
        }
    }

    /// The song as it is heard with voices left out: another player of it, loaded from the same file,
    /// which plays the song from its start, unheard, until it has got to where the song is, and is
    /// then heard in its place (see `TuneSession.heard`). Until then the song is heard whole, as it
    /// was. Once there, voices are left out and brought back at once.
    private final class Twin {
        let renderer: any Renderer
        /// Frames of the song this player has been given.
        var frames = 0

        init(_ renderer: any Renderer) {
            self.renderer = renderer
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
                // Every song starts with every voice heard, but for those asked to be left out of all.
                var muted = leftOut.marks(renderer.channelCount)
                var twin: Twin?
                /// The listener has changed which voices are left out.
                func leaveOut(_ marks: [Bool]) {
                    muted = marks
                    nowPlaying.withLock { $0.muted = marks }
                    guard marks.contains(true) else {
                        twin = nil
                        session.heard = nil
                        return
                    }
                    if let twin {
                        twin.renderer.setMuted(marks)
                        return
                    }
                    guard let other = try? files.load(url) else { return }
                    if other.subsongCount > 1 || subsong != other.currentSubsong { other.select(subsong: subsong) }
                    other.setMuted(marks)
                    twin = Twin(other)
                }
                if muted.contains(true) { leaveOut(muted) } else { nowPlaying.withLock { $0.muted = muted } }

                // The song is measured, if it has not been, and then the one after it, so that it is
                // ready when that begins. Until this one's level is known it is heard as it is, and
                // then glides there.
                var gain = LevelGain()
                var levelled = levels == nil
                /// The level of the song by as much of it as had been measured, that it was last brought to.
                var estimate: SongLevel?
                if let levels {
                    var wanted = [Levels.Song(url: url, number: subsong)]
                    if policy.allSubsongs, subsong + 1 < renderer.subsongCount {
                        wanted.append(Levels.Song(url: url, number: subsong + 1))
                    } else if index + 1 < playlist.count {
                        wanted.append(Levels.Song(url: playlist[index + 1], number: nil))
                    }
                    levels.want(wanted)
                    // A song not measured before is given up to a second to be measured now; if
                    // that is not enough, it starts at about its level, by as much of it as has
                    // been measured, glides to about its level again with each second more of it
                    // measured, and to its level once the whole of it has been.
                    let until = Date().addingTimeInterval(1)
                    while levels.level(of: url, song: subsong) == nil, Date() < until { usleep(10000) }
                    if let level = levels.level(of: url, song: subsong) {
                        gain = LevelGain(level.gain(levelling))
                        levelled = true
                        nowPlaying.withLock { $0.levelChange = level.change(levelling) }
                    } else if let partly = levels.provisionalLevel(of: url, song: subsong) {
                        gain = LevelGain(partly.gain(levelling))
                        estimate = partly
                    }
                }

                while !session.finished {
                    // A player of the song with voices left out that has not yet got to where the song
                    // is goes a step nearer; and once there, is what is heard.
                    if let twin, session.heard == nil {
                        let behind = session.framesRendered - twin.frames
                        if behind > 0 {
                            let step = min(behind, 16384)
                            var done = 0
                            while done < step {
                                let count = min(block, step - done)
                                twin.renderer.render(into: buffer, frames: count)
                                done += count
                            }
                            twin.frames += step
                        }
                        if twin.frames == session.framesRendered { session.heard = twin.renderer }
                    }
                    for command in commands.withLock({ let c = $0; $0.removeAll(); return c }) {
                        switch command {
                        case let .mute(voice):
                            leaveOut(LeftOut.pressed(voice, solo: false, in: muted))
                        case let .solo(voice):
                            leaveOut(LeftOut.pressed(voice, solo: true, in: muted))
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
                    if !levelled, let level = levels?.level(of: url, song: subsong) {
                        gain.glide(to: level.gain(levelling))
                        levelled = true
                        nowPlaying.withLock { $0.levelChange = level.change(levelling) }
                    } else if !levelled, let partly = levels?.provisionalLevel(of: url, song: subsong), partly != estimate {
                        gain.glide(to: partly.gain(levelling))
                        estimate = partly
                    }
                    gain.apply(buffer, frames: produced)
                    television?.process(buffer, frames: produced)
                    if produced > 0 { ring.write(buffer, frames: produced) }
                    let levels = session.channelLevels
                    nowPlaying.withLock { state in
                        for voice in levels.indices where voice < state.levels.count { state.levels[voice] = max(state.levels[voice], levels[voice]) }
                    }
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
