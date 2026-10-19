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
        func long(_ at: Int) -> Int {
            at + 4 <= data.count ? Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3]) : 0
        }
        var at = 20
        for _ in sizes {
            if long(at) & 0xC000_0000 == 0xC000_0000 { at += 4 }
            at += 4
        }
        guard at + 8 <= data.count, long(at) & 0x3FFF_FFFF == 0x3E9 else { return nil }
        let bytes = min(long(at + 4) * 4, data.count - at - 8)
        return data[(at + 8) ..< (at + 8 + bytes)]
    }

    init(_ data: [UInt8], song: Int = 0, name: String = "custom") throws(TuneError) {
        var refusal: TuneError?
        let host: DeliTrackerHost
        do throws(TuneError) {
            guard Self.isOne(data) else { throw TuneError.malformed("not a DeliTracker custom module") }
            host = try DeliTrackerHost(player: data, name: name)
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
        lengths = [UInt64??](repeating: nil, count: count)
        // (Refused only once it is all made.)
        if let refusal { throw refusal }
        try select(song: song >= 0 && song < count ? song : 0)
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
        return info
    }

    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { ticks.tickClocks }

    /// What Paula's registers held as the tick began (see `AmigaPaulaFeed`).
    func period(_ voice: Int) -> UInt16 { ticks.feed.periods[voice] }
    func volume(_ voice: Int) -> UInt16 { ticks.feed.volumes[voice] }
    var lightFilter: Bool { ticks.feed.lightFilter }
}
