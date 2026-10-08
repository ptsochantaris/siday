// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from it2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// An IT file, Impulse Tracker's kind of module, played by Impulse Tracker's replayer.
///
/// Impulse Tracker's own sound drivers were for the cards of its day and play neither a stereo
/// sample nor, most of them, a filter. The driver here is the one the port this is made from adds to
/// them: it mixes in floating point through a windowed sinc, ramps volumes, and has the resonant
/// filter, with the wider range ModPlug Tracker gave it where a file asks for that.
public final class ITRenderer: Renderer, ReferenceComparable {
    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var endsByLooping: Bool { true }
    public var subsongCount: Int { songList.count }
    public private(set) var currentSubsong = 0
    public var defaultSubsong: Int { ModuleSongs.first(of: songList.map { $0.empty }) }
    public var songs: [SongInfo] { songList.map { SongInfo(length: $0.length) } }
    public var knownLength: Double? { songList[currentSubsong].length }

    private let module: IT2Module
    private let songList: [ModuleSongs.Song]
    /// Which song first played each row. See `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>
    private let mono: Bool
    private var player: IT2Player
    private var tickFrames = 0, tickPosition = 0
    private var started = false

    /// A tune that has not come round after this many ticks is taken not to.
    private static let mostTicks = 50 * 60 * 120
    /// Set by measure, so that a module is about as loud as the chip tunes it is played among.
    private static let gain: Float = 0.64

    public init(_ data: [UInt8], options: LoadOptions) throws {
        module = try IT2Module(data)
        mono = options.stereo == .mono

        var info = TuneInfo(format: "IT")
        info.title = module.title
        info.detail = module.madeWith
        self.info = info

        // Once through each of its songs in silence, to find how long it is.
        let module = module
        let firstPlayedBy = UnsafeMutablePointer<UInt8>.allocate(capacity: IT2Player.rowsInAll)
        firstPlayedBy.initialize(repeating: ModuleSongs.unplayed, count: IT2Player.rowsInAll)
        self.firstPlayedBy = firstPlayedBy
        songList = ModuleSongs.find(places: 256, isPattern: { Int(module.Orders[$0]) < module.patternLimit }) { start, number in
            let player = IT2Player(module, order: start, firstPlayedBy: firstPlayedBy, songNumber: number)
            var frames = 0, ticks = 0
            while ticks < Self.mostTicks {
                player.Update()
                if player.cameRound, ticks > 0 { break }
                frames += player.mixer.skipTick()
                ticks += 1
            }
            let length = ticks < Self.mostTicks ? Double(frames) / Double(outputSampleRate) : nil
            return ModuleSongs.Pass(played: player.ordersPlayed, length: length, sounded: player.playedNote,
                                    ledIntoEarlierSong: player.ledIntoEarlierSong)
        }
        player = IT2Player(module)
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
        player = IT2Player(module, order: song.start, firstPlayedBy: firstPlayedBy, songNumber: song.number)
        tickFrames = 0
        tickPosition = 0
        loopCount = 0
        started = false
    }

    private func nextTick() {
        player.Update()
        if player.cameRound, started { loopCount += 1 }
        started = true
        tickFrames = player.mixer.mixTick()
        tickPosition = 0
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if tickPosition == tickFrames { nextTick() }
            let count = min(frames - done, tickFrames - tickPosition)
            let out = buffer + done * 2
            player.mixer.postMix(into: out, from: tickPosition, count: count)
            if mono {
                for i in 0 ..< count {
                    let both = (out[i * 2] + out[i * 2 + 1]) * (Self.gain * 0.5)
                    out[i * 2] = both
                    out[i * 2 + 1] = both
                }
            } else {
                for i in 0 ..< count * 2 { out[i] *= Self.gain }
            }
            tickPosition += count
            done += count
        }
    }

    /// The tune from its start as the reference player writes it to a file: sixteen bits, left and
    /// right in turn. For comparing the two.
    public func renderRaw(frames: Int) -> [Int16] {
        restart()
        var output = [Int16](repeating: 0, count: frames * 2)
        var done = 0
        output.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { return }
            while done < frames {
                nextTick()
                let count = min(frames - done, tickFrames)
                player.mixer.postMix(into: base + done * 2, from: 0, count: count)
                done += count
            }
        }
        restart()
        return output
    }
}
