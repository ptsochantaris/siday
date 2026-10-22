// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the EaglePlayer for the Mark II Sound System's modules ("Mark II player module V1.2 (24 Okt
// 93)", UADE's players/MarkII, credited to Cachet Software and adapted by Eagleeye), whose source is not
// given: what it does is read from its code, and the addresses given are of its hunk in UADE's file.

import SidayFoundation

/// Music made with the Mark II Sound System (Darius Zendeh's, improved by Andreas Scholl and distributed
/// by Cachet Software, as the Darius Zendeh player's credit has it; here Katakis and Denaris): each module
/// is the 68000 code that plays it, with its music and samples, put where UADE puts a module, and called
/// at its start with D0 -1 and D1 nought to start its one song, and with D0 nought and D1 one for each
/// tick.
///
/// As the player plays it, if the module's code is one of the three it knows (each known by the
/// instructions at a few places in it): the module's writes of its voices' samples, lengths, periods and
/// volumes made calls of the player's routines, which make them and tell EaglePlayer's scopes (the
/// volumes through the voices' own, which are full); and its going back to the start of its music made a
/// call of the player's routine that says the song has ended. That routine then clears the word four
/// bytes past the one the module clears there (the word for the song's being over, which no one reads):
/// the second of the voices' registers' offsets the module swaps between them, which sends one voice's
/// writes, from then on, to registers that are not Paula's. As UADE plays it, so here.
typealias MarkIIPlayer = WantedTeamPlayer<MarkII>

