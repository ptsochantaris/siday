// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The pieces Wanted Team's EaglePlayers (UADE's amigasrc/players/wanted_team/) have in common: their table
// of patches for EaglePlayer's `ModuleChange`, their searches of a module's code, and the routines of
// theirs that many have word for word, each hand-assembled as they have it.

/// The patches a player makes to a module's code, through EaglePlayer's `ModuleChange` (score's
/// `epg_modulechange`, `DeliTrackerHost.moduleChange`): each a pattern of the module's code and the
/// routine of the player's that is called in its place. As the players lay their `PatchTable` out: for
/// each, its pattern's offset from the table, its length in words less one, and its patch's offset;
/// a word of nought; then the patterns.
struct WantedTeamPatches {
    private var patterns: [[UInt16]] = []
    private var patches: [Int] = []
    /// Where the table is once it is assembled, and each pattern.
    private(set) var table: UInt32 = 0
    private(set) var patternAt: [UInt32] = []

    /// A patch: the code `pattern` (whole words of it) made a call of the routine at `patch` (a label of
    /// the code the table is assembled in, placed before the table is).
    mutating func add(_ pattern: [UInt16], patch: Int) {
        patterns.append(pattern)
        patches.append(patch)
    }

    /// The table and its patterns, assembled here.
    mutating func assemble(_ a: inout AmigaAssembly) {
        table = a.here
        var at = patterns.count * 6 + 2
        for (i, pattern) in patterns.enumerated() {
            a.w(UInt16(at), UInt16(pattern.count - 1), UInt16(truncatingIfNeeded: Int(a.addressOf(patches[i])) - Int(table)))
            at += pattern.count * 2
        }
        a.w(0)
        patternAt = []
        for pattern in patterns {
            patternAt.append(a.here)
            for word in pattern { a.w(word) }
        }
    }

    /// The players' `ModuleChange`: the patches made in the `length` bytes of the module's code from
    /// `from`, searched as they all ask (search mode 1, EPG_ARG5 -2, five arguments).
    func apply(_ host: inout DeliTrackerHost, from: UInt32, length: UInt32) {
        let g = DeliTrackerHost.globals
        host.machine.poke32(g + DeliTrackerHost.epgArg1, from)
        host.machine.poke32(g + DeliTrackerHost.epgArg2, length)
        host.machine.poke32(g + DeliTrackerHost.epgArg3, table)
        host.machine.poke32(g + DeliTrackerHost.epgArg5, 0xFFFF_FFFE)
        host.machine.poke32(g + DeliTrackerHost.epgArg4, 1)
        host.machine.poke32(g + DeliTrackerHost.epgArgN, 5)
        host.moduleChange()
    }
}

/// The players' searches of a module's code, a word at a time from where they begin, bounded here
/// (theirs run on until they find what they look for, into whatever memory follows).
enum WantedTeamSearch {
    /// The first place, from `from` and within `most` bytes of it, that holds `words`; nil if none.
    static func find(_ host: borrowing DeliTrackerHost, _ words: [UInt16], from: UInt32, most: Int) -> UInt32? {
        guard !words.isEmpty else { return nil }
        let end = min(Int(from) + most, host.memorySize - words.count * 2)
        var at = Int(from)
        while at <= end - 2 {
            var same = true
            for (i, word) in words.enumerated() where host.machine.peek16(UInt32(at + i * 2)) != word {
                same = false
                break
            }
            if same { return UInt32(at) }
            at += 2
        }
        return nil
    }

    /// The first place, as `find`, that holds the long `value`.
    static func find(_ host: borrowing DeliTrackerHost, long value: UInt32, from: UInt32, most: Int) -> UInt32? {
        find(host, [UInt16(value >> 16), UInt16(value & 0xFFFF)], from: from, most: most)
    }
}

/// The routines and variables many of Wanted Team's players have the same, each assembled as they have
/// it (with what it does for EaglePlayer's scopes left out).
extension AmigaAssembly {
    /// A long of the player's own, placed here, and its label.
    mutating func variable(long value: UInt32 = 0) -> Int {
        let l = placed()
        long(value)
        return l
    }

    /// A word of the player's own, placed here, and its label.
    mutating func variable(word value: UInt16 = 0) -> Int {
        let l = placed()
        w(value)
        return l
    }

    /// The globals' address, as the players keep it (`EagleBase`, `DeliBase`), placed here; its label.
    mutating func eagleBase() -> Int { variable(long: DeliTrackerHost.globals) }

