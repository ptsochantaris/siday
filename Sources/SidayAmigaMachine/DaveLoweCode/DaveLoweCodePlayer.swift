// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Dave Lowe's music ("Dave Lowe player module V1.2 (9 June
// 2001)", whose source UADE carries as players/wanted_team/DaveLowe/src/Dave Lowe_v3.asm), run by UADE's
// host as `DeliTrackerHost` runs it. The addresses given are of that player's code hunk, as its file in
// UADE (players/DaveLowe) has them.

import SidayChips
import SidayFoundation

/// Dave Lowe's music for the Amiga as Wanted Team adapted it: each module the 68000 code he wrote to play
/// it, as one hunk of an AmigaDOS program, with the music and the samples after it. It begins `MOVEQ
/// #-1,D0; RTS` and "UNCLEART" (for Uncle Art, Dave Lowe's company), then the addresses of its routines:
/// to start a song, to play a tick, to stop, the word that says which song, and more. (His later
/// music, which is data for one player, is `DaveLowePlayer`'s.)
///
/// It is played as UADE plays it with Wanted Team's player: the module loaded by the host's LoadSeg and
/// its code changed as the player changes it (`patch`), the song number put in its word and its start
/// called, and its routine for a tick called fifty times a second, from CIA-A's timer B, by the host.
/// A song ends when every voice has come to the end of its list of patterns twice (the player's
/// `SongEndTest`, as its patches call it), and its length is found by playing it through in silence.
struct DaveLoweCodePlayer: ~Copyable {
    private var host: DeliTrackerHost
    private var ticks: DeliTicks
    private(set) var songCount = 1
    /// What the module says of itself: its song's name and its author's.
    private(set) var title = ""
    private(set) var author = ""

    private(set) var song = 0
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    private var lengths: [UInt64??] = []
    private var dryRuns: Int64 = 0

    /// Where UADE puts the module: past Wanted Team's player, whose file is 2,832 bytes and whose hunk
    /// is 2,664 (`uadecore_reset`: the player relocated from $D000, the module 8 KB past the page its
    /// hunk ends in).
    static let moduleAt: UInt32 = 0xF000

    var memory: UnsafeMutablePointer<UInt8> { host.memory }
    var memoryCapacity: Int { host.memorySize }
    var silenceAt: Int { host.memorySize - DeliTrackerHost.room / 2 - 1024 }
    var mixingAt: Int { silenceAt }
    var writes: [AmigaWrite] { ticks.writes }
    var startWrites: [AmigaWrite] { ticks.startWrites }
    var tickClocks: Int { ticks.tickClocks }
    var lead: Int { ticks.lead }

