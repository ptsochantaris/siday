// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Andy Silva's EaglePlayer for the sounds of Lucasfilm's SCUMM games ("SCUMM Player module V1.0
// (25 Mar 95)", UADE's players/SCUMM), whose source is not given: what it does is read from its code, and
// the addresses given are of its hunk in UADE's file.

/// The music and sounds of the Amiga's versions of Maniac Mansion and Zak McKracken (SCUMM's first and
/// second versions), as the games kept them: each file is one sound, its own 68000 code with its data
/// after it. It begins with a word, then a word that is the distance from the end of the second to the
/// sound's samples, then its code (or a BRA.W to it), which begins `MOVEM.L D1-D7/A0-A6,-(A7)` and then
/// either `MOVEA.L A3,A2; MOVEA.L A3,A5` or `BCLR #4,D0`.
///
/// As the player plays it: the sound's code called fifty times a second, with its samples' address in
/// A1, memory of the player's to keep its state in at A0, and in D0 the voices it may use ($F, all four),
/// with bit 4 set on the first call, which starts it. The sound's code says it has finished by returning
/// with the carry set: the player does not look at that, and has no end of its own; here it is the
/// sound's end.
typealias ScummPlayer = WantedTeamPlayer<Scumm>

struct Scumm: WantedTeamRecipe {
    static let format = "SCUMM"
    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -20.8 dB.)
    static let gain: Float = 0.31

    /// `Check2` ($CC): the sound's code where its fourth byte is (or where the BRA.W there goes) begins
    /// `MOVEM.L D1-D7/A0-A6,-(A7)` and `MOVEA.L A3,A2; MOVEA.L A3,A5` or `BCLR #4,D0`.
    static func isOne(_ data: [UInt8]) -> Bool {
        func long(_ at: Int) -> UInt32 { WantedTeamHeader.long(data, at) }
        var at = 0
        if data.count >= 8, data[4] == 0x60, data[5] == 0 {
            at = 2 + Int(Int16(bitPattern: UInt16(data[6]) << 8 | UInt16(data[7])))
        }
        return long(at + 4) == 0x48E7_7FFE && (long(at + 8) == 0x244B_2A4B || long(at + 8) == 0x0880_0004)
    }

    let title = "", author = ""

    private var modulePtr: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables ($B4 to $CB): the sound, the call's voices and its start, and the sound's memory,
        // from $BC: 16 bytes of the player's and the code after them, its `Check2`, which the sounds
        // write over (UnExoticA's write as far as 24 bytes in): its words are put here as they are, for a
        // sound that reads them before it writes them.
        let module = a.variable(long: 0), voices = a.variable(long: 0)
        let work = a.placed()
        for _ in 0 ..< 8 { a.w(0) }
        a.w(0x206D, UInt16(DeliTrackerHost.dtgChkData), 0x7001, 0x0C68, 0x6000, 0x0004, 0x6608, 0x3028, 0x0006, 0x41F0, 0x0002)
        a.w(0x0CA8, 0x48E7, 0x7FFE, 0x0004, 0x6616, 0x0CA8, 0x244B, 0x2A4B, 0x0008, 0x670A, 0x0CA8, 0x0880, 0x0004, 0x0008)
        a.w(0x6602, 0x7000, 0x4E75)
        // `Interrupt` ($104, DTP_Interrupt): the sound's code called with its samples in A1 (past its
        // second word, by its distance), its memory in A0, and its voices in D0, $F after the first call.
        // (And the end, which is not the player's: the carry set.)
        let eagleBase = a.eagleBase()
        tick = a.here
        let done = a.label()
        a.w(0x48E7, 0x3F3E, 0x41FA) // MOVEM.L D2-D7/A2-A6,-(A7); LEA Work(PC),A0
        a.displacement(to: work)
        a.w(0x267A) // MOVEA.L Module(PC),A3
        a.displacement(to: module)
        a.w(0x548B, 0x301B, 0x43F3, 0x0000, 0x45FA) // ADDQ.L #2,A3; MOVE.W (A3)+,D0; LEA 0(A3,D0.W),A1; LEA Voices(PC),A2
        a.displacement(to: voices)
        a.w(0x2012, 0x720F, 0x2481, 0x4E93) // MOVE.L (A2),D0; MOVEQ #15,D1; MOVE.L D1,(A2); JSR (A3)
        a.branch(0x6400, to: done) // BCC.S
        a.callSongEnd(eagleBase: eagleBase)
        a.place(done)
        a.w(0x4CDF, 0x7CFC, 0x4E75) // MOVEM.L (A7)+,D2-D7/A2-A6; RTS
        // `InitSound` ($148, DTP_InitSound): the first call to start the sound.
        initSoundAt = a.here
        a.w(0x23FC, 0xFFFF, 0xFFFF) // MOVE.L #-1,Voices
        a.address(of: voices)
        a.w(0x4E75)
        modulePtr = a.addressOf(module)
    }

    /// `InitPlayer` ($12A): the sound found, and nothing else; one song.
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        let (module, _) = try Desire.listData(&host)
        host.machine.poke32(modulePtr, module)
        return WantedTeamSongs(first: 0, count: 1)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
