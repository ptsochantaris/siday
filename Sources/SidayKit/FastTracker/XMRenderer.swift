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
///
/// And it plays the modules of three trackers that this player has no replayer for, MultiTracker,
/// Digital Tracker and DSMI, each read by a loader of its own into what FastTracker plays (see
/// `ForeignModule`). Those have a place between the speakers for each channel, and keep it.
public final class XMRenderer: Renderer, ReferenceComparable {
    public private(set) var info: TuneInfo
    public private(set) var loopCount = 0
    public var subsongCount: Int { songList.count }
    public private(set) var currentSubsong = 0
    public var defaultSubsong: Int { ModuleSongs.first(of: songList.map { $0.empty }) }
    public var songs: [SongInfo] { songList.map { SongInfo(length: $0.length, empty: $0.empty) } }
    public var knownLength: Double? { songList[currentSubsong].length }
    public var endsByLooping: Bool { true }
    /// A song that stops itself, or runs off the end of the list into another: see `FT2Player.over`.
    public var hasEnded: Bool { player.stopped || player.over }

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
    static let gain: Float = 1.0 / (256.0 * 32768.0) * 1.6
    /// And for the tune being played, which for another tracker's kind of module is that with the
    /// kind's own loudness in it (see `ForeignModule.loudness`).
    private let level: Float

    public convenience init(_ data: [UInt8], options: LoadOptions) throws {
        self.init(try FT2Module(data), options: options)
    }

    init(_ module: FT2Module, options: LoadOptions) {
        self.module = module
        mono = options.stereo == .mono
        // (And for a file of ModPlug Tracker's or OpenMPT's, as much louder or quieter as OpenMPT plays it.)
        level = Self.gain * (module.foreign?.loudness ?? 1) * module.openMPTLevel
        var info = TuneInfo(format: module.foreign?.format ?? (module.isMOD ? "MOD" : "XM"))
        info.title = module.title
        info.detail = "\(module.foreign?.tracker ?? "FastTracker 2"), \(module.song.antChn) channels"
        info.shortfalls = module.shortfalls
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

    /// The channels left out of the sound, which a song started afresh is started without.
    private var muted: [Bool] = []

    public func setMuted(_ muted: [Bool]) {
        self.muted = muted
        player.setMuted(muted)
    }

    /// - Parameter asFastTracker: as the player this is ported from plays the file, for `renderRaw`.
    private func restart(asFastTracker: Bool = false) {
        let song = songList[currentSubsong]
        player = FT2Player(module, position: song.start, firstPlayedBy: firstPlayedBy, songNumber: song.number, asFastTracker: asFastTracker)
        player.stereoOutput = !mono
        if !asFastTracker { player.playsPlugIns() }
        player.setMuted(muted)
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
                    let both = (Float(source[i * 2]) + Float(source[i * 2 + 1])) * (level * 0.5)
                    buffer[(done + i) * 2] = both
                    buffer[(done + i) * 2 + 1] = both
                }
            } else {
                for i in 0 ..< count {
                    buffer[(done + i) * 2] = Float(source[i * 2]) * level
                    buffer[(done + i) * 2 + 1] = Float(source[i * 2 + 1]) * level
                }
            }
            tickPosition += count
            done += count
        }
    }

    public var channelCount: Int { Int(module.song.antChn) }

    /// Every voice plays samples.
    public var channelsAreSampled: Bool { true }

    public func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        // Where each channel's note is, with what its instrument's envelope does to that.
        for channel in 0 ..< channelCount {
            sides[channel] = max(-1, min(1, (Float(player.stm[channel].finalPan) - 128) / 127))
        }
    }

    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        player.levels.take(into: levels)
    }

    public func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        player.notes.take(pitches: pitches, struck: struck)
    }

    /// The tune from its start as the reference player writes it to a file: sixteen bits, left and
    /// right in turn, clipped where it is too loud for them. For comparing the two.
    public func renderRaw(frames: Int) -> [Int16] {
        // (That player has a sample in stereo as FastTracker has it: one side after the other.)
        module.playStereoSamples(asFastTracker: true)
        defer {
            module.playStereoSamples(asFastTracker: false)
            restart()
        }
        restart(asFastTracker: true)
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
        return output
    }

    /// What was read from the file, as text: for setting beside what another player made of it.
    /// A line for the song, its order and where its channels are; a line for each instrument (its
    /// length and its repeat in bytes, its bits, volume, fine tuning, the semitones its notes are
    /// moved by, its rate, and two sums of its bytes, of all of them and of all but the last two;
    /// and for each pattern a line for each note that is not empty: pattern, row and channel, then
    /// the note, the instrument, the volume column, and the command and its value.
    public func listing() -> String {
        let song = module.song
        var text = "format \(info.format)\n"
        text += "channels \(song.antChn) speed \(song.tempo) bpm \(song.speed) length \(song.len) restart \(song.repS)"
        text += " undo \(module.speedAndTempoUndoEachOther ? 1 : 0) linear \(module.linearFrqTab ? 1 : 0)\n"
        text += "orders" + song.songTab[0 ..< Int(song.len)].map { " \($0)" }.joined() + "\n"
        text += "pans" + module.channelPanning.map { " \($0)" }.joined() + "\n"
        // (How OpenMPT adds it up, for a file of ModPlug Tracker's or OpenMPT's: see `FT2Module.openMPTMix`.)
        if let mix = module.openMPTMix { text += "mix \(mix.mode) preamp \(mix.preAmp) channels \(mix.channels)\n" }
        for (number, instrument) in module.instr.enumerated() where number > 0 {
            guard let instrument, let bytes = instrument.samp[0].pek else { continue }
            let s = instrument.samp[0]
            var sum: UInt32 = 0, shorter: UInt32 = 0
            // (The sample after the end of a repeat is left out: FastTracker has written over it,
            // for the mixer to find the start of the repeat there.)
            let changed = s.typ & 3 != 0 ? Int(s.repS + s.repL) ..< Int(s.repS + s.repL) + (s.typ & 16 != 0 ? 2 : 1) : -1 ..< -1
            for i in 0 ..< Int(s.len) {
                if i == Int(s.len) - 2 { shorter = sum }
                sum = sum &* 31 &+ (changed.contains(i) ? 0 : UInt32(bytes.load(fromByteOffset: i, as: UInt8.self)))
            }
            text += "ins \(number) len \(s.len) reps \(s.repS) repl \(s.repL) loop \(s.typ & 3) bits \(s.typ & 16 != 0 ? 16 : 8) vol \(s.vol)"
            text += " fine \(s.fine) rel \(s.relTon) rate \(s.rate == 0 ? 8363 : s.rate) pan \(s.pan) sum \(sum) \(shorter)\n"
        }
        let channels = Int(song.antChn)
        for (number, pattern) in module.patt.enumerated() {
            guard let pattern else { continue }
            text += "pattern \(number) rows \(module.pattLens[number])\n"
            for (i, note) in pattern.enumerated() where note.ton != 0 || note.instr != 0 || note.vol != 0 || note.effTyp != 0 || note.eff != 0 {
                text += "\(number) \(i / channels) \(i % channels): t\(note.ton) i\(note.instr) v\(note.vol) e\(note.effTyp):\(note.eff)\n"
            }
        }
        return text
    }
}
