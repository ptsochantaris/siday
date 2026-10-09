// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ft2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// An XM file, FastTracker 2's own kind of module, or a MOD file of more channels than the Amiga
/// has: played by FastTracker's replayer and mixer.
///
/// An XM has its instruments where its composer placed them between the speakers, and that is how it
/// is heard here unless the sound is asked for in mono. FastTracker plays a MOD file's channels all
/// in the middle.
public final class XMRenderer: Renderer, ReferenceComparable {
    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var subsongCount: Int { songList.count }
    public private(set) var currentSubsong = 0
    public var defaultSubsong: Int { ModuleSongs.first(of: songList.map { $0.empty }) }
    public var songs: [SongInfo] { songList.map { SongInfo(length: $0.length) } }
    public var knownLength: Double? { songList[currentSubsong].length }
    public var endsByLooping: Bool { true }
    public var hasEnded: Bool { player.stopped }

    private let module: FT2Module
    private let songList: [ModuleSongs.Song]
    /// Which song first played each row. See `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>
    private let mono: Bool
    private var player: FT2Player
    private var tickFrames = 0, tickPosition = 0

    /// A tune that has not come round after this many ticks is taken not to.
    private static let mostTicks = 50 * 60 * 120
    /// From the mixer's whole numbers to the player's range, at a level set by ear and by measure so
    /// that a module is about as loud as the chip tunes it is played among.
    private static let gain: Float = 1.0 / (256.0 * 32768.0) * 1.6

    public init(_ data: [UInt8], options: LoadOptions) throws {
        module = try FT2Module(data)
        mono = options.stereo == .mono
        var info = TuneInfo(format: module.isMOD ? "MOD" : "XM")
        info.title = module.title
        info.detail = "FastTracker 2, \(module.song.antChn) channels"
        self.info = info

        // Once through each of its songs in silence, to find how long it is.
        let module = module
        let firstPlayedBy = UnsafeMutablePointer<UInt8>.allocate(capacity: FT2Player.rowsInAll)
        firstPlayedBy.initialize(repeating: ModuleSongs.unplayed, count: FT2Player.rowsInAll)
        self.firstPlayedBy = firstPlayedBy
        songList = ModuleSongs.find(places: Int(module.song.len), isPattern: { _ in true }) { start, number in
            let player = FT2Player(module, position: start, firstPlayedBy: firstPlayedBy, songNumber: number)
            var frames = 0, ticks = 0
            var watch = ModuleSongs.Watch()
            while ticks < Self.mostTicks, !player.stopped {
                let more = player.runSilentTick()
                if watch.tick(frames: frames, playedNote: player.playedNote, ledIntoEarlierSong: player.ledIntoEarlierSong) { break }
                if !more { break }
                frames += Int(player.speedVal)
                ticks += 1
            }
            let length = ticks < Self.mostTicks ? Double(frames) / Double(outputSampleRate) : nil
            return ModuleSongs.Pass(played: player.ordersPlayed, length: length, sounded: watch.sounded(player.playedNote),
                                    leadIn: watch.leadIn)
        }
        player = FT2Player(module)
        currentSubsong = defaultSubsong
        restart()
    }

    deinit {
        firstPlayedBy.deallocate()
    }

    public func select(subsong: Int) {
        currentSubsong = max(0, min(songList.count - 1, subsong))
        restart()
    }

    private func restart() {
        let song = songList[currentSubsong]
        player = FT2Player(module, position: song.start, firstPlayedBy: firstPlayedBy, songNumber: song.number)
        tickFrames = 0
        tickPosition = 0
        loopCount = 0
    }

    private var started = false

    private func nextTick() {
        tickFrames = player.runTick()
        tickPosition = 0
        // The first row is always new; after that, a row played before is the tune come round.
        if player.cameRound, started { loopCount += 1 }
        started = true
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if tickPosition == tickFrames { nextTick() }
            let count = min(frames - done, tickFrames - tickPosition)
            let source = player.mixBuffer + tickPosition * 2
            if mono {
                for i in 0 ..< count {
                    let both = (Float(source[i * 2]) + Float(source[i * 2 + 1])) * (Self.gain * 0.5)
                    buffer[(done + i) * 2] = both
                    buffer[(done + i) * 2 + 1] = both
                }
            } else {
                for i in 0 ..< count {
                    buffer[(done + i) * 2] = Float(source[i * 2]) * Self.gain
                    buffer[(done + i) * 2 + 1] = Float(source[i * 2 + 1]) * Self.gain
                }
            }
            tickPosition += count
            done += count
        }
    }

    /// The tune from its start as the reference player writes it to a file: sixteen bits, left and
    /// right in turn, clipped where it is too loud for them. For comparing the two.
    public func renderRaw(frames: Int) -> [Int16] {
        restart()
        var output: [Int16] = []
        output.reserveCapacity(frames * 2)
        while output.count < frames * 2 {
            if tickPosition == tickFrames { nextTick() }
            while tickPosition < tickFrames, output.count < frames * 2 {
                for side in 0 ..< 2 {
                    output.append(Int16(max(-32768, min(32767, player.mixBuffer[tickPosition * 2 + side] >> 8))))
                }
                tickPosition += 1
            }
        }
        restart()
        return output
    }
}
