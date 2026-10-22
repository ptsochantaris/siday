// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// An STM file, played by Scream Tracker 2.3's own replayer and mixing (see `ST2Player`).
///
/// What that makes is one channel of eight bits at 23,863 samples a second, which is brought to
/// the player's rate through the windowed sinc that Scream Tracker 3's Sound Blaster is brought
/// through (see `ST3Cards`). It is the same on the left and on the right: Scream Tracker 2 knew
/// nothing of stereo.
public final class STMRenderer: Renderer, ReferenceComparable {
    public private(set) var info: TuneInfo
    public var loopCount: Int { player.loopCount }
    public var subsongCount: Int { songList.count }
    public private(set) var currentSubsong = 0
    public var defaultSubsong: Int { ModuleSongs.first(of: songList.map { $0.empty }) }
    public var songs: [SongInfo] { songList.map { SongInfo(length: $0.length, empty: $0.empty) } }
    public var knownLength: Double? { songList[currentSubsong].length }
    public var endsByLooping: Bool { true }

    private let data: [UInt8]
    private let module: ST2Module
    private let songList: [ModuleSongs.Song]
    private var player: ST2Player
    /// The last sixteen samples the player made, the newest last, and how far the next of the
    /// output's samples lies past the middle of them: in 2^32nds of one of the player's.
    private let recent: UnsafeMutablePointer<Float>
    private let sinc: UnsafeMutablePointer<Float>
    private var fraction: UInt64 = 0
    private static let step = UInt64((4_294_967_296.0 * Double(ST2Player.mixRate) / Double(outputSampleRate)).rounded())
    private var ticksSeen = 0
    private var notes = TickNotes(voices: ST2Module.channels)

    /// A tune that has not come round after this many ticks is taken not to.
    private static let mostTicks = 50 * 60 * 120
    /// Set by measure, so that these files are about as loud as XM files are.
    private static let gain: Float = 0.5

    public convenience init(_ data: [UInt8], options _: LoadOptions) throws {
        try self.init(data, format: "STM", detail: "Scream Tracker 2.3", shortfalls: [])
    }

    /// - Parameters:
    ///   - data: an STM file, or what another kind of file has been read into (see `STXFile`).
    ///   - shortfalls: what was lost in that reading.
    init(_ data: [UInt8], format: String, detail: String, shortfalls: [String]) throws {
        self.data = data
        let module = try ST2Module(data)
        self.module = module
        var info = TuneInfo(format: format)
        info.title = module.title
        info.detail = detail
        info.shortfalls = shortfalls + module.shortfalls
        self.info = info

        // Once through each of its songs in silence, to find how long it is. A tune is what lies
        // before the first end of its list: Scream Tracker played no further, and what a file has
        // after that is whatever was left there.
        let firstPlayedBy = UnsafeMutablePointer<UInt8>.allocate(capacity: module.orders.count * ST2Module.rows)
        firstPlayedBy.initialize(repeating: ModuleSongs.unplayed, count: module.orders.count * ST2Module.rows)
        defer { firstPlayedBy.deallocate() }
        songList = ModuleSongs.find(places: module.listEnd, isPattern: { _ in true }) { start, number in
            let player = ST2Player(module, order: start, firstPlayedBy: firstPlayedBy, songNumber: number)
            // (The first tick comes after a tick's length of nothing.)
            var ticks = 0, frames = Int(player.framesPerTick)
            var watch = ModuleSongs.Watch()
            func heardFrames() -> Int { Int(Int64(frames) * Int64(outputSampleRate) / Int64(ST2Player.mixRate)) }
            while ticks < Self.mostTicks {
                let length = player.runTickInSilence()
                if watch.tick(frames: heardFrames(), playedNote: player.playedNote, ledIntoEarlierSong: player.ledIntoEarlierSong) { break }
                if player.loopCount > 0 { break }
                ticks += 1
                frames += length
            }
            let length = ticks < Self.mostTicks ? Double(frames) / Double(ST2Player.mixRate) : nil
            return ModuleSongs.Pass(played: player.ordersPlayed, length: length, sounded: watch.sounded(player.playedNote), leadIn: watch.leadIn)
        }
        recent = .allocate(capacity: 16)
        sinc = .allocate(capacity: st3Sinc.count)
        for i in 0 ..< st3Sinc.count { sinc[i] = st3Sinc[i] }
        player = ST2Player(module)
        currentSubsong = defaultSubsong
        restart()
    }

    deinit {
        recent.deallocate()
        sinc.deallocate()
    }

    public func select(subsong: Int) {
        currentSubsong = max(0, min(songList.count - 1, subsong))
        restart()
    }

    /// The channels left out of the sound, which a song started afresh is started without.
    private var muted: [Bool] = []

    /// Where the player keeps each channel's sound for its scope, at its own rate, once asked; a
    /// song started afresh keeps it there too.
    private var waves: ChannelWaves?

    public func keepChannelWaves() -> ChannelWaves? {
        if waves == nil {
            waves = ChannelWaves(voices: ST2Module.channels, rate: Double(ST2Player.mixRate), fullSwing: 32)
            player.waves = waves
        }
        return waves
    }

    public func setMuted(_ muted: [Bool]) {
        self.muted = muted
        player.setMuted(muted)
    }

    private func restart() {
        player = ST2Player(module, order: songList[currentSubsong].start)
        player.setMuted(muted)
        player.waves = waves
        for i in 0 ..< 16 { recent[i] = 0 }
        fraction = 0
        ticksSeen = 0
        notes.clear()
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        for n in 0 ..< frames {
            fraction &+= Self.step
            while fraction >= 1 << 32 {
                fraction -= 1 << 32
                for i in 0 ..< 15 { recent[i] = recent[i + 1] }
                recent[15] = Float(Int(player.renderSample()) - 128) * (Self.gain / 128)
                if player.ticks != ticksSeen {
                    ticksSeen = player.ticks
                    player.takeNotes(into: &notes)
                }
            }
            let fraction32 = UInt32(truncatingIfNeeded: fraction)
            let phase = Int(fraction32 >> 24)
            let between = Float(Int32(fraction32 & 0xFF_FFFF)) * (1.0 / 16_777_216.0)
            let sinc1 = sinc + (phase << 4), sinc2 = sinc + ((phase + 1) << 4)
            var sum: Float = 0
            for i in 0 ..< 16 {
                let y1 = sinc1[i], y2 = sinc2[i]
                sum += recent[i] * (y1 + (y2 - y1) * between)
            }
            buffer[n * 2] = sum
            buffer[n * 2 + 1] = sum
        }
    }

    /// The tune from its start as st2play makes it: a sample for each of Scream Tracker's own, at
    /// its own rate, from 0 to 255 with silence at 128. For comparing the two.
    public func renderRaw(frames: Int) -> [Int16] {
        guard let module = try? ST2Module(data, asST2Play: true) else { return [] }
        let player = ST2Player(module)
        player.setMuted(muted)
        return (0 ..< frames).map { _ in Int16(player.renderSample()) }
    }

    public var channelCount: Int { ST2Module.channels }

    /// What the channels have put out since this was last asked, sample by sample as the player
    /// makes them: what has been heard.
    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        player.takeLevels(into: levels)
    }

    public func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        notes.take(pitches: pitches, struck: struck)
    }

    /// Every voice plays samples.
    public var channelsAreSampled: Bool { true }

    public func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        for channel in 0 ..< ST2Module.channels { sides[channel] = 0 }
    }
}
