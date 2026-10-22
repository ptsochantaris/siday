// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after UADE's playing of DeliTracker's custom modules: its `custom` player, which is the module
// itself, run by its host `score` (amigasrc/score/score.s), as `DeliTrackerHost` runs it.

/// A DeliTracker custom module: music that is its own player, an AmigaDOS program made by whoever took it
/// from the game (as a rule, its composer's own code and music with DeliTracker's interface put round
/// them). It is run on an emulated Amiga by a host that does as DeliTracker does, as UADE's does
/// (`DeliTrackerHost`), and what it writes to Paula is heard at the moment it writes it.
///
/// Its songs are those of the range it gives (`DTP_SubSongRange`), the first of them first. A song ends
/// when the module says so (`dtg_SongEnd`); each one's length is found by playing it through in silence.
/// The ticks it is heard by are those of its own timer (`DeliTicks`): CIA-A's timer B, which the host
/// calls its `DTP_Interrupt` from (fifty times a second unless it sets another), or for a module that
/// sets its own interrupts going, the frames.
struct DeliCustomPlayer: ~Copyable {
    private var host: DeliTrackerHost
    private var ticks: DeliTicks
    private let first: Int
    let songCount: Int

    private(set) var song = 0
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    private var lengths: [UInt64??]
    private let title: String

    /// How long a song is played through to find its end, at most: ten minutes, which is longer than
    /// UADE plays a song that does not end (512 seconds).
    static let mostClocks: UInt64 = 600 * 3_546_895
    /// The processor's time (not waiting) a song's playing through in silence is given, and all of a
    /// module's songs': no more, for a module that is broken or busy.
    static let dryRunBudget: Int64 = 1_200_000_000
    static let dryRunsBudget: Int64 = 6_000_000_000
    private var dryRuns: Int64 = 0
    /// Whether the module's code calls DeliTracker's `dtg_SongEnd` (or EaglePlayer's), as far as can be
    /// seen by looking (`callsSongEnd`); whether any of its songs has been found to end; and whether one
    /// has been played to `mostClocks` without ending. A module that does not call it, of which no song
    /// has ended and one has been played that long, is taken to have no songs that end, and the rest are
    /// not played through to find out: most customs never tell DeliTracker, and one of seventy songs
    /// would otherwise take more than a minute to load. (In UnExoticA's collection this leaves one song
    /// without the length it has, Lemmings' seventh, which stops after 3:52.)
    private let callsSongEnd: Bool
    private var anyEnded = false
    private var anyRanOut = false

    var memory: UnsafeMutablePointer<UInt8> { host.memory }
    var memoryCapacity: Int { host.memorySize }
    var silenceAt: Int { host.memorySize - DeliTrackerHost.room / 2 - 1024 }
    var mixingAt: Int { silenceAt }
    /// What the tick just run wrote (see `DeliTicks`), and the song's start.
    var writes: [AmigaWrite] { ticks.writes }
    var startWrites: [AmigaWrite] { ticks.startWrites }
    var tickClocks: Int { ticks.tickClocks }
    var lead: Int { ticks.lead }

    /// True for an AmigaDOS program that is a DeliTracker player (its first hunk begins `MOVEQ #-1,D0;
    /// RTS` and "DELIRIUM") that says it is a custom module (the tag DTP_CustomPlayer, among the longs
    /// of its first hunk).
    static func isOne(_ data: [UInt8]) -> Bool {
        guard let hunk = firstHunk(data), hunk.count >= 16 else { return false }
        guard Array(hunk[hunk.startIndex ..< hunk.startIndex + 12]) == [0x70, 0xFF, 0x4E, 0x75, 0x44, 0x45, 0x4C, 0x49, 0x52, 0x49, 0x55, 0x4D] else {
            return false
        }
        var at = hunk.startIndex + 16
        while at + 8 <= hunk.endIndex {
            if hunk[at] == 0x80, hunk[at + 1] == 0x00, hunk[at + 2] == 0x44, hunk[at + 3] == 0x55 { return true }
            at += 2
        }
        return false
    }

