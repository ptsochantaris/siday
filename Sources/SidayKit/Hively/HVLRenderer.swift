// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from HivelyTracker, Copyright (c) Pete Gordon, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// A HivelyTracker file: AHX carried on from the Amiga's four voices to as many as sixteen, each
/// with its own place between the speakers. It is played by HivelyTracker's own replayer and mixer,
/// which have no Amiga in them, and heard as the tracker plays it: its voices where the file puts
/// them, unless the sound is asked for in mono, and nothing of the Amiga's put after them.
///
/// A file can hold several songs, and says itself where each starts: the one from the top of its
/// list of positions, and then any others, but for those that start where an earlier one has
/// played through. A song is over when it comes round to a row it has played, or when it stops itself.
public final class HVLRenderer: Renderer, ReferenceComparable {
    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var subsongCount: Int { songList.count }
    public private(set) var currentSubsong = 0
    public var defaultSubsong: Int { ModuleSongs.first(of: songList.map { $0.empty }) }
    public var songs: [SongInfo] { songList.map { SongInfo(length: $0.length, empty: $0.empty) } }
    public var knownLength: Double? { songList[currentSubsong].length }
    public var endsByLooping: Bool { true }
    public var hasEnded: Bool { replayer.stopped }

    private struct Song {
        /// Where in the list of positions it starts.
        var start: UInt16
        /// How long it is before it comes round or stops, in seconds; nil if it was not found to.
        var length: Double?
        /// True if there is nothing to it: no note, or less than a second.
        var empty: Bool
    }

    private let module: HVLModule
    /// The waves are AHX's, made as AHX made them: the two trackers' come out the same to the byte.
    private let waves = AHXWaves()
    private let songList: [Song]
    private let mono: Bool
    private var replayer: HVLReplayer
    /// One tick of sound, as the tracker's mixer leaves it.
    private let left: UnsafeMutablePointer<Int32>, right: UnsafeMutablePointer<Int32>
    private let tickFrames: Int
    private var tickPosition: Int
    private var levels: TickLevels
    private var notes: TickNotes

    /// A tune that has not come round after this many ticks is taken not to.
    private static let mostTicks = 50 * 60 * 120
    /// From the mixer's sixteen bits to the player's range. A file says itself how loud it is to be
    /// mixed, and most are set to come close to the most sixteen bits can hold; this brings them
    /// down to where, by measure, the middle of a run of them is as loud as the middle of a run of
    /// AHX tunes or of MOD files.
    private static let gain: Float = 0.35 / 32768.0

    /// - Parameter ahxStereo: for comparing with the tracker's replayer only, which plays AHX files
    ///   too: takes an AHX file as that replayer does, with its voices this far apart, from 0 to 4.
    ///   (An AHX file that is to be listened to is `AHXRenderer`'s.)
    public init(_ data: [UInt8], options: LoadOptions, ahxStereo: Int? = nil) throws {
        module = try HVLModule(data, ahxStereo: ahxStereo)
        mono = options.stereo == .mono
        tickFrames = module.tickFrames
        tickPosition = tickFrames
        left = .allocate(capacity: tickFrames)
        right = .allocate(capacity: tickFrames)
        levels = TickLevels(voices: module.channels)
        notes = TickNotes(voices: module.channels)

        var info = TuneInfo(format: module.isAHX ? "AHX" : "HVL")
        info.title = module.title
        info.detail = "HivelyTracker, \(module.channels) channels"
        if module.speedMultiplier > 1 { info.detail += ", \(50 * module.speedMultiplier) ticks a second" }
        self.info = info

        // The songs the file says it has. (One said to start past the end of the list is no song:
        // the tracker plays whatever its memory holds there.) And one said to start at a place an
        // earlier song has played through is no song of its own either, but a way into that one.
        let module = module, waves = waves
        let starts = [0] + module.subsongStarts.filter { $0 < module.positionCount }
        var heard = [Bool](repeating: false, count: Int(module.positionCount))
        var found: [Song] = []
        // Once through each of them in silence, to find how long it is.
        for start in starts where !heard[Int(start)] {
            var replayer = HVLReplayer(module, waves: waves, position: start)
            var ticks = 0
            while ticks < Self.mostTicks {
                heard[Int(replayer.position)] = true
                let more = replayer.runTick()
                ticks += 1
                if !more || replayer.stopped { break }
            }
            let length = ticks < Self.mostTicks ? Double(ticks * module.tickFrames) / Double(outputSampleRate) : nil
            found.append(Song(start: start, length: length, empty: !replayer.playedNote || (length ?? 1) < 1))
        }
        songList = found
        replayer = HVLReplayer(module, waves: waves)
        currentSubsong = defaultSubsong
        restart()
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    public func select(subsong: Int) {
        currentSubsong = max(0, min(songList.count - 1, subsong))
        restart()
    }

    private func restart() {
        replayer = HVLReplayer(module, waves: waves, position: songList[currentSubsong].start)
        tickPosition = tickFrames
        levels.clear()
        notes.clear()
        loopCount = 0
    }

    /// Runs the replayer for a tick, unless the tune has stopped it, and makes the sound of that tick.
    private func nextTick() {
        if !replayer.stopped, !replayer.runTick() { loopCount += 1 }
        tickPosition = 0
        replayer.mix(left: left, right: right, count: tickFrames)
        replayer.takeLevels(into: &levels.now)
        levels.tickMade()
        replayer.takeNotes(into: &notes)
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if tickPosition == tickFrames { nextTick() }
            let count = min(frames - done, tickFrames - tickPosition)
            if mono {
                for i in 0 ..< count {
                    let both = Float(left[tickPosition + i] + right[tickPosition + i]) * (Self.gain * 0.5)
                    buffer[(done + i) * 2] = both
                    buffer[(done + i) * 2 + 1] = both
                }
            } else {
                for i in 0 ..< count {
                    buffer[(done + i) * 2] = Float(left[tickPosition + i]) * Self.gain
                    buffer[(done + i) * 2 + 1] = Float(right[tickPosition + i]) * Self.gain
                }
            }
            tickPosition += count
            done += count
        }
    }

    public var channelCount: Int { module.channels }

    public func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        for voice in 0 ..< module.channels { sides[voice] = replayer.side(ofVoice: voice) }
    }

    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        self.levels.take(into: levels)
    }

    public func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        notes.take(pitches: pitches, struck: struck)
    }

    /// The tune from its start as the tracker's replayer makes it: sixteen bits, left and right in
    /// turn, the voices where the file puts them whatever is asked for here, at the loudness the
    /// file asks for and clipped where that is too loud. For comparing the two.
    ///
    /// It is the sound that is listened to, before it is brought down to the player's loudness. But
    /// the replayer goes on playing a tune that has stopped itself, which here is the end of it.
    public func renderRaw(frames: Int) -> [Int16] {
        restart()
        var output: [Int16] = []
        output.reserveCapacity(frames * 2)
        while output.count < frames * 2 {
            _ = replayer.runTick()
            replayer.mix(left: left, right: right, count: tickFrames)
            var i = 0
            while i < tickFrames, output.count < frames * 2 {
                output.append(Int16(left[i]))
                output.append(Int16(right[i]))
                i += 1
            }
        }
        restart()
        return output
    }
}