struct MarkII: WantedTeamRecipe {
    static let format = "Mark II"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -18.9 dB.)
    static let gain: Float = 0.25

    /// `Check2` ($19A): the module's second instruction a LEA d16(PC); then, in its first $240 bytes, an
    /// `ASL.W #3,D2` with a LEA d16(PC) after it; and a `ADDA.L d16(PC),A0` in the 24 words from that
    /// LEA's displacement on (or, if there is none, its next instruction `MOVE.W 6(A0,D2.W),4(A3)`), with
    /// a LEA d16(PC) a few words before it.
    static func isOne(_ data: [UInt8]) -> Bool {
        func word(_ at: Int) -> UInt16 {
            guard at >= 0, at + 2 <= data.count else { return 0 }
            return UInt16(data[at]) << 8 | UInt16(data[at + 1])
        }
        guard word(4) == 0x41FA else { return false }
        // (Each search counts down the same D0, from $11F, as DBF does: the count left when it finds
        // what it looks for is where the next search goes on from.)
        var count = 0x11F, at = 0
        while word(at) != 0xE742 {
            at += 2
            count -= 1
            if count < 0 { return false }
        }
        at += 2
        while word(at) != 0x41FA {
            at += 2
            count -= 1
            if count < 0 { return false }
        }
        at += 2
        let next = word(at + 2)
        count = 23
        var lea = at
        while word(lea) != 0xD1FA {
            lea += 2
            count -= 1
            if count < 0 { break }
        }
        var back: Int
        if count < 0 {
            guard next == 0x3770 else { return false }
            back = lea - 28
            count = 15
        } else {
            back = lea + 2
        }
        repeat {
            back -= 2
            if word(back) == 0x41FA { return true }
            count -= 1
        } while count >= 0
        return false
    }

    var title: String { "" }
    var author: String { "" }

    /// The player's three lists of patches (at $360, $394 and $3D2), each: the module's place, the three
    /// words of its code there, and the player's routine that a `JSR` written over them calls.
    private static let lists: [[(at: UInt16, code: [UInt16], patch: Patch)]] = [
        [(0x174, [0x3770, 0x2006, 0x0004], .length), (0x186, [0xD1C2, 0x2688, 0x3401], .addSample),
         (0x1D4, [0x3741, 0x0006, 0x7400], .period), (0x274, [0x3742, 0x0008, 0x5449], .volume),
         (0x0E4, [0x41FA, 0x01C2, 0x4250], .songEnd1C2)],
        [(0x0FE, [0xE341, 0x36B1, 0x1000], .tablePeriod), (0x1E0, [0x3770, 0x2006, 0x0004], .length),
         (0x1F4, [0x2688, 0x0C01, 0x0032], .sample), (0x258, [0x3741, 0x0006, 0x7400], .period),
         (0x304, [0x3742, 0x0008, 0x5449], .volume), (0x144, [0x41FA, 0x020A, 0x4250], .songEnd20A)],
        [(0x0FE, [0xE341, 0x36B1, 0x1000], .tablePeriod), (0x1E0, [0x3770, 0x2006, 0x0004], .length),
         (0x1F2, [0xD1C2, 0x2688, 0x3401], .addSampleW), (0x24C, [0x3741, 0x0006, 0x7400], .period),
         (0x2F8, [0x3742, 0x0008, 0x5449], .volume), (0x144, [0x41FA, 0x01FE, 0x4250], .songEnd1FE)],
    ]

    /// The player's patches, by their places in its hunk.
    private enum Patch: Int, CaseIterable {
        case songEnd20A, songEnd1C2, songEnd1FE, addSampleW, tablePeriod, sample, length, addSample, period, volume
    }

    private var songEndPtr: UInt32 = 0, modulePtr: UInt32 = 0, volumesAt: UInt32 = 0, voicesAt: UInt32 = 0
    private var patchAt: [UInt32] = []
    private var patched = false
    private var initSoundAt: UInt32 = 0, tick: UInt32 = 0

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables ($E8 to $148): `dtg_SongEnd`, the module's address, the voices' volumes, the
        // scopes' structure.
        let songEnd = a.variable(long: 0), module = a.variable(long: 0)
        let volumes = (0 ..< 4).map { _ in a.variable(word: 64) }
        let scopes = a.scopes()
        // `Interrupt` ($15C, DTP_Interrupt): the scopes told a tick is played, and the module called with
        // D0 nought and D1 one.
        let play = a.placed()
        a.w(0x48E7, 0x7FFE, 0x41FA) // MOVEM.L D1-D7/A0-A6,-(A7); LEA StructAdr(PC),A0
        a.displacement(to: scopes[0])
        a.w(0x303C, 0x008F, 0x3140, 0x004A, 0x3140, 0x004C) // MOVE.W #$8F,D0; MOVE.W D0,74(A0); MOVE.W D0,76(A0)
        a.w(0x4268, 0x0006, 0x4268, 0x0018, 0x4268, 0x002A, 0x4268, 0x003C) // CLR.W 6/24/42/60(A0)
        a.w(0x207A)
        a.displacement(to: module) // MOVEA.L Module(PC),A0
        a.w(0x7000, 0x7201, 0x4E90, 0x41FA) // MOVEQ #0,D0; MOVEQ #1,D1; JSR (A0); LEA StructAdr(PC),A0
        a.displacement(to: scopes[0])
        a.w(0x4268, 0x004C, 0x4CDF, 0x7FFE, 0x7000, 0x4E75) // CLR.W 76(A0); MOVEM.L (A7)+,D1-D7/A0-A6; MOVEQ #0,D0; RTS
        // `InitSound` ($208, DTP_InitSound): the module jumped to with D0 -1 and D1 nought.
        let initSound = a.placed()
        a.w(0x207A)
        a.displacement(to: module) // MOVEA.L Module(PC),A0
        a.w(0x70FF, 0x7200, 0x4ED0) // MOVEQ #-1,D0; MOVEQ #0,D1; JMP (A0)
        // $252: a volume (D2, by the patch), seven bits of it, told the scopes, and written turned down by
        // its voice's (A3 the voice's registers).
        let setVolume = a.placed()
        let v1 = a.label(), v2 = a.label(), v3 = a.label(), write = a.label()
        a.w(0x48E7, 0x4080, 0x0241, 0x007F, 0x41FA) // MOVEM.L D1/A0,-(A7); ANDI.W #$7F,D1; LEA StructAdr(PC),A0
        a.displacement(to: scopes[0])
        for (v, next) in [(0, v1), (1, v2), (2, v3)] {
            let at = 0xDFF0A0 + UInt32(v * 16)
            a.w(0xB7FC, UInt16(at >> 16), UInt16(at & 0xFFFF)) // CMPA.L #$DFF0x0,A3
            a.branch(0x6600, to: next) // BNE.S
            a.w(0x3141, UInt16(8 + v * 18), 0xC2FA) // MOVE.W D1,UPS_VoiceVol(A0); MULU VoiceVol(PC),D1
            a.displacement(to: volumes[v])
            a.branch(0x6000, to: write) // BRA.S
            a.place(next)
        }
        a.w(0x3141, 0x003E, 0xC2FA) // MOVE.W D1,UPS_Voice4Vol(A0); MULU Voice4Vol(PC),D1
        a.displacement(to: volumes[3])
        a.place(write)
        a.w(0xEC49, 0x3741, 0x0008, 0x4CDF, 0x0102, 0x4E75) // LSR.W #6,D1; MOVE.W D1,8(A3); MOVEM.L (A7)+,D1/A0; RTS

        // The patches ($410 to $48C), each in place of three words of the module's code.
        var at = [Int](repeating: 0, count: Patch.allCases.count)
        let setSample = a.label(), setLength = a.label(), setPeriod = a.label()
        // $410, $422, $434: the song's end said, and the word the module clears there cleared, as the
        // player finds it: past the JSR's return, by the module's displacement (which counts from four
        // bytes before it).
        for (patch, offset) in [(Patch.songEnd20A, UInt32(0x20A)), (.songEnd1C2, 0x1C2), (.songEnd1FE, 0x1FE)] {
            at[patch.rawValue] = a.placed()
            a.w(0x207A)
            a.displacement(to: songEnd) // MOVEA.L SongEnd(PC),A0
            a.w(0x4E90, 0x2057, 0xD1FC) // JSR (A0); MOVEA.L (A7),A0; ADDA.L #offset,A0
            a.long(offset)
            a.w(0x4250, 0x4E75) // CLR.W (A0); RTS
        }
        // $446: ADDA.L D2,A0; the sample set; MOVE.W D1,D2.
        at[Patch.addSampleW.rawValue] = a.placed()
        a.w(0xD1C2, 0x6100)
        a.displacement(to: setSample) // BSR.W SetSample
        a.w(0x3401, 0x4E75)
        // $450: ASL.W #1,D1; the period from the table at A1 set (A3 six bytes past the voice's registers).
        at[Patch.tablePeriod.rawValue] = a.placed()
        a.w(0xE341, 0x3231, 0x1000, 0x5D8B, 0x6100) // ASL.W #1,D1; MOVE.W 0(A1,D1.W),D1; SUBQ.L #6,A3; BSR.W SetPeriod
        a.displacement(to: setPeriod)
        a.w(0x5C8B, 0x4E75) // ADDQ.L #6,A3; RTS
        // $460: the sample set; CMPI.B #$32,D1.
        at[Patch.sample.rawValue] = a.placed()
        a.branch(0x6100, to: setSample) // BSR.S SetSample
        a.w(0x0C01, 0x0032, 0x4E75)
        // $468: the length 6(A0,D2.W) set.
        at[Patch.length.rawValue] = a.placed()
        a.w(0x2F01, 0x3230, 0x2006) // MOVE.L D1,-(A7); MOVE.W 6(A0,D2.W),D1
        a.branch(0x6100, to: setLength) // BSR.S SetLength
        a.w(0x221F, 0x4E75) // MOVE.L (A7)+,D1; RTS
        // $474: ADDA.L D2,A0; the sample set; MOVE.W D1,D2.
        at[Patch.addSample.rawValue] = a.placed()
        a.w(0xD1C2)
        a.branch(0x6100, to: setSample) // BSR.S SetSample
        a.w(0x3401, 0x4E75)
        // $47C: the period D1 set; MOVEQ #0,D2.
        at[Patch.period.rawValue] = a.placed()
        a.w(0x6100)
        a.displacement(to: setPeriod) // BSR.W SetPeriod
        a.w(0x7400, 0x4E75)
        // $484: the volume D2 set ($252); ADDQ.W #2,A1.
        at[Patch.volume.rawValue] = a.placed()
        a.w(0x2F01, 0x2202, 0x6100) // MOVE.L D1,-(A7); MOVE.L D2,D1; BSR.W SetVolume
        a.displacement(to: setVolume)
        a.w(0x5449, 0x221F, 0x4E75) // ADDQ.W #2,A1; MOVE.L (A7)+,D1; RTS
        // $492, $4CC, $508: a voice's sample (A0), length or period (D1) written, and told the scopes.
        for (routine, field, write) in [(setSample, 0, [UInt16(0x2688)]), (setLength, 2, [0x3741, 0x0004]),
                                        (setPeriod, 3, [0x3741, 0x0006])]
        {
            a.place(routine)
            let done = a.label()
            for word in write { a.w(word) } // MOVE.L A0,(A3), MOVE.W D1,4(A3) or MOVE.W D1,6(A3)
            let store: UInt16 = field == 0 ? 0x23C8 : 0x33C1 // MOVE.L A0,abs.L or MOVE.W D1,abs.L
            for v in 0 ..< 4 {
                let next = a.label()
                if v < 3 {
                    let reg = 0xDFF0A0 + UInt32(v * 16)
                    a.w(0xB7FC, UInt16(reg >> 16), UInt16(reg & 0xFFFF)) // CMPA.L #$DFF0x0,A3
                    a.branch(0x6600, to: next) // BNE.S
                }
                a.w(store)
                a.address(of: scopes[v * 9 + field])
                if v < 3 {
                    a.branch(0x6000, to: done) // BRA.S
                    a.place(next)
                }
            }
            a.place(done)
            a.w(0x4E75)
        }
        songEndPtr = a.addressOf(songEnd)
        modulePtr = a.addressOf(module)
        volumesAt = a.addressOf(volumes[0])
        voicesAt = a.addressOf(scopes[36])
        patchAt = at.map { a.addressOf($0) }
        initSoundAt = a.addressOf(initSound)
        tick = a.addressOf(play)
    }

    /// `InitPlayer` ($2A8): the module's address and `dtg_SongEnd` kept; the first of the three lists
    /// whose code is all where it says made (each place a `JSR` of its patch); and the voices allocated.
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let g = DeliTrackerHost.globals
        let module = host.machine.peek32(g + DeliTrackerHost.dtgChkData)
        host.machine.poke32(modulePtr, module)
        host.machine.poke32(songEndPtr, host.machine.peek32(g + DeliTrackerHost.dtgSongEnd))
        patched = false
        for list in Self.lists where !patched {
            let fits = list.allSatisfy { entry in
                entry.code.enumerated().allSatisfy { host.machine.peek16(module + UInt32(entry.at) + UInt32($0 * 2)) == $1 }
            }
            guard fits else { continue }
            for entry in list {
                host.machine.poke16(module + UInt32(entry.at), 0x4EB9)
                host.machine.poke32(module + UInt32(entry.at) + 2, patchAt[entry.patch.rawValue])
            }
            patched = true
        }
        return WantedTeamSongs(first: 0, count: 1)
    }

    /// `DTP_Volume` ($23A), which the player gives only once it has patched the module: the voices'
    /// volumes, and which are on, from EaglePlayer's.
    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        guard patched else { return }
        let g = DeliTrackerHost.globals
        host.machine.poke16(voicesAt, host.machine.peek16(g + DeliTrackerHost.epgVoices))
        host.machine.poke32(volumesAt, host.machine.peek32(g + DeliTrackerHost.epgVoice1Vol))
        host.machine.poke32(volumesAt + 4, host.machine.peek32(g + DeliTrackerHost.epgVoice1Vol + 4))
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