    /// What the players tell EaglePlayer's scopes (`StructAdr`, a `UPS_` structure of 80 bytes: for each
    /// voice from nought 18 bytes, its sample's address, length, period and volume, at 18v + 0, 4, 6 and 8;
    /// then the DMA's word at 72, the flags at 74 and `UPS_Enabled` at 76), placed here. It is not heard,
    /// but the players' writes to it take their time, which is kept; a label for each of its words.
    mutating func scopes() -> [Int] { (0 ..< 40).map { _ in variable(word: 0) } }

    /// The start of the players' `InitSound`: the scopes' structure cleared, a word at a time.
    mutating func clearScopes(_ scopes: [Int]) {
        let loop = label()
        w(0x41FA)
        displacement(to: scopes[0]) // LEA StructAdr(PC),A0
        w(0x43E8, 0x0050) // LEA UPS_SizeOF(A0),A1
        place(loop)
        w(0x4258, 0xB3C8) // CLR.W (A0)+; CMPA.L A0,A1
        branch(0x6600, to: loop) // BNE.B ClearUPS
    }

    /// `SongEnd`, as the players call it inline: DeliTracker's `dtg_SongEnd`, from the globals' address
    /// kept at `eagleBase`, every register kept.
    mutating func callSongEnd(eagleBase: Int) {
        w(0x48E7, 0x0044, 0x2A7A) // MOVEM.L A1/A5,-(A7); MOVEA.L EagleBase(PC),A5
        displacement(to: eagleBase)
        w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd)) // MOVEA.L dtg_SongEnd(A5),A1
        w(0x4E91) // JSR (A1)
        w(0x4CDF, 0x2200) // MOVEM.L (A7)+,A1/A5
    }

    /// The players' `SongEnd` routine, placed here: `callSongEnd` and RTS.
    mutating func songEndRoutine(eagleBase: Int) -> Int {
        let routine = placed()
        callSongEnd(eagleBase: eagleBase)
        w(0x4E75)
        return routine
    }

    /// The players' test of `SongEndFlag`, which they set while the module's start runs (a module that
    /// starts its song as it ends it, and is patched to say so, would otherwise say so as it begins):
    /// `TST.W SongEndFlag` and a BNE.B to `skip`, which the caller places past its call of the end.
    mutating func unlessStarting(flag: Int, skip: Int) {
        w(0x4A79)
        address(of: flag) // TST.W SongEndFlag
        branch(0x6600, to: skip) // BNE.B NoEnd
    }

    /// The players' `DMAWait`, a routine placed here: `lines` lines of the beam waited for (each change
    /// of VHPOSR's line), every register kept.
    mutating func dmaWait(lines: UInt8) -> Int {
        let routine = placed(), line = label(), same = label()
        w(0x48E7, 0xC000) // MOVEM.L D0/D1,-(SP)
        w(0x7000 | UInt16(lines)) // MOVEQ #lines,D0
        place(line)
        w(0x1239, 0x00DF, 0xF006) // MOVE.B $DFF006,D1
        place(same)
        w(0xB239, 0x00DF, 0xF006) // CMP.B $DFF006,D1
        branch(0x6700, to: same) // BEQ.S same
        w(0x57C8)
        displacement(to: line) // DBEQ D0,line
        w(0x4CDF, 0x0003, 0x4E75) // MOVEM.L (SP)+,D0/D1; RTS
        return routine
    }

    /// The start of the players' `DTP_Interrupt`: the registers but D0 kept, the scopes told a tick is
    /// being played (`UPS_Enabled`) and the periods of the first `voices` voices cleared, and the
    /// module's routine for a tick, whose address is the long at `play`, called.
    mutating func beginTick(play: Int, scopes: [Int], voices: Int) {
        w(0x48E7, 0x7FFE, 0x41FA) // MOVEM.L D1-D7/A0-A6,-(SP); LEA StructAdr(PC),A0
        displacement(to: scopes[0])
        w(0x50E8, 0x004C) // ST UPS_Enabled(A0)
        for v in 0 ..< voices { w(0x4268, UInt16(6 + v * 18)) } // CLR.W UPS_VoiceNPer(A0)
        w(0x317C, 0x000F, 0x004A, 0x207A) // MOVE.W #UPSB_Adr!UPSB_Len!UPSB_Per!UPSB_Vol,UPS_Flags(A0); MOVEA.L PlayPtr(PC),A0
        displacement(to: play)
        w(0x4E90) // JSR (A0)
    }

    /// The end of the players' `DTP_Interrupt`: the scopes told the tick is over, the registers given
    /// back, D0 nought.
    mutating func endTick(scopes: [Int]) {
        w(0x41FA)
        displacement(to: scopes[0]) // LEA StructAdr(PC),A0
        w(0x4268, 0x004C) // CLR.W UPS_Enabled(A0)
        w(0x4CDF, 0x7FFE, 0x7000, 0x4E75) // MOVEM.L (SP)+,D1-D7/A0-A6; MOVEQ #0,D0; RTS
    }

    /// The players' `DTP_Interrupt` with nothing else in it, a routine placed here.
    mutating func tickRoutine(play: Int, scopes: [Int], voices: Int) -> Int {
        let routine = placed()
        beginTick(play: play, scopes: scopes, voices: voices)
        endTick(scopes: scopes)
        return routine
    }

    /// The players' routines that tell the scopes of a voice (`SetVol`, `SetPer`, `SetAll`), placed here:
    /// the address register `pointer` (A0, or another) kept and pointed at the word `field` (from nought: 0
    /// the address, 2 the length, 3 the period, 4 the volume) of the voice whose registers' base the
    /// address register `base` holds (the first of the four whose base is `voicesAt` + 16v, the last for
    /// any other), and then `body`, which writes it.
    mutating func scopeRoutine(_ scopes: [Int], base: Int, field: Int, pointer: Int = 0, voicesAt: UInt32 = 0xDFF000,
                               body: [UInt16]) -> Int
    {
        let routine = placed(), set = label()
        let n = UInt16(pointer) << 9
        w(0x2F08 | UInt16(pointer)) // MOVE.L An,-(A7)
        for v in 0 ..< 4 {
            w(0x41FA | n)
            displacement(to: scopes[v * 9 + field]) // LEA StructAdr+UPS_VoiceN...(PC),An
            if v < 3 {
                let at = voicesAt + UInt32(v * 16)
                w(0xB1FC | UInt16(base) << 9, UInt16(at >> 16), UInt16(at & 0xFFFF)) // CMPA.L #$DFF0x0,Am
                branch(0x6700, to: set) // BEQ.S .SetVoice
            }
        }
        place(set)
        for word in body { w(word) }
        w(0x205F | n, 0x4E75) // MOVEA.L (A7)+,An; RTS
        return routine
    }

    /// The structure an audio interrupt is given to exec by (`StructInt`): an Interrupt node of type
    /// NT_INTERRUPT and priority 5, no data, and its code at `+18`, which the player fills in. Its label.
    mutating func interruptStructure() -> Int {
        let s = placed()
        w(0, 0, 0, 0, 0x0205, 0, 0, 0, 0, 0, 0) // LN_SUCC, LN_PRED, LN_TYPE/LN_PRI, LN_NAME, IS_DATA, IS_CODE
        return s
    }

    /// The players' `SetAudioVector`, a routine placed here: the structure at `structure` made the
    /// handler of Paula's four interrupts by exec's SetIntVector, each old one kept at its long of
    /// `old` (four labels), D0, A1 and A6 kept.
    mutating func setAudioVector(structure: Int, old: [Int]) -> Int {
        let routine = placed()
        w(0x48E7, 0x8042) // MOVEM.L D0/A1/A6,-(A7)
        w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
        for n in 0 ..< 4 {
            w(0x43FA)
            displacement(to: structure) // LEA StructInt(PC),A1
            w(0x7007 + UInt16(n)) // MOVEQ #INTB_AUDn,D0
            w(0x4EAE, 0xFF5E) // JSR _LVOSetIntVector(A6)
            w(0x23C0)
            address(of: old[n]) // MOVE.L D0,ChannelN
        }
        w(0x4CDF, 0x4201, 0x4E75) // MOVEM.L (A7)+,D0/A1/A6; RTS
        return routine
    }

    /// The players' `ClearAudioVector`, a routine placed here: each of Paula's four interrupts given back
    /// the handler kept at `old` by `setAudioVector`.
    mutating func clearAudioVector(old: [Int]) -> Int {
        let routine = placed()
        w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
        for n in 0 ..< 4 {
            w(0x227A)
            displacement(to: old[n]) // MOVEA.L ChannelN(PC),A1
            w(0x7007 + UInt16(n)) // MOVEQ #INTB_AUDn,D0
            // JSR _LVOSetIntVector(A6), and for the last JMP
            w(n < 3 ? 0x4EAE : 0x4EEE, 0xFF5E)
        }
        return routine
    }
}
