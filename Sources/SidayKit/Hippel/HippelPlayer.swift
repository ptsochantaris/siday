// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A port of libtfmxaudiodecoder's player of Jochen Hippel's TFMX and of Future Composer (src/Jochen/),
// Copyright (C) Michael Schwendt, used under the GPL-2.0-or-later, as it is at its commit dcec102 of
// 2026-09-26.

/// Which of Jochen Hippel's formats, or of those made from his player, a module is.
enum HippelFormat: Sendable, Equatable {
    /// Future Composer 1.0 to 1.3 ("SMOD"), with its 47 waveforms built in.
    case futureComposer10
    /// Future Composer 1.4 ("FC14"), with 80 waveforms of the module's own.
    case futureComposer14
    case tfmx
    /// TFMX compressed ("COSO").
    case compressedTFMX
    /// TFMX 7V: three voices of Paula's four as they are, and four more mixed onto the fourth.
    case tfmx7V
    case compressedTFMX7V
    case mcmd

    /// The name libtfmxaudiodecoder gives it (which is the same for both kinds of TFMX 7V).
    var libraryName: String {
        switch self {
        case .futureComposer10: "Future Composer 1.0-1.3 (AMIGA)"
        case .futureComposer14: "Future Composer 1.4 (AMIGA)"
        case .tfmx: "TFMX/Hippel (AMIGA)"
        case .compressedTFMX: "Compressed TFMX/Hippel (AMIGA)"
        case .tfmx7V, .compressedTFMX7V: "TFMX 7V/Hippel (AMIGA)"
        case .mcmd: "MCMD (AMIGA)"
        }
    }

    var isSevenVoices: Bool { self == .tfmx7V || self == .compressedTFMX7V }
}

/// Jochen Hippel's music (from 1987 to the early 1990s, for Thalion's and others' games on the Amiga and
/// the Atari ST), and Future Composer's and MCMD's, the trackers made from his player. A song is a
/// table of steps, each giving each voice a pattern and its transposes; a pattern's notes each start an
/// instrument, whose volume sequence is run on every tick for the volume, and whose sound sequence for
/// the waves Paula plays and the note's transposes, which vibrato and portamento then bend.
///
/// This is libtfmxaudiodecoder's player of them, line for line: what it tells Paula, tick by tick, is
/// the same as that library's for every song of every module of UnExoticA's collection. It owns the
/// memory Paula plays from: the module, the eight bytes of silence the library puts after it, room, and
/// Future Composer 1.0 to 1.3's built-in waveforms.
///
/// What it tells Paula is through `TFMXOutput`, as for Chris Hülsbeck's TFMX: its volumes are 0 to 64 for
/// a sensible module, but a TFMX 7V voice's random volume can make up to 127 (the library's mixer takes
/// a volume to a byte and keeps it to 64). For TFMX 7V, voices 3 to 6 are the four mixed onto Paula's
/// fourth: the library has no buffer of its own for them, its mixer adding the four voices' samples, each
/// at its volume, at every sample it makes, and playing the sum, clipped, at full volume. A voice is never
/// told to play from outside the memory up to `memoryCapacity`.
struct HippelPlayer: ~Copyable {
    /// The module and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    /// How many bytes of `memory` are the module's (not counting the eight of silence after them).
    var memorySize: Int { decoder.length }
    /// Where Paula starts a voice that has not been told where to: the silence after the module (from
    /// its second byte, seven noughts).
    var silenceAt: Int { decoder.length + 1 }
    /// Where, after the module, there is room for buffers to mix TFMX 7V's four voices into for Paula's
    /// fourth: far enough after it that no voice told a start in the module and a length, however long,
    /// reads into them, only silence (which is what is there).
    var mixingAt: Int { file.count + HippelDecoder.silenceData.count + 0x20000 }
    static let mixingSpace = 2048
    /// Where Future Composer 1.0 to 1.3's waveforms are, after the room for mixing.
    var wavesAt: Int { mixingAt + Self.mixingSpace }
    /// How many bytes Paula may read of `memory`: the module, its silence, the room after it, the mixing
    /// and the waveforms.
    let memoryCapacity: Int

