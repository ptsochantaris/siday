// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ahx2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// An AHX file: a module from the Amiga with no samples in it, whose instruments are made up as it
/// plays. It is played by AHX's own replayer on the emulation of the Amiga's sound chip that plays
/// MOD files, and heard as they are: on either Amiga, with its two sides brought most of the way
/// together, and all the way for mono.
///
/// A file can hold several songs, and says itself where each starts: the one from the top of its
/// list of positions, and then any others, but for those that start where an earlier one has
/// played through. A song is over when it comes round to a row it has played, or when it stops itself.
public final class AHXRenderer: Renderer, ReferenceComparable {
    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var subsongCount: Int { songList.count }
    public private(set) var currentSubsong = 0
    public var defaultSubsong: Int { ModuleSongs.first(of: songList.map { $0.empty }) }
    public var songs: [SongInfo] { songList.map { SongInfo(length: $0.length, empty: $0.empty) } }
    public var knownLength: Double? { songList[currentSubsong].length }
    public var endsByLooping: Bool { true }
    public var isPlayedOnAnAmiga: Bool { true }
    public var hasEnded: Bool { replayer.stopped }

    private struct Song {
        /// Where in the list of positions it starts.
        var start: UInt16
        /// How long it is before it comes round or stops, in seconds; nil if it was not found to.
        var length: Double?
        /// True if there is nothing to it: no note, or less than a second.
        var empty: Bool
    }

    private let module: AHXModule
    private let waves = AHXWaves()
    private let songList: [Song]
    private let model: AmigaModel
    /// How much of the difference between the two sides is kept, halved: none of it for mono.
    private let side: Float
    /// The same as the player this is ported from is told it, in hundredths, for `renderRaw`.
    private let separation: Int
    private var replayer: AHXReplayer
    /// One tick of sound: made at twice the rate, then brought down where it lies.
    private let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    private var tickFrames = 0, tickPosition = 0
    private var levels = TickLevels(voices: 4)
    private var notes = TickNotes(voices: 4)
    private var down = (HalfBand(), HalfBand())
    /// The part of a sample that ticks are over by, in 2^-52s, carried from tick to tick.
    private var remainder: UInt64 = 0
    private static let one: UInt64 = 1 << 52
    // For `renderRaw`: the reference player's dither.
    private var seed: UInt32 = 0x1234_5000
    private var ditherLeft: Float = 0, ditherRight: Float = 0

    /// The longest a tick can be, at twice the output's rate, and some to spare.
    private static let tickSpace = 2048
    /// A tune that has not come round after this many ticks is taken not to.
    private static let mostTicks = 50 * 60 * 120
    /// Two voices at their loudest on one side come to twice this. It is set by measure, so that the
    /// middle of a run of AHX tunes comes out as loud as the middle of a run of MOD files. It is less
    /// than a MOD file's, since a wave that is made up fills a voice as few samples do.
    private static let gain: Float = 0.17

