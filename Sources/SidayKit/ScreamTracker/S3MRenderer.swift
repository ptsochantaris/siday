// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from st3play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// An S3M file, Scream Tracker 3's kind of module, played by Scream Tracker's replayer on one of the
/// two sound cards it knew.
///
/// Which card matters: a tune written with a Gravis Ultrasound was heard smoothly mixed, and one
/// written with a Sound Blaster was heard in eight bits at 22 kHz. A file saved by Scream Tracker
/// says which it was saved with, and is played on that unless another is asked for.
///
/// Beside either there may be an AdLib card, for the channels of a tune that are FM and not samples.
public final class S3MRenderer: Renderer, ReferenceComparable {
    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var endsByLooping: Bool { true }
    public var subsongCount: Int { songList.count }
    public private(set) var currentSubsong = 0
    public var defaultSubsong: Int { ModuleSongs.first(of: songList.map { $0.empty }) }
    public var songs: [SongInfo] { songList.map { SongInfo(length: $0.length) } }
    public var knownLength: Double? { songList[currentSubsong].length }

    private let module: ST3Module
    private let card: ST3Card
    private let mono: Bool
    /// One of the file's songs: where in the list of patterns it starts, how long it is, and whether
    /// it plays a note on the AdLib card at some point. The card is then mixed in from the start, so
    /// that the samples do not drop in volume at its first note.
    private struct Song {
        var start: Int
        var number: UInt8
        var length: Double?
        var empty: Bool
        var adLib: Bool
    }

    private let songList: [Song]
    /// Which song first played each row. See `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>
    private var usesAdLib: Bool { songList[currentSubsong].adLib }
    private var player: ST3Player
    private let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    private var tickFrames = 0, tickPosition = 0
    /// The part of a sample that ticks are over by, in 2^-32s, carried from tick to tick.
    private var remainder: UInt64 = 0
    private var started = false
    // For `renderRaw`: the reference player's dither.
    private var seed: UInt32 = 0x1234_5000
    private var ditherLeft: Float = 0, ditherRight: Float = 0

    /// The slowest tempo is some nineteen ticks a second, and a tick is then some 2,500 samples.
    private static let tickSpace = 16384
    private static let mostTicks = 50 * 60 * 120
    /// Set by ear and by measure, so that a module is about as loud as the chip tunes it is played
    /// among, whichever card it is on: what a GUS puts out is half as loud again as a Sound Blaster.
    /// The samples are made quieter by a third to leave room for the AdLib card in sixteen bits;
    /// there is room to spare here, so with that card both are brought back up by as much.
    private var gain: Float { (card == .gus ? 0.34 : 0.5) * (usesAdLib ? 1.5 : 1) }