    private(set) var decoder: HippelDecoder
    private let file: [UInt8]
    private var requestedSong = 0

    /// True for a file in which libtfmxaudiodecoder's `detect` finds a module of these formats where
    /// it can read it (it also takes files that are no more than one of the players' code, which it
    /// then cannot read: those are not taken here). Whether one is played is known only once it is read.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard let probe = HippelDecoder.probe(data) else { return false }
        return probe.header != 0xFFFF_FFFF
    }

    /// Reads the module and starts its song `song` (counting from nought; one beyond the last is the
    /// first).
    init(_ file: [UInt8], song: Int = 0) throws(TuneError) {
        memoryCapacity = file.count + HippelDecoder.silenceData.count + 0x20000 + Self.mixingSpace + HippelTables.smodWaveforms.count
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        self.file = file
        decoder = HippelDecoder(memory: memory, wavesAt: memoryCapacity - HippelTables.smodWaveforms.count)
        try start(song)
    }

    deinit { memory.deallocate() }

    private mutating func start(_ song: Int) throws(TuneError) {
        memory.update(repeating: 0, count: memoryCapacity)
        for (i, b) in HippelTables.smodWaveforms.enumerated() { memory[wavesAt + i] = b }
        let loops = decoder.loopMode
        decoder = HippelDecoder(memory: memory, wavesAt: wavesAt)
        decoder.loopMode = loops
        requestedSong = song
        try decoder.setUp(file, song: song)
    }

    /// Starts song `song` afresh: the module is read again, as a new player would read it.
    mutating func select(song: Int) throws(TuneError) { try start(song) }

    /// Runs the player for one tick, telling `output` what Paula is to do. Returns the tick's length in
    /// milliseconds, rounded down, the part of a millisecond left over being carried to the next.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int { decoder.run(&output) }

    /// Starts the song from its beginning again, as the library's `restart` does: the voices are
    /// stopped and set to silence, but what the song last set the rate to is kept.
    mutating func restart<Output: TFMXOutput>(_ output: inout Output) {
        decoder.restart(&output)
        decoder.endings = 0
        decoder.stops = 0
    }

    /// How many songs the module has (one at least: the library counts none for Future Composer and
    /// MCMD, which have one).
    var songCount: Int { max(1, decoder.vSongs.count) }
    /// The song playing, counting from nought.
    var song: Int { requestedSong }
    /// Four, or seven for TFMX 7V.
    var voiceCount: Int { decoder.stats.voices }
    var format: HippelFormat { decoder.format }
    /// How often the player runs: ticks a second, times 256. It is fifty ticks a second, but for TFMX 7V,
    /// whose song sets it, at its start and as it plays (from 33.4 to 100 ticks a second).
    var rate: UInt32 { decoder.rate }
    /// True once the song has come to its end, after which the player does nothing more but keep the
    /// voices' volumes at nought. (A song that is looped plays on instead, and does not end.)
    var songEnded: Bool { decoder.songEnd }
    /// Whether the song plays on when it ends. Off unless set; kept from song to song.
    var loops: Bool {
        get { decoder.loopMode }
        set { decoder.loopMode = newValue }
    }
    /// How long the song plays before it ends, in milliseconds, as the player found by playing it
    /// through once before it began (up to 59 minutes, for a song that does not end).
    var duration: UInt32 { decoder.duration }
    /// How many times the song has come to its end since it was started: the end of its steps, where it
    /// goes round, or a command to stop (ST $80, or a step's command $8x), counted in `stops`. In loop
    /// mode the library plays on after either, a stop as if it had not been told to stop.
    var endings: Int { decoder.endings }
    var stops: Int { decoder.stops }
    /// Paula's period for the voice, as the player last set it.
    func period(_ voice: Int) -> UInt16 { decoder.paula[voice].period }
    /// Paula's volume for the voice, as the player last set it (see the type's description).
    func volume(_ voice: Int) -> UInt16 { decoder.paula[voice].volume }
}