    /// The player's check (`Check3`): an AmigaDOS program of one hunk, to be loaded into chip memory,
    /// whose code begins `MOVEQ #-1,D0; RTS` and "UNCLEART", and whose routine to start a song, routine
    /// for a tick and word for the song are there.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 60, long(data, 0) == 0x3F3, data[20] != 0, long(data, 32) == 0x70FF_4E75,
              long(data, 36) == 0x554E_434C, long(data, 40) == 0x4541_5254
        else { return false }
        return long(data, 44) != 0 && long(data, 48) != 0 && long(data, 56) != 0
    }

    private static func long(_ data: [UInt8], _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= data.count else { return 0 }
        return UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
    }

    /// What the player found in the module, as its `InitPlayer` reads it after LoadSeg ($52C).
    private struct Layout {
        var module: UInt32 = 0
        var initAt: UInt32 = 0, playAt: UInt32 = 0, endAt: UInt32 = 0, songWord: UInt32 = 0
        var init2At: UInt32 = 0, initPlayerAt: UInt32 = 0, firstSongs: UInt32 = 0, specialFX: UInt32 = 0
        var songName: UInt32 = 0, authorName: UInt32 = 0, loadSize: UInt32 = 0
        var songs = 1
    }

    private var layout = Layout()
    private let code: [UInt8]
    private let entries: Entries

    init(_ data: [UInt8], song: Int = 0, name: String = "module.dl") throws(TuneError) {
        var refusal: TuneError?
        let host: DeliTrackerHost
        do throws(TuneError) {
            guard Self.isOne(data) else { throw TuneError.malformed("not a module of Dave Lowe's") }
            host = try DeliTrackerHost(moduleAt: Self.moduleAt, module: data, name: name)
        } catch {
            refusal = error
            host = try! DeliTrackerHost(moduleAt: Self.moduleAt, module: [])
        }
        self.host = host
        ticks = DeliTicks(memorySize: self.host.memorySize)
        var entries = Entries()
        code = Self.assemble(&entries)
        self.entries = entries
        if refusal == nil {
            do {
                try start(0)
                songCount = layout.songs
                if layout.songName != 0 { title = self.host.string(at: layout.songName, most: 64) }
                if layout.authorName != 0 { author = self.host.string(at: layout.authorName, most: 64) }
            } catch {
                refusal = error
            }
        }
        lengths = [UInt64??](repeating: nil, count: songCount)
        if let refusal { throw refusal }
        try select(song: song >= 0 && song < songCount ? song : 0)
    }

    // MARK: Starting

    /// Starts a song afresh, as UADE does with the player: the machine switched on, the module loaded,
    /// changed and started, and its ticks set going (songs from nought here, from one in the player).
    private mutating func start(_ song: Int) throws(TuneError) {
        try host.prepare()
        host.machine.load(code, at: DeliTrackerHost.clientCode)
        host.startInterrupts()
        try initPlayer()
        host.setSong(song + 1)
        try initSound()
        host.playByTimer(entries.interrupt)
        host.idle()
        endings = 0
        stops = 0
        ticks.begin(&host)
    }

    /// The player's `InitPlayer` ($52C).
    private mutating func initPlayer() throws(TuneError) {
        guard let module = host.loadSegment(host.moduleFileName) else {
            throw .malformed("a module of Dave Lowe's that does not load")
        }
        func long(_ at: UInt32) -> UInt32 { host.machine.peek32(at) }
        var l = Layout()
        l.module = module
        l.initAt = long(module + 12)
        l.playAt = long(module + 16)
        l.endAt = long(module + 20)
        l.songWord = long(module + 24)
        l.init2At = long(module + 36)
        l.initPlayerAt = long(module + 40)
        l.firstSongs = long(module + 44)
        l.songName = long(module + 48)
        l.authorName = long(module + 52)
        l.loadSize = long(module + 60)
        l.specialFX = long(module + 76)
        // The songs: one for each entry of 16 bytes of the list of their first patterns, until one whose
        // first long is less than 256 ($584).
        l.songs = 1
        if l.firstSongs != 0 {
            var at = l.firstSongs
            while l.songs < 256 {
                at &+= 16
                guard Int(at) + 4 <= host.memorySize, long(at) & 0xFFFF_FF00 != 0 else { break }
                l.songs += 1
            }
        }
        // Where the tick's routine writes a voice's volume (MOVE.W D0,8(A2)) and then branches on (BRA.W),
        // the branch made one that the patch for it comes back to ($5BA): from 380 bytes in, the first
        // such write, or the first MOVE.W (A1)+,8(A2), which is International Soccer's and not changed.
        var at = l.playAt &+ 380
        while Int(at) + 8 <= host.memorySize {
            if long(at) == 0x3540_0008 {
                if host.machine.peek16(at + 4) == 0x6000 { host.machine.poke16(at + 6, host.machine.peek16(at + 6) &+ 0x6002) }
                break
            }
            if long(at) == 0x3559_0008 { break }
            at &+= 2
        }
        // Midwinter 2's songs 3, 11 and 13, whose second voice reads its notes from page zero, given the
        // player's own ($5E4).
        if l.loadSize == 77554, l.songs == 17 { midwinter2(l.module) }
        layout = l
        // `ModuleChange` ($1F0): the patches, from the tick's routine to the list of songs (or 900 bytes).
        let g = DeliTrackerHost.globals
        host.machine.poke32(g + DeliTrackerHost.epgArg1, l.playAt)
        host.machine.poke32(g + DeliTrackerHost.epgArg2, l.firstSongs != 0 ? l.firstSongs &- l.playAt : 900)
        host.machine.poke32(g + DeliTrackerHost.epgArg3, entries.patchTable)
        host.machine.poke32(g + DeliTrackerHost.epgArg5, 0xFFFF_FFFE)
        host.machine.poke32(g + DeliTrackerHost.epgArg4, 1)
        host.machine.poke32(g + DeliTrackerHost.epgArgN, 5)
        host.moduleChange()
        // The module's own routine for its start, if it has one.
        if l.initPlayerAt != 0 { _ = try host.call(l.initPlayerAt, with: [(9, l.initPlayerAt)]) }
        // What the player keeps of it.
        host.machine.poke32(entries.eagleBase, g)
        host.machine.poke32(entries.songWordAt, l.songWord)
        host.machine.poke32(entries.specialFX, l.specialFX)
        host.machine.poke32(entries.play, l.playAt)
    }

    /// The player's `InitSound` ($66E): its count of each voice's ends of its list made two to go, the
    /// voice whose list of patterns is longest (in the last song up to this one) taken for its count of
    /// position, the module's second start called if it has one, the song's number put in its word (and,
    /// for its first song, its sound effects' number in the long six bytes before), and its start called.
    private mutating func initSound() throws(TuneError) {
        let l = layout
        let g = DeliTrackerHost.globals
        host.machine.poke32(entries.songEnd, 0xFEFE_FEFE)
        host.machine.poke32(entries.songEnd + 4, 0)
        var hardware: UInt32 = 0x00DF_F0A0
        let song = Int(host.machine.peek16(g + DeliTrackerHost.dtgSndNum))
        if l.firstSongs != 0 {
            var at = l.firstSongs
            for _ in 0 ..< max(1, min(song, 256)) {
                var longest = 0
                for v in 0 ..< 4 {
                    var list = host.machine.peek32(at)
                    var length = 0
                    while length < 0x10000, Int(list) + 4 <= host.memorySize, host.machine.peek32(list) != 0 {
                        length += 1
                        list &+= 4
                    }
                    if length >= longest {
                        longest = length
                        hardware = 0x00DF_F0A0 + UInt32(v * 16)
                    }
                    at &+= 4
                }
            }
        }
        host.machine.poke32(entries.hardware, hardware)
        var d0: UInt32 = 0
        if l.init2At != 0 { d0 = try host.call(l.init2At) }
        host.machine.poke16(l.songWord, UInt16(truncatingIfNeeded: song))
        if l.specialFX != 0, song == 1 { host.machine.poke32(l.songWord &- 6, l.specialFX) }
        // (Its start, jumped to with the song's word in A1 and the effects' number in D1.)
        try host.initSound(l.initAt, with: [(0, d0), (1, l.specialFX), (9, l.songWord)])
    }

    /// The player's patches of Midwinter 2's songs ($5E4): pointers in the module to lists of the
    /// player's own, and those lists' first pattern a place in the module.
    private mutating func midwinter2(_ module: UInt32) {
        let at = entries.midwinter
        for i in 0 ..< 4 { host.machine.poke32(module + 0x2E44 + UInt32(i * 4), at + Self.song03) }
        let place = module + 0x2E54 + 8494
        host.machine.poke32(at + Self.label03, place)
        host.machine.poke32(module + 0x261A, at + Self.song11)
        host.machine.poke32(at + Self.label11A, place)
        host.machine.poke32(at + Self.label11B, place)
        for i in 0 ..< 5 { host.machine.poke32(module + 0x2F6E + UInt32(i * 4), at + Self.song13) }
        host.machine.poke32(at + Self.label13, place)
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        if lengths[song] == nil {
            try start(song)
            var none = Unheard()
            var used: Int64 = 0
            var clocks: UInt64 = 0
            while endings == 0, stops == 0, clocks < DeliCustomPlayer.mostClocks, used < DeliCustomPlayer.dryRunBudget,
                  dryRuns < DeliCustomPlayer.dryRunsBudget
            {
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

    var failure: String? { host.failure }

    private struct Unheard: TFMXOutput {
        mutating func on(_: Int) {}
        mutating func off(_: Int) {}
        mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
        func loopCount(_: Int) -> UInt16 { 0 }
    }

    // MARK: The player's own code

    /// Where the parts of the player's code and data are.
    private struct Entries {
        var interrupt: UInt32 = 0, patchTable: UInt32 = 0, midwinter: UInt32 = 0
        var eagleBase: UInt32 = 0, songWordAt: UInt32 = 0, specialFX: UInt32 = 0, songEnd: UInt32 = 0
        var hardware: UInt32 = 0, play: UInt32 = 0
    }

    /// Wanted Team's lists for Midwinter 2's songs ($95C to $A68 of the player), with the places of its
    /// labels in them and of the two pointers to its lists of notes, `Fiksik_1` and `Fiksik_2`.
    private static let midwinterData: [UInt8] = [
        0x00, 0x0C, 0x00, 0x00, 0x00, 0xE8, 0x00, 0x04, 0x57, 0x54, 0x57, 0x54, 0x01, 0xAC, 0x00, 0x0A,
        0x01, 0x94, 0x00, 0x0A, 0x01, 0xC5, 0x00, 0x0A, 0x01, 0xAC, 0x00, 0x0A, 0x01, 0xAC, 0x00, 0x0A,
        0x01, 0x94, 0x00, 0x0A, 0x01, 0xC5, 0x00, 0x0A, 0x01, 0xAC, 0x00, 0x0A, 0x00, 0x08, 0x00, 0x0C,
        0x00, 0x00, 0x00, 0xE8, 0x00, 0x04, 0x57, 0x54, 0x57, 0x54, 0x01, 0xAC, 0x00, 0x18, 0x01, 0x7D,
        0x00, 0x20, 0x01, 0x68, 0x00, 0x20, 0x01, 0x7D, 0x00, 0x28, 0x01, 0xAC, 0x00, 0x18, 0x01, 0x7D,
        0x00, 0x20, 0x01, 0x68, 0x00, 0x20, 0x01, 0x40, 0x00, 0x28, 0x00, 0x0C, 0x00, 0x00, 0x00, 0xEE,
        0x00, 0x04, 0x57, 0x54, 0x57, 0x54, 0x01, 0x1D, 0x00, 0x08, 0x01, 0x1D, 0x00, 0x08, 0x01, 0x1D,
        0x00, 0x08, 0x01, 0x1D, 0x00, 0x08, 0x01, 0x1D, 0x00, 0x08, 0x01, 0x1D, 0x00, 0x08, 0x01, 0x1D,
        0x00, 0x08, 0x01, 0x1D, 0x00, 0x08, 0x01, 0x1D, 0x00, 0x08, 0x01, 0x1D, 0x00, 0x08, 0x01, 0x1D,
        0x00, 0x08, 0x01, 0x1D, 0x00, 0x08, 0x01, 0x1D, 0x00, 0x08, 0x01, 0x40, 0x00, 0x08, 0x01, 0x68,
        0x00, 0x08, 0x01, 0x7D, 0x00, 0x08, 0x01, 0xAC, 0x00, 0x08, 0x00, 0x08, 0x00, 0x0C, 0x00, 0x00,
        0x00, 0xE8, 0x00, 0x04, 0x57, 0x54, 0x57, 0x54, 0x01, 0xAC, 0x00, 0x0A, 0x01, 0xAC, 0x00, 0x0A,
        0x00, 0xD6, 0x00, 0x0A, 0x01, 0x68, 0x00, 0x05, 0x00, 0xF0, 0x00, 0x0A, 0x01, 0x40, 0x00, 0x05,
        0x00, 0xD6, 0x00, 0x0A, 0x01, 0x1D, 0x00, 0x0A, 0x01, 0x2E, 0x00, 0x0A, 0x00, 0x08, 0x01, 0xAC,
        0x00, 0x0A, 0x00, 0x20, 0x00, 0x46, 0x00, 0x08, 0x00, 0x00, 0x00, 0x2C, 0x00, 0xFF, 0x00, 0x00,
        0x00, 0x40, 0x00, 0x40, 0x00, 0x3B, 0x00, 0x36, 0x00, 0x31, 0x00, 0x2C, 0x00, 0x28, 0x00, 0x23,
        0x00, 0x1E, 0x00, 0x19, 0x00, 0x14, 0x00, 0x0F, 0x00, 0xFF, 0x57, 0x54,
    ]
    /// The places in it of the pointers to `Fiksik_1` and `Fiksik_2` (which hold their offsets in it).
    private static let midwinterPointers = [0x02, 0x30, 0x5C, 0xAE]
    private static let song03: UInt32 = 0x00, label03: UInt32 = 0x08, song11: UInt32 = 0x2E, label11A: UInt32 = 0x36
    private static let label11B: UInt32 = 0x62, song13: UInt32 = 0xAC, label13: UInt32 = 0xB4

    /// The player's routine for a tick, and its patches of the module's code, each with the pattern it
    /// is put in place of (Dave Lowe's own code, as it is in the player's `PatchTable`, $726), done as the
    /// player's do. The player's patches also tell EaglePlayer's scopes what they write, which is not
    /// heard and is left out; what is left of each leaves the registers and the flags as the player's does.
    private static func assemble(_ e: inout Entries) -> [UInt8] {
        var a = AmigaAssembly(at: DeliTrackerHost.clientCode)
        let fx = a.label(), songEnd = a.label(), currentPos = a.label(), hardware = a.label()
        let left = a.label(), right = a.label()
        let voices = (0 ..< 4).map { _ in a.label() }
        let eagleBase = a.label(), songWordAt = a.label(), play = a.label()
        // `Interrupt` ($434): the module's routine for a tick, in A0.
        e.interrupt = a.here
        a.w(0x48E7, 0x7FFE) // MOVEM.L D1-D7/A0-A6,-(A7)
        a.w(0x2079)
        a.address(of: play) // MOVEA.L play,A0
        a.w(0x4E90) // JSR (A0)
        a.w(0x4CDF, 0x7FFE, 0x7000, 0x4E75) // MOVEM.L (A7)+,D1-D7/A0-A6; MOVEQ #0,D0; RTS
        // `ChangeVolume` ($262): the volume's seven bits, turned down by the balance of the voice's side
        // and its muting, written to the voice A2 points at (by its low word), if it points at one.
        let changeVolume = a.placed()
        let v1 = a.label(), v2 = a.label(), v3 = a.label(), write = a.label(), out = a.label()
        a.w(0x2F01, 0x0240, 0x007F, 0x220A) // MOVE.L D1,-(A7); ANDI.W #$7F,D0; MOVE.L A2,D1
        a.w(0x0C41, 0xF0A0)
        a.branch(0x6700, to: v1) // CMPI.W #$F0A0,D1; BEQ.S
        a.w(0x0C41, 0xF0B0)
        a.branch(0x6700, to: v2)
        a.w(0x0C41, 0xF0C0)
        a.branch(0x6700, to: v3)
        a.w(0x0C41, 0xF0D0)
        a.branch(0x6600, to: out) // CMPI.W #$F0D0,D1; BNE.S out
        for (side, voice, label) in [(left, voices[3], nil as Int?), (left, voices[0], v1), (right, voices[1], v2), (right, voices[2], v3)] {
            if let label { a.place(label) }
            a.w(0xC0F9)
            a.address(of: side) // MULU side,D0
            a.w(0xC079)
            a.address(of: voice) // AND.W voice,D0
            if label != v3 { a.branch(0x6000, to: write) } // BRA.S write
        }
        a.place(write)
        a.w(0xEC48, 0x3540, 0x0008) // LSR.W #6,D0; MOVE.W D0,8(A2)
        a.place(out)
        a.w(0x221F, 0x4E75) // MOVE.L (A7)+,D1; RTS
        // The patches, and the table that says where each goes (`PatchTable`).
        var patterns: [[UInt16]] = []
        var patches: [Int] = []
        // Code0, Patch0 ($776, $78A): a volume less a voice's own, made nought below nought.
        patterns.append([0x9068, 0x003E, 0x6400, 0x0008, 0x3039, 0x0000, 0x0000, 0x3540, 0x0008, 0x6000])
        let patch1 = a.label()
        patches.append(a.placed())
        a.w(0x9068, 0x003E, 0x6404, 0x303C, 0x0000) // SUB.W $3E(A0),D0; BCC.S +4; MOVE.W #0,D0
        a.w(0x6100)
        a.displacement(to: patch1) // BSR.W Patch1
        a.w(0x4E75)
        // Code1, Patch1 ($798, $7A0): a volume written, and the voice's place in its pattern kept.
        patterns.append([0x3540, 0x0008, 0x2149, 0x0012])
        a.place(patch1)
        patches.append(patch1)
        a.w(0x6100)
        a.displacement(to: changeVolume) // BSR.W ChangeVolume
        a.w(0x2149, 0x0012, 0x4E75) // MOVE.L A1,$12(A0); RTS
        // Code2 ($7AE), with Patch1: a volume written, then a branch.
        patterns.append([0x3540, 0x0008, 0x6000])
        patches.append(patch1)
        // Code3, Patch3 ($7B4, $7BC): a period written.
        patterns.append([0x3142, 0x0006, 0x3542, 0x0006])
        patches.append(a.placed())
        a.w(0x3142, 0x0006, 0x3542, 0x0006, 0x4A80, 0x4E75) // MOVE.W D2,6(A0); MOVE.W D2,6(A2); TST.L D0; RTS
        // Code4, Patch4 ($7D0, $7DC): a period written, as it is.
        patterns.append([0x3140, 0x0006, 0x3540, 0x0006, 0x3159, 0x0002])
        patches.append(a.placed())
        a.w(0x3140, 0x0006, 0x3540, 0x0006, 0x3159, 0x0002, 0x4E75)
        // Code5, Patch5 ($7EE, $7F8): a sample's start and length, as they are.
        patterns.append([0x24A8, 0x0026, 0x3568, 0x002A, 0x0004])
        patches.append(a.placed())
        a.w(0x24A8, 0x0026, 0x3568, 0x002A, 0x0004, 0x4E75)
        // Code6, Patch6 ($818, $824): two volumes written.
        let patch8 = a.label()
        patterns.append([0x3540, 0x0008, 0x3559, 0x0008, 0x2149, 0x0012])
        patches.append(a.placed())
        a.w(0x6100)
        a.displacement(to: changeVolume)
        a.w(0x6100)
        a.displacement(to: patch8)
        a.w(0x4E75)
        // Code7, Patch7 ($830, $836): a sample's start and length, as they are.
        patterns.append([0x249B, 0x3553, 0x0004])
        patches.append(a.placed())
        a.w(0x249B, 0x3553, 0x0004, 0x4E75)
        // Code8, Patch8 ($852, $85A): a volume from the pattern written.
        patterns.append([0x3559, 0x0008, 0x2149, 0x0012])
        a.place(patch8)
        patches.append(patch8)
        a.w(0x2F00, 0x3019) // MOVE.L D0,-(A7); MOVE.W (A1)+,D0
        a.w(0x6100)
        a.displacement(to: changeVolume)
        a.w(0x201F, 0x2149, 0x0012, 0x4E75) // MOVE.L (A7)+,D0; MOVE.L A1,$12(A0); RTS
        // Code9, Patch9 ($86E, $876): a word cleared, not one read from address nought.
        patterns.append([0x3179, 0x0000, 0x0000, 0x0042])
        patches.append(a.placed())
        a.w(0x317C, 0x0000, 0x0042, 0x4E75)
        // CodeA, PatchA ($87E, $88C): a voice back at the start of its list of patterns; then
        // `SongEndTest` ($89A), which counts it, and once every voice has come round twice says so.
        patterns.append([0x2168, 0x001E, 0x001A, 0x2268, 0x001A, 0x58A8, 0x001A])
        patches.append(a.placed())
        a.w(0x2168, 0x001E, 0x001A, 0x2268, 0x001A, 0x58A8, 0x001A)
        let songEndTest = a.placed()
        let test = a.label(), skip = a.label(), noFX = a.label()
        a.w(0x48E7, 0x0044) // MOVEM.L A1/A5,-(A7)
        a.w(0x43F9)
        a.address(of: songEnd) // LEA SongEnd,A1
        for v in 0 ..< 4 {
            let next = a.label()
            a.w(0xB5FC, 0x00DF, 0xF0A0 + UInt16(v * 16)) // CMPA.L #$DFF0x0,A2
            a.branch(0x6600, to: v == 3 ? test : next) // BNE.S
            if v == 0 {
                a.w(0x4A11) // TST.B (A1)
                a.branch(0x6700, to: test)
                a.w(0x5211) // ADDQ.B #1,(A1)
            } else {
                a.w(0x4A29, UInt16(v)) // TST.B v(A1)
                a.branch(0x6700, to: test)
                a.w(0x5229, UInt16(v)) // ADDQ.B #1,v(A1)
            }
            if v < 3 { a.branch(0x6000, to: test) } // BRA.S test
            a.place(next)
        }
        a.place(test)
        a.w(0x4A91) // TST.L (A1)
        a.branch(0x6600, to: skip) // BNE.S SkipEnd
        a.w(0x22FC, 0xFFFF, 0xFFFF, 0x4291) // MOVE.L #-1,(A1)+; CLR.L (A1)
        a.w(0x2A79)
        a.address(of: eagleBase) // MOVEA.L EagleBase,A5
        a.w(0x4AA9, 0xFFF8) // TST.L -8(A1)
        a.branch(0x6700, to: noFX)
        a.w(0x0C6D, 0x0001, 0x002C) // CMPI.W #1,dtg_SndNum(A5)
        a.branch(0x6600, to: noFX)
        a.w(0x2279)
        a.address(of: songWordAt) // MOVEA.L SubsongPtr,A1
        a.w(0x2379)
        a.address(of: fx)
        a.w(0xFFFA) // MOVE.L SpecialFX,-6(A1)
        a.place(noFX)
        a.w(0x226D, 0x005C, 0x4E91) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1)
        a.place(skip)
        a.w(0x4CDF, 0x2200, 0x4E75) // MOVEM.L (A7)+,A1/A5; RTS
        // CodeB, PatchB ($920, $926): the next pattern; and, for the voice whose list is longest, the
        // count of the position in D0.
        patterns.append([0x58A8, 0x001A, 0x2251])
        patches.append(a.placed())
        let exit = a.label()
        a.w(0xB5F9)
        a.address(of: hardware) // CMPA.L Hardware,A2
        a.branch(0x6600, to: exit)
        a.w(0x2028, 0x001A, 0x90A8, 0x001E, 0x23C0) // MOVE.L $1A(A0),D0; SUB.L $1E(A0),D0; MOVE.L D0,
        a.address(of: currentPos) // CurrentPos
        a.place(exit)
        a.w(0x58A8, 0x001A, 0x2251, 0x4E75) // ADDQ.L #4,$1A(A0); MOVEA.L (A1),A1; RTS
        // CodeC, PatchC ($942, $94A): a note's length, a negative one the end of the voice's list.
        patterns.append([0x3159, 0x0002, 0x5368, 0x0002])
        patches.append(a.placed())
        let ok = a.label()
        a.w(0x3E19) // MOVE.W (A1)+,D7
        a.branch(0x6A00, to: ok) // BPL.S
        a.w(0x6100)
        a.displacement(to: songEndTest) // BSR.W SongEndTest
        a.place(ok)
        a.w(0x3147, 0x0002, 0x5368, 0x0002, 0x4E75) // MOVE.W D7,2(A0); SUBQ.W #1,2(A0); RTS
        // The table: for each, its pattern's offset from the table, its length in words less one, and its
        // patch's offset; then the patterns.
        let table = a.placed()
        e.patchTable = a.addressOf(table)
        let tableBytes = patterns.count * 6 + 2
        var patternAt = tableBytes
        var tableWords: [UInt16] = []
        for (i, pattern) in patterns.enumerated() {
            tableWords += [UInt16(patternAt), UInt16(pattern.count - 1),
                           UInt16(truncatingIfNeeded: Int(a.addressOf(patches[i])) - Int(e.patchTable))]
            patternAt += pattern.count * 2
        }
        for word in tableWords { a.w(word) }
        a.w(0)
        for pattern in patterns { for word in pattern { a.w(word) } }
        // The player's data: its sound effects' number, its counts of the voices' ends, its count of
        // position, the voice that counts it, the two sides' volumes, the four voices' muting, the
        // globals' address, the song's word's address, the routine for a tick's; then Midwinter 2's lists.
        a.place(fx)
        a.long(0)
        a.place(songEnd)
        a.long(0x5754_5754)
        a.place(currentPos)
        a.long(0)
        a.place(hardware)
        a.long(0x00DF_0000)
        a.place(left)
        a.w(64)
        a.place(right)
        a.w(64)
        for v in voices {
            a.place(v)
            a.w(0xFFFF)
        }
        a.place(eagleBase)
        a.long(0)
        a.place(songWordAt)
        a.long(0)
        a.place(play)
        a.long(0)
        let midwinter = a.placed()
        e.midwinter = a.addressOf(midwinter)
        var data = midwinterData
        for at in midwinterPointers {
            let offset = UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
            let address = e.midwinter + offset
            data[at] = UInt8(address >> 24)
            data[at + 1] = UInt8(address >> 16 & 0xFF)
            data[at + 2] = UInt8(address >> 8 & 0xFF)
            data[at + 3] = UInt8(address & 0xFF)
        }
        for i in stride(from: 0, to: data.count, by: 2) { a.w(UInt16(data[i]) << 8 | UInt16(data[i + 1])) }
        e.eagleBase = a.addressOf(eagleBase)
        e.songWordAt = a.addressOf(songWordAt)
        e.specialFX = a.addressOf(fx)
        e.songEnd = a.addressOf(songEnd)
        e.hardware = a.addressOf(hardware)
        e.play = a.addressOf(play)
        return a.assembled()
    }
}

/// Dave Lowe's music, played on Paula by `PaulaTickRenderer`.
extension DaveLoweCodePlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Dave Lowe")
        info.title = title
        info.author = author
        return info
    }

    /// Dave Lowe's earlier music is louder on the Amiga's chip than ProTracker's is, by 5.5 dB in the middle of
    /// UnExoticA's 45 files that play, and is turned down by that (2026-10-19).
    var gain: Float { 0.24 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { ticks.tickClocks }

    func period(_ voice: Int) -> UInt16 { ticks.feed.periods[voice] }
    func volume(_ voice: Int) -> UInt16 { ticks.feed.volumes[voice] }
    var lightFilter: Bool { ticks.feed.lightFilter }
}