    public init(_ data: [UInt8], options: LoadOptions) throws {
        module = try ST3Module(data)
        card = options.s3mCard ?? (module.savedWithSoundBlaster ? .sb : .gus)
        mono = options.stereo == .mono
        left = .allocate(capacity: Self.tickSpace)
        right = .allocate(capacity: Self.tickSpace)

        // Once through each of its songs in silence, to find how long it is and whether the AdLib
        // card is in it.
        let module = module, card = card
        let firstPlayedBy = UnsafeMutablePointer<UInt8>.allocate(capacity: ST3Player.rowsInAll)
        firstPlayedBy.initialize(repeating: ModuleSongs.unplayed, count: ST3Player.rowsInAll)
        self.firstPlayedBy = firstPlayedBy
        var adLib = [Bool](repeating: false, count: ST3Module.mostOrders + 1)
        let found = ModuleSongs.find(places: module.ordnum, isPattern: { module.order[$0] < 254 }) { start, number in
            let player = ST3Player(module, card: card, order: start, firstPlayedBy: firstPlayedBy, songNumber: number)
            var frames = 0, ticks = 0
            var remainder: UInt64 = 0
            if !player.silent {
                while ticks < Self.mostTicks {
                    player.tick()
                    if player.cameRound, ticks > 0 { break }
                    frames += Self.tickLength(player, &remainder)
                    ticks += 1
                }
            }
            adLib[start] = player.adlibused
            let length = ticks > 0 && ticks < Self.mostTicks ? Double(frames) / Double(outputSampleRate) : nil
            return ModuleSongs.Pass(played: player.ordersPlayed, length: length, sounded: player.playedNote,
                                    ledIntoEarlierSong: player.ledIntoEarlierSong)
        }
        songList = found.map { Song(start: $0.start, number: $0.number, length: $0.length, empty: $0.empty, adLib: adLib[$0.start]) }
        player = ST3Player(module, card: card)

        var info = TuneInfo(format: "S3M")
        info.title = module.title
        info.detail = "Scream Tracker 3, " + (card == .gus ? "Gravis Ultrasound" : "Sound Blaster Pro") + (songList.contains { $0.adLib } ? " and AdLib" : "")
        self.info = info
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
        let song = songList[currentSubsong]
        player = ST3Player(module, card: card, order: song.start, adlib: song.adLib && !ST3Player.repeatsReferenceSlips,
                           firstPlayedBy: firstPlayedBy, songNumber: song.number)
        tickFrames = 0
        tickPosition = 0
        remainder = 0
        loopCount = 0
        started = false
        seed = 0x1234_5000
        ditherLeft = 0
        ditherRight = 0
    }

    /// How many samples the tick just run lasts, at the tempo it left.
    private static func tickLength(_ player: ST3Player, _ remainder: inout UInt64) -> Int {
        var frames = Int(player.samplesPerTick >> 32)
        remainder += player.samplesPerTick & 0xFFFF_FFFF
        if remainder > 0xFFFF_FFFF {
            remainder &= 0xFFFF_FFFF
            frames += 1
        }
        return min(Self.tickSpace, max(1, frames))
    }

    private func nextTick() {
        player.tick()
        if player.cameRound, started { loopCount += 1 }
        started = true
        tickFrames = Self.tickLength(player, &remainder)
        tickPosition = 0
        player.cards.render(left: left, right: right, count: tickFrames, channels: player.zchn)
        if player.adlibused { player.adlib.render(left: left, right: right, count: tickFrames, sinc: player.cards.sinc) }
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        let gain = gain
        var done = 0
        while done < frames {
            if tickPosition == tickFrames { nextTick() }
            let count = min(frames - done, tickFrames - tickPosition)
            if mono {
                for i in 0 ..< count {
                    let both = (left[tickPosition + i] + right[tickPosition + i]) * (gain * 0.5)
                    buffer[(done + i) * 2] = both
                    buffer[(done + i) * 2 + 1] = both
                }
            } else {
                for i in 0 ..< count {
                    buffer[(done + i) * 2] = left[tickPosition + i] * gain
                    buffer[(done + i) * 2 + 1] = right[tickPosition + i] * gain
                }
            }
            tickPosition += count
            done += count
        }
    }

    /// The tune from its start as the reference player writes it to a file: sixteen bits, left and
    /// right in turn, with that player's dither. For comparing the two.
    public func renderRaw(frames: Int) -> [Int16] {
        restart()
        var output: [Int16] = []
        output.reserveCapacity(frames * 2)

        func dithered(_ sample: Float, _ state: inout Float) -> Int16 {
            seed = seed &* 134_775_813 &+ 1
            let noise = Float(Int32(bitPattern: seed)) * (1.0 / 4_294_967_296.0)
            let value = (sample * 32768.0 + noise) - state
            state = noise
            return Int16(max(-32768, min(32767, Int32(max(-1e9, min(1e9, value))))))
        }
        while output.count < frames * 2 {
            if tickPosition == tickFrames { nextTick() }
            while tickPosition < tickFrames, output.count < frames * 2 {
                output.append(dithered(left[tickPosition], &ditherLeft))
                output.append(dithered(right[tickPosition], &ditherRight))
                tickPosition += 1
            }
        }
        restart()
        return output
    }
}
