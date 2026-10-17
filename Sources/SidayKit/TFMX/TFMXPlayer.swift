// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A port of libtfmxaudiodecoder's player of TFMX (src/Chris/), Copyright (C) Michael Schwendt, used
// under the GPL-2.0-or-later, as it is at its commit dcec102 of 2026-09-26.

/// What the TFMX player plays through: Paula's registers for each voice. (For the seven voices of TFMX
/// 7V, voices 3 to 6 are mixed onto Paula's fourth by whoever plays them.)
///
/// The period and the volume of each voice are not told: they are read from the player after each
/// tick (`TFMXPlayer.period(_:)` and `volume(_:)`), as libtfmxaudiodecoder's mixer reads them.
protocol TFMXOutput {
    /// DMA on: a voice that is not playing starts at what it was last given; one playing goes on.
    mutating func on(_ voice: Int)
    mutating func off(_ voice: Int)
    /// Paula's location (an offset into the player's memory) and length in words, as last given:
    /// told every time either is set, as libtfmxaudiodecoder calls its voice's `takeNextBuf`. A voice
    /// that is not playing takes them as where to start; one that is, as where to go on from when it
    /// comes to the end of what it is playing.
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16)
    /// How many times the voice has come to the end of what it was playing and gone round again, since
    /// it was last started; nought for one that is not playing.
    func loopCount(_ voice: Int) -> UInt16
}

/// Which TFMX a module is played as: its player's version, from the module's header, a mark of the
/// file's, a checksum of a few known modules, or its using seven voices.
enum TFMXFormat: Sendable, Equatable {
    /// TFMX 1.5 and 2.2, and the versions of the player a few early games had.
    case tfmx
    /// TFMX Professional, and the later players like it.
    case pro
    /// TFMX 7V: three voices of Paula's four as they are, and four more mixed onto the fourth.
    case sevenVoices

    var name: String {
        switch self {
        case .tfmx: "TFMX"
        case .pro: "TFMX Pro"
        case .sevenVoices: "TFMX 7V"
        }
    }
}

/// Chris Hülsbeck's TFMX ("The Final Musicsystem eXtended", from the late 1980s), the music system of
/// Turrican and of many other games: a module's notes and instruments in one file, its samples in
/// another. A song is a table of steps, each giving eight tracks a pattern to play and a voice to play
/// it on; a pattern's notes each start a macro, the instrument, a short program run on every tick that
/// tells Paula where to play from and how long, and sets the period and the volume, which the player's
/// effects then bend.
///
/// This is libtfmxaudiodecoder's player of it, line for line: what it tells Paula, tick by tick, is the
/// same as that library's for every song of every module of UnExoticA's collection (given the same
/// chances for random play, which two of Masterblazer's modules use: see `TFMXDecoder.randomState`).
/// It owns the memory Paula plays from, the module and its samples laid out as that library lays them
/// out, which a few instruments write sounds of their own making into as they play.
struct TFMXPlayer: ~Copyable {
    /// The module and its samples, as Paula reads them, and after them four bytes of silence: Paula's
    /// starting place before a song has told her one (`silenceAt`).
    let memory: UnsafeMutablePointer<UInt8>
    /// How many bytes of `memory` are the module's (not counting the four of silence after them).
    var memorySize: Int { decoder.size }
    /// Where Paula starts a voice that has not been told where to: four bytes of nought after the
    /// module, as libtfmxaudiodecoder's mixer starts its voices at four of its own. (A voice told only
    /// a length after that plays on past them, out of the memory, as that mixer's does: what is read
    /// beyond `memorySize + 4` is best taken to be silence.)
    var silenceAt: Int { decoder.size }

    private var decoder: TFMXDecoder
    private let file: [UInt8]
    private let samples: [UInt8]?

    /// True for a file that begins as a TFMX module does (as libtfmxaudiodecoder's `detect` tells):
    /// whether it is one is known only once it is read.
    static func isOne(_ data: [UInt8]) -> Bool { TFMXDecoder.isOne(data) }

    /// Reads the module and starts its song `song` (counting from nought; a song beyond the last is
    /// the first). `samples` is the samples file's bytes, or nil for none; a module that keeps its samples
    /// in its own file has no need of them (and is not given them: they would be left unread).
    init(_ file: [UInt8], samples: [UInt8]?, song: Int = 0) throws(TuneError) {
        let size = file.count + (samples?.count ?? 0)
        memory = .allocate(capacity: size + 4)
        memory.initialize(repeating: 0, count: size + 4)
        self.file = file
        self.samples = samples
        decoder = TFMXDecoder(memory: memory)
        try decoder.setUp(file, samples: samples, song: song)
    }

    deinit { memory.deallocate() }

    /// Starts song `song` afresh: the module is read again, as a new player would read it.
    /// (Whether a module is played does not hang on which of its songs is asked for, so one that was
    /// read once is read again.)
    mutating func select(song: Int) throws(TuneError) {
        memory.update(repeating: 0, count: file.count + (samples?.count ?? 0) + 4)
        decoder = TFMXDecoder(memory: memory)
        try decoder.setUp(file, samples: samples, song: song)
    }

    /// Runs the player for one tick, telling `output` what Paula is to do. Returns the tick's length in
    /// milliseconds, rounded down, the part of a millisecond left over being carried to the next.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int { decoder.run(&output) }

    /// Starts the song from its beginning again, as it was when it was selected.
    mutating func restart<Output: TFMXOutput>(_ output: inout Output) { decoder.restart(&output) }

    /// How many songs the module has (one at least).
    var songCount: Int { decoder.songs.count }
    /// The song playing, counting from nought.
    var song: Int { decoder.admin.startSong }
    /// Four, or eight for TFMX 7V.
    var voiceCount: Int { decoder.voiceCount }
    var format: TFMXFormat { decoder.format }
    /// How often the player runs: ticks a second, times 256. It may change as the song plays.
    var rate: UInt32 { decoder.rate }
    /// True once the song has come to its end, after which the player does nothing more. (A song that
    /// is looped goes back to its beginning instead, and does not end.)
    var songEnded: Bool { decoder.songEnd }
    /// Whether the song goes back to its beginning when it ends. Off unless set.
    var loops: Bool {
        get { decoder.loopMode }
        set { decoder.loopMode = newValue }
    }
    /// How long the song plays before it ends, in milliseconds, as the player found by playing it
    /// through once before it began (up to 59 minutes, for a song that does not end).
    var duration: UInt32 { decoder.duration }
    /// Paula's period for the voice, as the player last set it.
    func period(_ voice: Int) -> UInt16 { decoder.paula[voice].period }
    /// Paula's volume for the voice, as the player last set it: 0 to 64 for any sensible module, though
    /// it is set as the player has it, and a module may make it more.
    func volume(_ voice: Int) -> UInt16 { decoder.paula[voice].volume }
    /// The module's title, composer and game, for a TFMX-MOD file, which may say them; empty otherwise.
    var title: String { String(decoding: decoder.title, as: UTF8.self) }
    var author: String { String(decoding: decoder.author, as: UTF8.self) }
    var game: String { String(decoding: decoder.game, as: UTF8.self) }
}
