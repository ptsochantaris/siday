// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after UADE's own DeliTracker player for Frederic Hahn's music ("Fred player module V0.1 for UADE
// (21.12.2001)" by Heikki Orsila, LGPL; UADE's players/Fred, whose source is UADE's amigasrc/players/fred/
// fred_new.asm). The lines given are of that source.

import SidayFoundation
import SidayM68000

/// Frederic Hahn's music for the Amiga ("Fred Monitor", as UADE's player names it): each module is the
/// 68000 code that plays it, with its music and its samples, as the game had it, beginning with four
/// JMPs: to its routine that starts a song (with its number, from nought, in D0), to the one for a tick,
/// to the one that stops it, and a fourth. Its four voices' records, of 128 bytes each, follow its
/// code; each voice plays its own list of patterns, which ends in a jump back to a place in it (a word
/// with its top bit set) or in the music's stop ($FFFF).
///
/// As the player plays it, fifty ticks a second, with nothing of it changed but for siday's end of a song.
/// The player's own (each voice's place in its pattern back where it was at the first tick) is taken
/// for the song's end by UADE only if it is asked to (eagleplayer.conf marks it `broken_song_end`), and
/// comes only for songs whose voices' lists all jump back to their start together. A song ends here,
/// rather, once every one of its voices has come to its list's jump at least once (which siday's patch
/// of the module's code that takes the jump notes), as Wanted Team's players end the songs of the
/// composers' code they play; or as the module stops its music itself.
typealias FredMonitorPlayer = WantedTeamPlayer<FredMonitor>

