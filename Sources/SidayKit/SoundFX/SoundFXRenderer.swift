// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after MODRenderer, whose way with the sound chip's output is derived from pt2-clone,
// Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence (see THIRD-PARTY.md).

/// A SoundFX file: a four-channel module from the Amiga's first years, played as SoundFX's own
/// routine played it, on an emulation of the Amiga's sound chip.
///
/// As with any module for the Amiga the two sides are brought most of the way together (see
/// `MODRenderer`).
///
/// A module has no way of going anywhere but on to its next pattern, and round to its first from
/// its last. So where one file was made to hold several tunes, a tune for each level of a game, say,
/// they were set apart by a pattern with nothing in it, and whoever played the file was to know
/// where each began. Those are its songs here: a file is divided wherever a pattern of silence is
/// followed by one that is not.
public final class SoundFXRenderer: Renderer {
    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var subsongCount: Int { songList.count }
    public private(set) var currentSubsong = 0
    public var songs: [SongInfo] { songList.map { SongInfo(length: $0.length) } }
    public var knownLength: Double? { songList[currentSubsong].length }
    public var endsByLooping: Bool { true }
    public var isPlayedOnAnAmiga: Bool { true }

    /// One of the songs: the places in the order of playing that are its own.
    private struct Song {
        var first: Int
        var end: Int
        var length: Double
    }

    private let module: SoundFXModule
    private let songList: [Song]
    private let model: AmigaModel
    /// How much of the difference between the two sides is kept, halved: none of it for mono.
    private let side: Float
    private var player: SoundFXPlayer
    /// One tick of sound: made at twice the rate, then brought down where it lies.
    private let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    private var tickFrames = 0, tickPosition = 0
    private var levels = TickLevels(voices: 4)
    private var notes = TickNotes(voices: 4)
    private var down = (HalfBand(), HalfBand())
    /// The part of a sample that ticks are over by, carried from tick to tick: in samples times the
    /// sound chip's clock.
    private var remainder = 0

    /// The longest a tick can be, at twice the output's rate, and some to spare.
    /// (Worked out in 64 bits, as a tick's length is below: clocks times samples is more than the 32
    /// that a whole number has in a browser can hold.)
    private static let tickSpace = Int(Int64(65536 * SoundFXPlayer.clocksPerTimerCount) * Int64(outputSampleRate) * 2
        / Int64(SoundFXPlayer.chipClock)) + 64
    /// A file is only divided into songs if its timer counts from more than this, which is a tick
    /// of a hundredth of a second: the number is the one the player of these files for
    /// DeliTracker goes by, which divides them in the same way.
    private static let fastestDivided = 7094
    /// As loud as a MOD file, which is played on the same chip. See `MODRenderer`.
    private static let gain: Float = 0.26

    public init(_ data: [UInt8], options: LoadOptions) throws {
        module = try SoundFXModule(data)
        model = options.amigaModel
        side = options.stereo == .mono ? 0 : Float(max(0, min(1, options.amigaSeparation))) * 0.5
        info = TuneInfo(format: "SoundFX")

        // A song's length needs no finding: every line is six ticks, every pattern 64 lines, and a
        // tick is as long as the file says.
        let tick = Double((module.timer + 1) * SoundFXPlayer.clocksPerTimerCount) / Paula.clockHz
        let pattern = tick * Double(SoundFXPlayer.ticksPerLine * SoundFXModule.linesInPattern)
        var songList: [Song] = []
        for part in Self.songs(of: module) {
            songList.append(Song(first: part.first, end: part.end, length: pattern * Double(part.end - part.first)))
        }
        self.songList = songList
        left = .allocate(capacity: Self.tickSpace)
        right = .allocate(capacity: Self.tickSpace)
        player = SoundFXPlayer(module, model: model)
        restart()
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// The songs of a module: the stretches of its order of playing that lie between patterns of
    /// silence. A pattern of silence parts two songs only if music follows it at once, and the
    /// very first place in the order is never taken for a gap.
    private static func songs(of module: SoundFXModule) -> [(first: Int, end: Int)] {
        func isSilent(_ place: Int) -> Bool {
            let pattern = Int(module.positions[place])
            for line in 0 ..< SoundFXModule.linesInPattern {
                for voice in 0 ..< 4 {
                    let cell = module.cell(pattern: pattern, line: line, voice: voice)
                    // (A mark to stop a voice, with nothing else beside it, is silence too.)
                    let nothing = cell.instrument == 0 && cell.command == 0 && cell.data == 0
                    if !(nothing && (cell.period == 0 || cell.period == 0xFFFE)) { return false }
                }
            }
            return true
        }
        var parts: [(first: Int, end: Int)] = []
        var first = 0
        var place = 1
        let count = module.positions.count
        // (A file whose ticks come fast has short patterns, and a silent one in it is a pause.)
        guard module.timer > Self.fastestDivided else { return [(0, count)] }
        while place < count - 1 {
            if isSilent(place), !isSilent(place + 1) {
                parts.append((first, place))
                first = place + 1
                place += 2
            } else {
                place += 1
            }
        }
        parts.append((first, count))
        return parts
    }

    public func select(subsong: Int) {
        currentSubsong = max(0, min(songList.count - 1, subsong))
        restart()
    }

    private func restart() {
        let song = songList[currentSubsong]
        player = SoundFXPlayer(module, model: model, first: song.first, end: song.end)
        down = (HalfBand(), HalfBand())
        tickFrames = 0
        tickPosition = 0
        levels.clear()
        notes.clear()
        remainder = 0
        loopCount = 0
    }

    /// How many samples a tick of so many of the sound chip's clocks lasts. What is over is kept
    /// for the next tick.
    private static func tickLength(_ clocks: Int, _ remainder: inout Int) -> Int {
        let whole = Int64(clocks) * Int64(outputSampleRate) + Int64(remainder)
        remainder = Int(whole % Int64(SoundFXPlayer.chipClock))
        return Int(whole / Int64(SoundFXPlayer.chipClock))
    }

    /// Runs the player for a tick, and makes the sound of that tick.
    private func nextTick() {
        if !player.runTick() { loopCount += 1 }
        tickFrames = Self.tickLength(player.tickClocks, &remainder)
        tickPosition = 0
        player.paula.generate(left: left, right: right, count: tickFrames * 2)
        player.paula.takeLevels(into: &levels.now)
        levels.tickMade()
        player.takeNotes(into: &notes)
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

    /// What the player tells the sound chip, tick by tick, from the start of the song that is
    /// playing: for setting beside what SoundFX's own routine tells it. The song is left at its start.
    /// - Parameter places: the places in the order of playing to play in place of that song's: the
    ///   first, and the one after the last (nil for the end of the order).
    public func registerTicks(seconds: Double, places: (first: Int, end: Int?)? = nil) -> [SoundFXTick] {
        restart()
        if let places { player = SoundFXPlayer(module, model: model, first: places.first, end: places.end) }
        player.record = SoundFXTick()
        var ticks: [SoundFXTick] = []
        var clocks = 0.0
        while clocks < seconds * Paula.clockHz {
            _ = player.runTick()
            if let tick = player.record { ticks.append(tick) }
            clocks += Double(player.tickClocks)
        }
        restart()
        return ticks
    }
}
