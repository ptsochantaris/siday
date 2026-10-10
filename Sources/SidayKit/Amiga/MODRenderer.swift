// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from pt2-clone, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// A MOD file: a four-channel module from the Amiga, played by ProTracker's own replayer on an
/// emulation of the Amiga's sound chip.
///
/// The Amiga wires two of its four voices to the left speaker and two to the right, with nothing in
/// between. Through loudspeakers the room does the mixing; in headphones there is no room, and a
/// module is harsh. So the two sides are brought most of the way together, as the tracker this is
/// ported from brings them by default, and all the way for mono.
public final class MODRenderer: Renderer, ReferenceComparable {
    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var subsongCount: Int { songList.count }
    public private(set) var currentSubsong = 0
    public var defaultSubsong: Int { ModuleSongs.first(of: songList.map { $0.empty }) }
    public var songs: [SongInfo] { songList.map { SongInfo(length: $0.length) } }
    public var knownLength: Double? { songList[currentSubsong].length }
    public var endsByLooping: Bool { true }
    public var hasEnded: Bool { replayer.stopped }

    private let module: ProTrackerModule
    private let songList: [ModuleSongs.Song]
    /// Which song first played each row. See `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>
    private let model: AmigaModel
    /// How much of the difference between the two sides is kept, halved: none of it for mono.
    private let side: Float
    private var replayer: ProTrackerReplayer
    /// One tick of sound: made at twice the rate, then brought down where it lies.
    private let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    private var tickFrames = 0, tickPosition = 0
    private var levels = TickLevels(voices: 4)
    private var notes = TickNotes(voices: 4)
    private var down = (HalfBand(), HalfBand())
    /// The part of a sample that ticks of a tempo are over by, in 2^-52s, carried from tick to tick.
    private var remainder: UInt64 = 0
    private static let one: UInt64 = 1 << 52
    // For `renderRaw`: the reference player's dither.
    private var seed: UInt32 = 0x1234_5000
    private var ditherLeft: Float = 0, ditherRight: Float = 0

    /// The longest a tick can be at the slowest tempo, at twice the output's rate, and some to spare.
    private static let tickSpace = 8192
    /// A tune that has not come round after this many ticks is taken not to.
    private static let mostTicks = 50 * 60 * 120
    /// Two voices at their loudest on one side come to twice this. It is set by ear and by measure, so
    /// that a module is about as loud as the chip tunes it is played among: in mono, the middle of a
    /// run of modules comes out between the middles of the Spectrum's, the Atari's and the C64's tunes.
    private static let gain: Float = 0.26

    public init(_ data: [UInt8], options: LoadOptions) throws {
        module = try ProTrackerModule(data)
        model = options.amigaModel
        side = options.stereo == .mono ? 0 : Float(max(0, min(1, options.amigaSeparation))) * 0.5
        left = .allocate(capacity: Self.tickSpace)
        right = .allocate(capacity: Self.tickSpace)

        var info = TuneInfo(format: "MOD")
        info.title = module.title
        info.detail = module.channelCount == 4 ? module.kind.name : "\(module.kind.name), \(module.channelCount) channels"
        self.info = info

        // Once through each of its songs in silence, to find how long it is.
        let module = module, model = model
        let firstPlayedBy = UnsafeMutablePointer<UInt8>.allocate(capacity: ProTrackerReplayer.rowsInAll)
        firstPlayedBy.initialize(repeating: ModuleSongs.unplayed, count: ProTrackerReplayer.rowsInAll)
        self.firstPlayedBy = firstPlayedBy
        songList = ModuleSongs.find(places: module.songLength, isPattern: { _ in true }) { start, number in
            module.restoreSamples()
            var replayer = ProTrackerReplayer(module, model: model, position: start, firstPlayedBy: firstPlayedBy, songNumber: number)
            var frames = 0, ticks = 0
            var remainder: UInt64 = 0
            var watch = ModuleSongs.Watch()
            while ticks < Self.mostTicks {
                let more = replayer.runTick()
                frames += Self.tickLength(tempo: replayer.tempo, &remainder)
                ticks += 1
                // (The replayer looks ahead: it says so on the last tick before the earlier song's row.)
                if watch.tick(frames: frames, playedNote: replayer.playedNote, ledIntoEarlierSong: replayer.ledIntoEarlierSong) { break }
                if !more || replayer.stopped { break }
            }
            let length = ticks < Self.mostTicks ? Double(frames) / Double(outputSampleRate) : nil
            return ModuleSongs.Pass(played: replayer.ordersPlayed, length: length, sounded: watch.sounded(replayer.playedNote),
                                    leadIn: watch.leadIn)
        }
        replayer = ProTrackerReplayer(module, model: model)
        currentSubsong = defaultSubsong
        restart()
    }

    deinit {
        left.deallocate()
        right.deallocate()
        firstPlayedBy.deallocate()
    }

    public func select(subsong: Int) {
        currentSubsong = max(0, min(songList.count - 1, subsong))
        restart()
    }

    private func restart() {
        module.restoreSamples()
        let song = songList[currentSubsong]
        replayer = ProTrackerReplayer(module, model: model, position: song.start, firstPlayedBy: firstPlayedBy, songNumber: song.number)
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

    /// How many samples the tick just run lasts, at the tempo it left.
    private static func tickLength(tempo: Int, _ remainder: inout UInt64) -> Int {
        let exact = Double(outputSampleRate) / ProTrackerReplayer.ticksPerSecond(tempo: tempo)
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
        tickFrames = Self.tickLength(tempo: replayer.tempo, &remainder)
        tickPosition = 0
        replayer.paula.generate(left: left, right: right, count: tickFrames * 2)
        replayer.paula.takeLevels(into: &levels.now)
        levels.tickMade()
        replayer.paula.takeNotes(into: &notes)
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

    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        self.levels.take(into: levels)
    }

    public func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        notes.take(pitches: pitches, struck: struck)
    }

    /// The tune from its start as the reference player writes it to a file: sixteen bits, left and
    /// right in turn, with that player's dither, and the two sides as far apart as they are listened
    /// to here (for mono, as far as the Amiga has them). For comparing the two.
    public func renderRaw(frames: Int) -> [Int16] {
        restart()
        var output: [Int16] = []
        output.reserveCapacity(frames * 2)

        func dithered(_ sample: Float, _ state: inout Float) -> Int16 {
            seed = seed &* 134_775_813 &+ 1
            let noise = Float(Int32(bitPattern: seed)) * (1.0 / 4_294_967_296.0)
            let value = (sample * 16384.0 + noise) - state
            state = noise
            return Int16(max(-32768, min(32767, Int32(value))))
        }
        while output.count < frames * 2 {
            if tickPosition == tickFrames { nextTick() }
            while tickPosition < tickFrames, output.count < frames * 2 {
                var l = left[tickPosition], r = right[tickPosition]
                if side > 0, side < 0.5 {
                    let middle = (l + r) * 0.5, apart = (l - r) * side
                    l = middle + apart
                    r = middle - apart
                }
                output.append(dithered(l, &ditherLeft))
                output.append(dithered(r, &ditherRight))
                tickPosition += 1
            }
        }
        restart()
        return output
    }
}