struct FredMonitor: WantedTeamRecipe {
    static let format = "Fred Monitor"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -15.6 dB.)
    static let gain: Float = 0.17

    /// `Check2` (lines 34-122), its three kinds of module: the four JMPs (d16(PC)) and a word or two that
    /// follow them as they are in each; and its last song's number, a byte where the displacement of the
    /// instruction after the JMPs points (six bytes on for the second kind, as the check has it).
    static func isOne(_ data: [UInt8]) -> Bool { lastSong(data) != nil }

    /// The number of the module's last song (from nought), if it is a module of the player's.
    static func lastSong(_ data: [UInt8]) -> Int? {
        func word(_ at: Int) -> Int? { at >= 0 && at + 2 <= data.count ? Int(data[at]) << 8 | Int(data[at + 1]) : nil }
        func long(_ at: Int) -> Int? { word(at).flatMap { high in word(at + 2).map { high << 16 | $0 } } }
        func jumps(_ targets: [Int]) -> Bool {
            (0 ..< 4).allSatisfy { long($0 * 4) == 0x4EFA_0000 | targets[$0] }
        }
        let skip: Int
        if jumps([0x10, 0xA4, 0x8E, 0x7C]), long(16) == 0x0F00_123A {
            skip = 0
        } else if jumps([0x10, 0xA2, 0x94, 0x82]), long(18) == 0x0F00_4238 {
            skip = 6
        } else if jumps([0x4E, 0xE2, 0xCC, 0xBA]), word(16) == 0x0F20 {
            skip = 0
        } else {
            return nil
        }
        // (In words, as the check adds them up.)
        guard let start = word(2) else { return nil }
        var at = (start + 4 + skip) & 0xFFFF
        guard let displacement = word(at) else { return nil }
        at = (at + displacement) & 0xFFFF
        return at < data.count ? Int(data[at]) : nil
    }

    let title = ""
    let author = ""

    private var modPtr: UInt32 = 0, stopAt: UInt32 = 0, notStopped: UInt32 = 0
    private var initSoundAt: UInt32 = 0, tick: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The player's variables (lines 223-229); and siday's for its end of a song: the module's byte that
        // says it has stopped (or a byte of nought here, if it has none where it is looked for), whether
        // the stop has been said, and which voices have come to their list's jump (four bytes).
        let mod = a.variable(long: 0)
        _ = a.variable(long: 0) // maxsubsong
        _ = a.variable(long: 0) // sposptr
        let firstBeat = a.variable(long: 0), endPossible = a.variable(long: 0)
        let stop = a.variable(long: 0), stopped = a.variable(word: 0), zero = a.variable(word: 0)
        let ends = a.variable(long: 0x5754_5754)
        let eagleBase = a.eagleBase()
        // `InitSound` (lines 152-160, DTP_InitSound): the song started with its number in D0.
        initSoundAt = a.here
        a.w(0x48E7, 0xFFFE, 0x7000, 0x302D, UInt16(DeliTrackerHost.dtgSndNum), 0x2079) // MOVEM.L D0-D7/A0-A6,-(A7); MOVEQ #0,D0; MOVE.W dtg_SndNum(A5),D0; MOVEA.L modptr,A0
        a.address(of: mod)
        a.w(0x4E90, 0x42B9) // JSR (A0); CLR.L firstbeat
        a.address(of: firstBeat)
        a.w(0x42B9)
        a.address(of: endPossible) // CLR.L endpossible
        a.w(0x4CDF, 0x7FFF, 0x4E75) // MOVEM.L (A7)+,D0-D7/A0-A6; RTS
        // `Interrupt` (lines 162-204, DTP_Interrupt): the module's routine for a tick, its second JMP; then,
        // in place of the player's end of a song, siday's (done once the tick's writes are made): the
        // module stopped, said once; or every voice at its list's jump, said, and counted afresh.
        tick = a.here
        let done = a.label(), playing = a.label(), end = a.label()
        a.w(0x48E7, 0xFFFE, 0x2079) // MOVEM.L D0-D7/A0-A6,-(A7); MOVEA.L modptr,A0
        a.address(of: mod)
        a.w(0x4EA8, 0x0004, 0x227A) // JSR 4(A0); MOVEA.L Stop(PC),A1
        a.displacement(to: stop)
        a.w(0x4A11) // TST.B (A1)
        a.branch(0x6700, to: playing) // BEQ.S playing
        a.w(0x45FA)
        a.displacement(to: stopped) // LEA Stopped(PC),A2
        a.w(0x4A52) // TST.W (A2)
        a.branch(0x6600, to: done) // BNE.S done
        a.w(0x50D2) // ST (A2)
        a.branch(0x6000, to: end) // BRA.S end
        a.place(playing)
        a.w(0x47FA)
        a.displacement(to: ends) // LEA Ends(PC),A3
        a.w(0x4A93) // TST.L (A3)
        a.branch(0x6600, to: done) // BNE.S done
        a.w(0x26BC, 0x5754, 0x5754) // MOVE.L #'WTWT',(A3)
        a.place(end)
        a.w(0x2A7A)
        a.displacement(to: eagleBase) // MOVEA.L EagleBase(PC),A5
        a.w(0x206D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E90) // MOVEA.L dtg_SongEnd(A5),A0; JSR (A0)
        a.place(done)
        a.w(0x4CDF, 0x7FFF, 0x4E75) // MOVEM.L (A7)+,D0-D7/A0-A6; RTS
        // siday's patch: the module's jump in a voice's list (BCLR #15,D2; MOVE.W D2,D0; ANDI.L #$FFFF,D0, the
        // place it jumps to), and the voice (D5) noted as come to it.
        let jump = a.placed()
        a.w(0x0882, 0x000F, 0x3002, 0x0280, 0x0000, 0xFFFF, 0x2F08, 0x41FA) // BCLR #15,D2; MOVE.W D2,D0; ANDI.L #$FFFF,D0; MOVE.L A0,-(A7); LEA Ends(PC),A0
        a.displacement(to: ends)
        a.w(0x4230, 0x5000, 0x205F, 0x4E75) // CLR.B 0(A0,D5.W); MOVEA.L (A7)+,A0; RTS
        patches.add([0x0882, 0x000F, 0x3002, 0x0280, 0x0000, 0xFFFF], patch: jump)
        patches.assemble(&a)

        modPtr = a.addressOf(mod)
        stopAt = a.addressOf(stop)
        notStopped = a.addressOf(zero)
    }

    /// `InitPlayer` (lines 129-150).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        _ = try host.call(host.machine.peek32(DeliTrackerHost.globals + DeliTrackerHost.dtgGetListData), with: [(0, 0)])
        let module = host.machine.cpu.registers[8], size = Int(host.machine.cpu.registers[0])
        host.machine.poke32(modPtr, module)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(min(size, 0x2000))
        for i in 0 ..< min(size, 0x2000) { bytes.append(host.machine.peek8(module + UInt32(i))) }
        guard let last = Self.lastSong(bytes) else { throw .malformed("not a module of Frederic Hahn's") }
        // The module's byte that says it has stopped: the one its routine for a tick tests first (LEA
        // d(PC),A3; TST.B (A3)); or, if it is not so, a byte of nought of siday's.
        let play = module &+ 6 &+ UInt32(bitPattern: Int32(Int16(bitPattern: host.machine.peek16(module + 6))))
        var stop = notStopped
        if Int(play) + 6 <= host.memorySize, host.machine.peek16(play) == 0x47FA, host.machine.peek16(play + 4) == 0x4A13 {
            stop = play &+ 2 &+ UInt32(bitPattern: Int32(Int16(bitPattern: host.machine.peek16(play + 2))))
        }
        host.machine.poke32(stopAt, stop)
        // siday's patch, in the module's code (as far as 4 KB of it).
        patches.apply(&host, from: module, length: UInt32(min(size, 0x1000)))
        return WantedTeamSongs(first: 0, count: last + 1)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