    public init(_ data: [UInt8], options: LoadOptions) throws {
        module = try AHXModule(data)
        model = options.amigaModel
        let apart = max(0, min(1, options.amigaSeparation))
        side = options.stereo == .mono ? 0 : Float(apart) * 0.5
        separation = options.stereo == .mono ? 100 : Int((apart * 100).rounded())
        left = .allocate(capacity: Self.tickSpace)
        right = .allocate(capacity: Self.tickSpace)

        var info = TuneInfo(format: "AHX")
        info.title = module.title
        info.detail = module.revision == 0 ? "AHX 1" : "AHX 2"
        if module.timerPeriod != 14209 { info.detail += ", \(Int(module.ticksPerSecond.rounded())) ticks a second" }
        self.info = info

        // The songs the file says it has. (One said to start past the end of the list is no song: the
        // player this is ported from plays whatever its memory holds there.) And one said to start
        // at a place an earlier song has played through is no song of its own either, but a way
        // into that one: many files have several of those, and each would be the same music again.
        let module = module, waves = waves, model = model
        let starts = [0] + module.subsongStarts.filter { $0 < module.positionCount }
        var heard = [Bool](repeating: false, count: Int(module.positionCount))
        var found: [Song] = []
        // Once through each of them in silence, to find how long it is.
        for start in starts where !heard[Int(start)] {
            var replayer = AHXReplayer(module, waves: waves, model: model, rate: Double(outputSampleRate), position: start)
            var frames = 0, ticks = 0
            var remainder: UInt64 = 0
            while ticks < Self.mostTicks {
                if Int(replayer.position) < heard.count { heard[Int(replayer.position)] = true }
                let more = replayer.runTick()
                frames += Self.tickLength(module, &remainder)
                ticks += 1
                if !more || replayer.stopped { break }
            }
            let length = ticks < Self.mostTicks ? Double(frames) / Double(outputSampleRate) : nil
            found.append(Song(start: start, length: length, empty: !replayer.playedNote || (length ?? 1) < 1))
        }
        songList = found
        replayer = AHXReplayer(module, waves: waves, model: model, rate: Double(outputSampleRate * 2))
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

    /// - Parameter asReference: with the sound chip run as the player this is ported from runs it,
    ///   at the output's own rate, for `renderRaw`.
    private func restart(asReference: Bool = false) {
        replayer = AHXReplayer(module, waves: waves, model: model, rate: Double(outputSampleRate * (asReference ? 1 : 2)),
                               position: songList[currentSubsong].start)
        down = (HalfBand(), HalfBand())
        tickFrames = 0
        tickPosition = 0
        levels.clear()
        notes.clear()
        remainder = 0
        loopCount = 0
        seed = 0x1234_5000
        ditherLeft = 0
        ditherRight = 0
    }

    /// How many samples a tick lasts. The timer that keeps the ticks does not go a whole number of
    /// samples, and what is over is kept for the next.
    private static func tickLength(_ module: AHXModule, _ remainder: inout UInt64) -> Int {
        let exact = Double(outputSampleRate) / module.ticksPerSecond
        let whole = exact.rounded(.towardZero)
        var frames = Int(whole)
        remainder += UInt64((exact - whole) * Double(Self.one))
        if remainder >= Self.one {
            remainder &= Self.one - 1
            frames += 1
        }
        return frames
    }

    /// Runs the replayer for a tick, unless the tune has stopped it, and makes the sound of that tick.
    private func nextTick() {
        if !replayer.stopped, !replayer.runTick() { loopCount += 1 }
        tickFrames = Self.tickLength(module, &remainder)
        tickPosition = 0
        replayer.paula.generate(left: left, right: right, count: tickFrames * 2)
        replayer.paula.takeLevels(into: &levels.now)
        levels.tickMade()
        replayer.takeNotes(into: &notes)
        for i in 0 ..< tickFrames {
            left[i] = down.0.step(left[i * 2], left[i * 2 + 1])
            right[i] = down.1.step(right[i * 2], right[i * 2 + 1])
        }
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if tickPosition == tickFrames { nextTick() }
            let count = min(frames - done, tickFrames - tickPosition)
            for i in 0 ..< count {
                let l = left[tickPosition + i], r = right[tickPosition + i]
                let middle = (l + r) * 0.5, apart = (l - r) * side
                buffer[(done + i) * 2] = (middle + apart) * Self.gain
                buffer[(done + i) * 2 + 1] = (middle - apart) * Self.gain
            }
            tickPosition += count
            done += count
        }
    }

    /// Paula's four voices.
    public var channelCount: Int { 4 }

    public func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        // The Amiga's own sides, however near they are brought to one another here.
        for voice in 0 ..< 4 { sides[voice] = Paula.side(ofVoice: voice) }
    }

    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        self.levels.take(into: levels)
    }

    public func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        notes.take(pitches: pitches, struck: struck)
    }

    /// The tune from its start as the reference player writes it to a file: sixteen bits, left and
    /// right in turn, at that player's loudness and with its dither, and the two sides as far apart
    /// as they are listened to here (for mono, as far as the Amiga has them). For comparing the two.
    ///
    /// That player runs the sound chip at the rate of its output and puts nothing after it, where
    /// for listening the chip is run at twice the rate and followed by what an Amiga has on its
    /// board. And it goes on playing a tune that has stopped itself, which here is the end of it.
    public func renderRaw(frames: Int) -> [Int16] {
        restart(asReference: true)
        var output: [Int16] = []
        output.reserveCapacity(frames * 2)

        func dithered(_ sample: Float, _ state: inout Float) -> Int16 {
            seed = seed &* 134_775_813 &+ 1
            let noise = Float(Int32(bitPattern: seed)) * (1.0 / 4_294_967_296.0)
            let value = (sample * 14336.0 + noise) - state
            state = noise
            return Int16(max(-32768, min(32767, Int32(value))))
        }
        let side = Float(separation) / 100.0 * 0.5
        while output.count < frames * 2 {
            _ = replayer.runTick()
            let count = Self.tickLength(module, &remainder)
            replayer.paula.generateUnfiltered(left: left, right: right, count: count)
            var i = 0
            while i < count, output.count < frames * 2 {
                var l = left[i], r = right[i]
                if separation != 100 {
                    let middle = (l + r) * 0.5, apart = (l - r) * side
                    l = middle + apart
                    r = middle - apart
                }
                output.append(dithered(l, &ditherLeft))
                output.append(dithered(r, &ditherRight))
                i += 1
            }
        }
        restart()
        return output
    }
}