    /// The bytes of the program's first hunk, as they are in the file.
    private static func firstHunk(_ data: [UInt8]) -> ArraySlice<UInt8>? {
        guard AmigaHunks.isOne(data), let sizes = try? AmigaHunks.sizes(data), !sizes.isEmpty else { return nil }
        func long(_ at: Int) -> UInt32 {
            at + 4 <= data.count ? UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3]) : 0
        }
        var at = 20
        for _ in sizes {
            if long(at) & 0xC000_0000 == 0xC000_0000 { at += 4 }
            at += 4
        }
        guard at + 8 <= data.count, long(at) & 0x3FFF_FFFF == 0x3E9 else { return nil }
        let bytes = Int(min(UInt64(long(at + 4)) * 4, UInt64(data.count - at - 8)))
        return data[(at + 8) ..< (at + 8 + bytes)]
    }

    /// - Parameter files: files the module loads from beside it, by their names (a few do: Nebulus 2's
    ///   loading music its instruments from "instr/", Lemmings' older custom its songs and instruments
    ///   from "songs/" and "instruments/"); found by the last part of the name the module asks for.
    init(_ data: [UInt8], song: Int = 0, name: String = "custom", files: [(name: String, bytes: [UInt8])] = []) throws(TuneError) {
        var refusal: TuneError?
        let host: DeliTrackerHost
        do throws(TuneError) {
            guard Self.isOne(data) else { throw TuneError.malformed("not a DeliTracker custom module") }
            host = try DeliTrackerHost(player: data, name: name, files: files)
        } catch {
            refusal = error
            host = try! DeliTrackerHost(moduleAt: 0x10000, module: [])
        }
        self.host = host
        ticks = DeliTicks(memorySize: self.host.memorySize)
        var first = 0, count = 1, title = ""
        if refusal == nil {
            do {
                try self.host.start(song: nil)
                first = self.host.firstSong
                count = max(1, min(256, self.host.lastSong - self.host.firstSong + 1))
                title = self.host.namedModule
            } catch {
                refusal = error
            }
        }
        self.first = first
        songCount = count
        self.title = title
        callsSongEnd = Self.callsSongEnd(data)
        lengths = [UInt64??](repeating: nil, count: count)
        // (Refused only once it is all made.)
        if let refusal { throw refusal }
        try select(song: song >= 0 && song < count ? song : 0)
    }

    /// True if the module has an instruction that reaches `dtg_SongEnd` in the globals it is given (a
    /// `MOVE` or `MOVEA` from it, or a `JSR` through it, at its offset from an address register), or a
    /// `JSR` to EaglePlayer's `ENPP_SongEnd`. Any word of the file is looked at, so it may say yes for
    /// one that does not; it says no only for a module that cannot call it in these ways.
    static func callsSongEnd(_ data: [UInt8]) -> Bool {
        var at = 0
        while at + 3 < data.count {
            let word = UInt16(data[at]) << 8 | UInt16(data[at + 1])
            let offset = UInt16(data[at + 2]) << 8 | UInt16(data[at + 3])
            if offset == UInt16(DeliTrackerHost.dtgSongEnd), word >> 12 == 2 || word >> 12 == 3, (word >> 3) & 7 == 5 { return true }
            if offset == UInt16(DeliTrackerHost.dtgSongEnd), word & 0xFFF8 == 0x4EA8 { return true }
            if offset == UInt16(bitPattern: Int16(DeliTrackerHost.enppSongEnd)), word & 0xFFF8 == 0x4EA8 { return true }
            at += 2
        }
        return false
    }

    /// Starts a song afresh, as UADE does: the machine switched on and the module started by its host.
    private mutating func start(_ song: Int) throws(TuneError) {
        try host.start(song: first + song)
        endings = 0
        stops = 0
        ticks.begin(&host)
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        if lengths[song] == nil, !callsSongEnd, anyRanOut, !anyEnded { lengths[song] = .some(nil) }
        if lengths[song] == nil {
            // Played through in silence to its end: the tick it ends in is the first of it again, or the
            // first of the silence after it.
            try start(song)
            var none = Unheard()
            var used: Int64 = 0
            var clocks: UInt64 = 0
            while endings == 0, stops == 0, clocks < Self.mostClocks, used < Self.dryRunBudget, dryRuns < Self.dryRunsBudget {
                let busy = host.busyCycles
                _ = run(&none)
                clocks += UInt64(ticks.tickClocks)
                used += host.busyCycles - busy
                dryRuns += host.busyCycles - busy
            }
            lengths[song] = .some(endings > 0 || stops > 0 ? clocks - UInt64(ticks.tickClocks) : nil)
            if endings > 0 || stops > 0 { anyEnded = true } else if clocks >= Self.mostClocks { anyRanOut = true }
        }
        lengthClocks = lengths[song] ?? nil
        try start(song)
    }

    /// Runs a tick: the machine run as the Amiga runs until the module's next tick is due, and what it
    /// wrote told `output` at the moments it wrote it. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        if stops > 0 {
            ticks.idle()
            return 20
        }
        let (failed, ends) = ticks.run(&host, &output)
        if failed { stops += 1 }
        endings += ends
        return ticks.tickClocks * 1000 / 3_546_895
    }

    /// Why the module stopped, if it has.
    var failure: String? { host.failure }

    private struct Unheard: TFMXOutput {
        mutating func on(_: Int) {}
        mutating func off(_: Int) {}
        mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
        func loopCount(_: Int) -> UInt16 { 0 }
    }
}

/// A DeliTracker custom module, played on Paula by `PaulaTickRenderer`.
extension DeliCustomPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "DeliTracker custom")
        info.title = title
        let player = host.playerName
        if player != "CustomPlay", player != "Custom Player" { info.detail = player }
        for file in host.missing {
            info.shortfalls.append("It loads \(file) from beside it, which was not given, and plays without it.")
        }
        return info
    }

    /// DeliTracker's custom modules' music is louder on the Amiga's chip than ProTracker's is, by 3.4 dB in the middle of
    /// UnExoticA's 345 files that play, and is turned down by that (2026-10-19).
    var gain: Float { 0.31 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { ticks.tickClocks }

    /// What Paula's registers held as the tick began (see `AmigaPaulaFeed`).
    func period(_ voice: Int) -> UInt16 { ticks.feed.periods[voice] }
    func volume(_ voice: Int) -> UInt16 { ticks.feed.volumes[voice] }
    var lightFilter: Bool { ticks.feed.lightFilter }
}
