// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Kris Hatlelid's music ("Kris Hatlelid player module V1.0 (6 Nov
// 2001)", UADE's players/KrisHatlelid, whose source is UADE's amigasrc/players/wanted_team/KrisHatlelid/src/
// "Kris Hatlelid_v1.asm"). The addresses given are of the player's hunk in UADE's file.

/// Kris Hatlelid's music for the Amiga (of 1989 to 1991, as the player's credit has it: The Cycles, Grand
/// Prix Circuit, Test Drive II, Hardball II, Wings of Fury, Super C, Teenage Mutant Ninja Turtles, and
/// Igor Shimsky's music for Fiendish Freddy's Big Top o' Fun, played by Hatlelid's code), as Wanted Team
/// adapted it: an AmigaDOS program of three hunks, the second of them for chip memory. In the older games
/// (Grand Prix Circuit, Test Drive II) it is the whole of his code with the one song it plays, beginning
/// `BRA.W` past a long $ABCD; in the rest it is the music alone, whose code is `LEA songs,A0; RTS` (by
/// itself, or after such a `BRA.W`), and the code that plays it is a program of its own beside it, which
/// the player loads by the name `songplay` from the module's folder. Either way the code goes, by a table
/// of `CMP.W #n,D0; BEQ` at its start, to the routines it is called for with their number in D0.
///
/// As the player plays it: the code's routines to start a song, for a tick and for Paula's audio
/// interrupts found in it by the instructions around them (the audio interrupt's RTE made an RTS, and
/// called through exec's SetIntVector for each of Paula's four interrupts); its speed, CIA-A's timer, from
/// the start of the song's first voice, and its changes of speed made through `dtg_SetTimer`; its every
/// voice's volume doubled (at most 64) and written whatever the code would have done; its read of the
/// interrupts' requests made to wait for the beam; and a song ends when every voice's music is over (the
/// first word of each of the four tracks' places nought), when the code turns its audio interrupts off,
/// or when each of the voices has come round to its start again.
typealias KrisHatlelidPlayer = WantedTeamPlayer<KrisHatlelid>

struct KrisHatlelid: WantedTeamRecipe {
    static let format = "Kris Hatlelid"

    /// The name of the replayer the player loads beside a module of music alone (`EPlayerName`, $14F), from
    /// the module's folder.
    static let replayerName = "songplay"

    /// `Check3` ($49E).
    static func isOne(_ data: [UInt8]) -> Bool { twoFiles(data) != nil }

    /// `Check3`'s finding of the kind of module (its `TwoFilesFlags`): an AmigaDOS program of three hunks
    /// (and no names), the first's size in the header the size of its code, the second for chip memory and
    /// the third a long; and its code either `BRA.W *+$18`, a long $ABCD and, at $18, `CMP.W #0,D0` (the
    /// whole of the code: false), or at $18 or at its start `LEA abs.L,A0; RTS` with the address nought
    /// before it is relocated (the music alone: true). Nil for any other file.
    static func twoFiles(_ data: [UInt8]) -> Bool? {
        func long(_ at: Int) -> UInt32 { WantedTeamHeader.long(data, at) }
        guard data.count >= 44, long(0) == 0x3F3, long(4) == 0, long(8) == 3, long(12) == 0, long(16) == 2,
              data[24] == 0x40, long(28) == 1, long(32) == 0x3E9, long(36) == long(20) & ~0x4000_0000
        else { return nil }
        var code = 40
        if long(40) == 0x6000_0016 {
            guard long(44) == 0xABCD else { return nil }
            if long(64) == 0xB07C_0000 { return false }
            code = 64
        }
        return long(code) == 0x41F9_0000 && long(code + 4) == 0x0000_4E75 ? true : nil
    }

    let title = ""
    let author = ""

    /// The player's variables and routines, where they are assembled.
    private var modulePtr: UInt32 = 0, twoFilesFlags: UInt32 = 0, songsPtr: UInt32 = 0, speedPtr: UInt32 = 0
    private var initPtr: UInt32 = 0, playPtr: UInt32 = 0, track0Info: UInt32 = 0, voicesPtr: UInt32 = 0
    private var intAddress: UInt32 = 0, setVolume: UInt32 = 0, initSoundAt: UInt32 = 0, tick: UInt32 = 0
    private var patches = WantedTeamPatches()

    var interrupt: UInt32? { tick }

    mutating func assemble(_ a: inout AmigaAssembly) {
        // The variables ($160 to $1FC), in the player's order where its code relies on it: `Track0Info`
        // then `VoicesPtr`, the four kept volumes, and `Songend`'s four bytes, one for each voice.
        let module = a.variable(long: 0)
        let eagleBase = a.eagleBase()
        let twoFiles = a.variable(word: 0)
        let songs = a.variable(long: 0), speed = a.variable(long: 0), initRoutine = a.variable(long: 0)
        let play = a.variable(long: 0), track0 = a.variable(long: 0), voices = a.variable(long: 0)
        let stack = a.variable(long: 0), firstVoice = a.variable(long: 0), songend = a.variable(long: 0)
        let rightVolume = a.variable(word: 64), leftVolume = a.variable(word: 64)
        let voiceOn = (0 ..< 4).map { _ in a.variable(word: 1) }
        // (The kept volumes are, in UADE's file, the start of its dedication, "This player is dedicated to
        // Shivaree!", which takes the place of the source's noughts and of its scopes' structure: written by
        // `SetVolume` before `InitSound` clears them.)
        let oldVoices = [0x5468, 0x6973, 0x2070, 0x6C61].map { a.variable(word: $0) }
        let scopes = a.scopes()
        // (`InfoBuffer`, $52E: of what it tells EaglePlayer only the song's length is written as it plays.)
        let info = a.placed()
        for _ in 0 ..< 6 { a.long(0) }
        let channels = (0 ..< 4).map { _ in a.variable(long: 0) }
        let structure = a.interruptStructure()
        // `SetVolume` ($2B0, DTP_Volume): the sides' volumes from DeliTracker's, and each voice's kept
        // volume written again through `ChangeVolume` (A6 its volume's register).
        let changeVolume = a.label(), setNew = a.label()
        setVolume = a.here
        for (balance, side) in [(DeliTrackerHost.dtgSndLBal, leftVolume), (DeliTrackerHost.dtgSndRBal, rightVolume)] {
            a.w(0x302D, UInt16(balance), 0xC0ED, UInt16(DeliTrackerHost.dtgSndVol)) // MOVE.W balance(A5),D0; MULU.W dtg_SndVol(A5),D0
            a.w(0xEC48, 0x33C0) // LSR.W #6,D0; MOVE.W D0,side
            a.address(of: side)
        }
        a.w(0x45FA)
        a.displacement(to: oldVoices[0]) // LEA OldVoice1(PC),A2
        a.w(0x7203, 0x4DF9, 0x00DF, 0xF0A8) // MOVEQ #3,D1; LEA $DFF0A8,A6
        a.place(setNew)
        a.w(0x301A) // MOVE.W (A2)+,D0
        a.branch(0x6100, to: changeVolume) // BSR.B ChangeVolume
        a.w(0x508E, 0x508E, 0x51C9) // ADDQ.L #8,A6; ADDQ.L #8,A6; DBF D1,SetNew
        a.displacement(to: setNew)
        a.w(0x4E75)
        // `ChangeVolume` ($2EA): the volume in D0, seven bits, kept as the voice's, nought if it is muted,
        // turned down by its side's balance, and written.
        a.place(changeVolume)
        let setIt = a.label()
        let sides = [leftVolume, rightVolume, rightVolume, leftVolume]
        a.w(0x0240, 0x007F) // ANDI.W #$7F,D0
        for v in 0 ..< 4 {
            let next = a.label(), on = a.label()
            if v < 3 {
                a.w(0xBDFC, 0x00DF, 0xF0A8 + UInt16(v * 16)) // CMPA.L #$DFF0x8,A6
                a.branch(0x6600, to: next) // BNE.B NoVoice
            }
            a.w(0x33C0)
            a.address(of: oldVoices[v]) // MOVE.W D0,OldVoice
            a.w(0x4A79)
            a.address(of: voiceOn[v]) // TST.W Voice
            a.branch(0x6600, to: on) // BNE.B VoiceOn
            a.w(0x7000) // MOVEQ #0,D0
            a.place(on)
            a.w(0xC0FA)
            a.displacement(to: sides[v]) // MULU.W side(PC),D0
            if v < 3 {
                a.branch(0x6000, to: setIt) // BRA.B SetIt
                a.place(next)
            }
        }
        a.place(setIt)
        a.w(0xEC48, 0x3C80, 0x4E75) // LSR.W #6,D0; MOVE.W D0,(A6); RTS
        // `SetVol`, `SetAdr`, `SetLen` and `SetPer` ($362, $392, $3C2, $3F2): the scopes told a voice's
        // volume (D0), sample (A0), length and period (D2), A6 the register written.
        let setVol = a.scopeRoutine(scopes, base: 6, field: 4, pointer: 2, voicesAt: 0xDFF0A8, body: [0x3480]) // MOVE.W D0,(A2)
        let setAdr = a.scopeRoutine(scopes, base: 6, field: 0, pointer: 2, voicesAt: 0xDFF0A0, body: [0x2488]) // MOVE.L A0,(A2)
        let setLen = a.scopeRoutine(scopes, base: 6, field: 2, voicesAt: 0xDFF0A4, body: [0x3082]) // MOVE.W D2,(A0)
        let setPer = a.scopeRoutine(scopes, base: 6, field: 3, voicesAt: 0xDFF0A6, body: [0x3082])
        // `Interrupt` ($55A, DTP_Interrupt): the song's end said if the first word of each of the four
        // tracks' places (74 bytes apart from `Track0Info`) is nought; and the module's tick.
        tick = a.here
        let playIt = a.label()
        a.w(0x48E7, 0x7FFE, 0x41FA) // MOVEM.L D1-D7/A0-A6,-(SP); LEA StructAdr(PC),A0
        a.displacement(to: scopes[0])
        a.w(0x50E8, 0x004C) // ST UPS_Enabled(A0)
        for v in 0 ..< 4 { a.w(0x4268, UInt16(6 + v * 18)) } // CLR.W UPS_VoiceNPer(A0)
        a.w(0x317C, 0x000F, 0x004A, 0x207A) // MOVE.W #UPSB_Adr!UPSB_Len!UPSB_Per!UPSB_Vol,UPS_Flags(A0); MOVEA.L Track0Info(PC),A0
        a.displacement(to: track0)
        for v in 0 ..< 4 {
            if v > 0 { a.w(0x41E8, 0x004A) } // LEA 74(A0),A0
            a.w(0x4A50) // TST.W (A0)
            a.branch(0x6600, to: playIt) // BNE.B Play
        }
        a.w(0x2A7A)
        a.displacement(to: eagleBase) // MOVEA.L EagleBase(PC),A5
        a.w(0x226D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E91) // MOVEA.L dtg_SongEnd(A5),A1; JSR (A1)
        a.place(playIt)
        a.w(0x207A)
        a.displacement(to: play) // MOVEA.L PlayPtr(PC),A0
        a.w(0x4E90) // JSR (A0)
        a.endTick(scopes: scopes)
        // `SetAudioVector` ($5BC), and `SongEnd` ($67C).
        let setAudioVector = a.setAudioVector(structure: structure, old: channels)
        let songEnd = a.songEndRoutine(eagleBase: eagleBase)
        // `InitSound` ($844, DTP_InitSound): the kept volumes cleared, the timer to $3700, each voice's end
        // to come; the module's start (`InitPtr`), then its routine 1 (the instruments read, D1 the song and
        // D2 the songs' table) and 2 (the song played). For a module with its code, the four tracks set
        // going from `VoicesPtr`, as `Patch3` does for the rest. Then the speed from the start of the song's
        // first voice: a $DD and a byte, the timer's upper byte (and a $DE and a byte, its lower); or a $DE
        // and a byte, given to the module's routine for it (`SpeedPtr`), which `Patch1` comes back from
        // here. And the module's audio interrupt made Paula's four's.
        initSoundAt = a.here
        let skipNextTrack = a.label(), nextTrack = a.label(), skipIt = a.label(), newSpeed = a.label()
        let normal = a.label(), noSecond = a.label(), skipNew = a.label()
        a.clearScopes(scopes)
        a.w(0x41FA)
        a.displacement(to: oldVoices[0]) // LEA OldVoice1(PC),A0
        a.w(0x4298, 0x4290) // CLR.L (A0)+; CLR.L (A0)
        a.w(0x3B7C, 0x3700, UInt16(DeliTrackerHost.dtgTimer), 0x41FA) // MOVE.W #$3700,dtg_Timer(A5); LEA Songend(PC),A0
        a.displacement(to: songend)
        a.w(0x20BC, 0x5754, 0x5754, 0x207A) // MOVE.L #'WTWT',(A0); MOVEA.L InitPtr(PC),A0
        a.displacement(to: initRoutine)
        a.w(0x4E90, 0x322D, UInt16(DeliTrackerHost.dtgSndNum), 0x243A) // JSR (A0); MOVE.W dtg_SndNum(A5),D1; MOVE.L SongsPtr(PC),D2
        a.displacement(to: songs)
        a.w(0x7001, 0x207A) // MOVEQ #1,D0; MOVEA.L ModulePtr(PC),A0
        a.displacement(to: module)
        a.w(0x4E90, 0x7002, 0x207A) // JSR (A0); MOVEQ #2,D0; MOVEA.L ModulePtr(PC),A0
        a.displacement(to: module)
        // (Both of `TwoFilesFlags`' bytes are the flag, which `InitPlayer` copies to the second: the first is
        // tested here.)
        a.w(0x4E90, 0x4A39) // JSR (A0); TST.B TwoFilesFlags+1
        a.address(of: twoFiles)
        a.branch(0x6600, to: skipNextTrack) // BNE.B SkipNextTrack
        a.w(0x41FA)
        a.displacement(to: track0) // LEA Track0Info(PC),A0
        a.w(0x2258, 0x7203) // MOVEA.L (A0)+,A1; MOVEQ #3,D1
        a.place(nextTrack)
        // MOVE.W #$FFFF,(A1); CLR.W 58(A1); MOVE.L (A0),$3C(A1); LEA 74(A1),A1; DBF D1,NextTrack
        a.w(0x32BC, 0xFFFF, 0x4269, 0x003A, 0x2350, 0x003C, 0x43E9, 0x004A, 0x51C9)
        a.displacement(to: nextTrack)
        a.w(0x2050, 0x41E8, 0xFFF0) // MOVEA.L (A0),A0; LEA -16(A0),A0
        a.branch(0x6000, to: skipIt) // BRA.B SkipIt
        a.place(skipNextTrack)
        a.w(0x207A)
        a.displacement(to: firstVoice) // MOVEA.L FirstVoice(PC),A0
        a.place(skipIt)
        a.w(0x2028, 0x0004, 0x9090, 0x80FC, 0x0006, 0x45FA) // MOVE.L 4(A0),D0; SUB.L (A0),D0; DIVU.W #6,D0; LEA InfoBuffer(PC),A2
        a.displacement(to: info)
        a.w(0x2540, 0x0014, 0x2050, 0x2050) // MOVE.L D0,Length(A2); MOVEA.L (A0),A0; MOVEA.L (A0),A0
        a.w(0x0C10, 0x00DE) // CMPI.B #$DE,(A0)
        a.branch(0x6700, to: newSpeed) // BEQ.B NewSpeed
        a.w(0x0C10, 0x00DC) // CMPI.B #$DC,(A0)
        a.branch(0x6600, to: normal) // BNE.B Normal
        a.w(0x5488) // ADDQ.L #2,A0
        a.place(normal)
        a.w(0x0C18, 0x00DD) // CMPI.B #$DD,(A0)+
        a.branch(0x6600, to: skipNew) // BNE.B SkipNew
        a.w(0x1018, 0xE188, 0x0C18, 0x00DE) // MOVE.B (A0)+,D0; LSL.L #8,D0; CMPI.B #$DE,(A0)+
        a.branch(0x6600, to: noSecond) // BNE.B NoSecond
        a.w(0x1018) // MOVE.B (A0)+,D0
        a.place(noSecond)
        a.w(0x3B40, UInt16(DeliTrackerHost.dtgTimer)) // MOVE.W D0,dtg_Timer(A5)
        a.branch(0x6000, to: skipNew) // BRA.B SkipNew
        a.place(newSpeed)
        a.w(0x7400, 0x1428, 0x0001, 0x23CF) // MOVEQ #0,D2; MOVE.B 1(A0),D2; MOVE.L A7,Stack
        a.address(of: stack)
        a.w(0x207A)
        a.displacement(to: speed) // MOVEA.L SpeedPtr(PC),A0
        a.w(0x4E90) // JSR (A0)
        let back = a.placed()
        a.w(0x41FA)
        a.displacement(to: stack) // LEA Stack(PC),A0
        a.w(0x2E50, 0x4290) // MOVEA.L (A0),A7; CLR.L (A0)
        a.place(skipNew)
        a.w(0x6000)
        a.displacement(to: setAudioVector) // BRA.W SetAudioVector
        // The patches (`PatchTable`, $934), each with the module's code it is called in place of.
        // Code0, Patch0 ($98A, $998): as it is, and the interrupts in D3 let through again.
        let patch0 = a.placed()
        a.w(0x22A8, 0x0024, 0x317C, 0xFFFF, 0x0012, 0x33C3, 0x00DF, 0xF09A, 0x4E75) // MOVE.L $24(A0),(A1); MOVE.W #$FFFF,$12(A0); MOVE.W D3,$DFF09A; RTS
        patches.add([0x22A8, 0x0024, 0x317C, 0xFFFF, 0x0012], patch: patch0)
        // Code1, Patch1 ($9AA, $9C0) and Code2, Patch2 ($9E2, $9F8): the module's setting of CIA-A's timer
        // A, its upper or lower byte, made `dtg_Timer`'s and set through `dtg_SetTimer`; and, while the
        // speed is being set as the song starts (`Stack` not nought), back to `InitSound`.
        for (latch, byte) in [(UInt16(0xE501), UInt16(DeliTrackerHost.dtgTimer)), (0xE401, UInt16(DeliTrackerHost.dtgTimer + 1))] {
            let patch = a.placed()
            a.w(0x48E7, 0x0044, 0x2A7A) // MOVEM.L A1/A5,-(SP); MOVEA.L EagleBase(PC),A5
            a.displacement(to: eagleBase)
            a.w(0x1B42, byte, 0x226D, UInt16(DeliTrackerHost.dtgSetTimer), 0x4E91, 0x4CDF, 0x2200) // MOVE.B D2,dtg_Timer(A5); MOVEA.L dtg_SetTimer(A5),A1; JSR (A1); MOVEM.L (SP)+,A1/A5
            if latch == 0xE501 {
                a.w(0x4AB9)
                a.address(of: stack) // TST.L Stack
                a.w(0x6600)
                a.displacement(to: back) // BNE.W Back
            }
            a.w(0x4E75)
            // MOVE.B D2,$BFE501 (or $BFE401); MOVE.B #$10,$BFEE01; MOVE.B #1,$BFEE01
            patches.add([0x13C2, 0x00BF, latch, 0x13FC, 0x0010, 0x00BF, 0xEE01, 0x13FC, 0x0001, 0x00BF, 0xEE01], patch: patch)
        }
        // Code3, Patch3 ($A10, $A16): the first voice's place kept (`FirstVoice`), and the four tracks set
        // going from the voices after it.
        let patch3 = a.placed(), nextTrackNew = a.label()
        a.w(0x23C8)
        a.address(of: firstVoice) // MOVE.L A0,FirstVoice
        a.w(0x41E8, 0x0010, 0x267A) // LEA $10(A0),A0; MOVEA.L Track0Info(PC),A3
        a.displacement(to: track0)
        a.w(0x7003) // MOVEQ #3,D0
        a.place(nextTrackNew)
        // MOVE.W #$FFFF,(A3); CLR.W 58(A3); MOVE.L (A0),$3C(A3); LEA 74(A3),A3; DBF D0,NextTrackNew
        a.w(0x36BC, 0xFFFF, 0x426B, 0x003A, 0x2750, 0x003C, 0x47EB, 0x004A, 0x51C8)
        a.displacement(to: nextTrackNew)
        a.w(0x4E75)
        patches.add([0xD1FC, 0x0000, 0x0010], patch: patch3) // ADDA.L #$10,A0
        // Code4, Patch4 ($A3C, $A4C): the module's audio interrupts turned off, at its song's end, made the
        // song's end said.
        let patch4 = a.placed()
        a.w(0x6100)
        a.displacement(to: songEnd) // BSR.W SongEnd
        a.w(0x4E75)
        patches.add([0x33FC, 0x0780, 0x00DF, 0xF09A, 0x33FC, 0x0780, 0x00DF, 0xF01E], patch: patch4) // MOVE.W #$780,$DFF09A; MOVE.W #$780,$DFF01E
        // Code5, Patch5 and `SongEndTest` ($A52, $A5A, $A62): a voice come round to its start (A3 its
        // place, whose volume's register is at 40), as it is, and its byte of `Songend` cleared; once all
        // four are, the song's end said and the count begun again.
        let patch5 = a.placed(), skipEnd = a.label(), test = a.label()
        a.w(0x42AB, 0x000A, 0x206B, 0x0002) // CLR.L 10(A3); MOVEA.L 2(A3),A0
        a.w(0x48E7, 0x0084, 0x41FA) // MOVEM.L A0/A5,-(A7); LEA Songend(PC),A0
        a.displacement(to: songend)
        for v in 0 ..< 4 {
            let next = a.label()
            a.w(0x0CAB, 0x00DF, 0xF0A8 + UInt16(v * 16), 0x0028) // CMPI.L #$DFF0x8,40(A3)
            a.branch(0x6600, to: v < 3 ? next : test) // BNE.B
            if v == 0 { a.w(0x4210) } else { a.w(0x4228, UInt16(v)) } // CLR.B v(A0)
            if v < 3 {
                a.branch(0x6000, to: test) // BRA.B test
                a.place(next)
            }
        }
        a.place(test)
        a.w(0x4A90) // TST.L (A0)
        a.branch(0x6600, to: skipEnd) // BNE.B SkipEnd
        a.w(0x20BC, 0x5754, 0x5754, 0x2A7A) // MOVE.L #'WTWT',(A0); MOVEA.L EagleBase(PC),A5
        a.displacement(to: eagleBase)
        a.w(0x206D, UInt16(DeliTrackerHost.dtgSongEnd), 0x4E90) // MOVEA.L dtg_SongEnd(A5),A0; JSR (A0)
        a.place(skipEnd)
        a.w(0x4CDF, 0x2100, 0x4E75) // MOVEM.L (A7)+,A0/A5; RTS
        patches.add([0x42AB, 0x000A, 0x206B, 0x0002], patch: patch5)
        // Code6, Patch6 ($AC0, $ACE): a voice's volume, which the module writes unless a flag of its own (at
        // `ChangeIt`, found in its code) is set, doubled (at most 64) and written through `ChangeVolume`.
        // Code7 and Code12, Patch7 and Patch12 ($AE6, $AEC; $B58, $B5E): the same for its other writes of
        // a volume (D2) and of nought.
        func writeVolume(_ a: inout AmigaAssembly, _ load: [UInt16], double: Bool) {
            for word in load { a.w(word) }
            if double {
                let low = a.label()
                a.w(0xE348, 0x0C40, 0x0040) // LSL.W #1,D0; CMPI.W #64,D0
                a.branch(0x6F00, to: low) // BLE.B VolLow
                a.w(0x7040) // MOVEQ #64,D0
                a.place(low)
            }
            a.w(0x6100)
            a.displacement(to: changeVolume) // BSR.W ChangeVolume
            a.w(0x6100)
            a.displacement(to: setVol) // BSR.W SetVol
        }
        let patch6 = a.placed()
        writeVolume(&a, [0x302B, 0x001E], double: true) // MOVE.W $1E(A3),D0
        a.w(0x4E75)
        patches.add([0x302B, 0x001E, 0x4A79, 0x5754, 0x5754, 0x6604, 0x3C80], patch: patch6) // ...; TST.W ChangeIt; BNE.S *+6; MOVE.W D0,(A6)
        let patch7 = a.placed()
        writeVolume(&a, [0x2C6B, 0x0028, 0x2F00, 0x3002], double: true) // MOVEA.L $28(A3),A6; MOVE.L D0,-(SP); MOVE.W D2,D0
        a.w(0x201F, 0x4E75) // MOVE.L (SP)+,D0; RTS
        patches.add([0x2C6B, 0x0028, 0x3C82], patch: patch7) // MOVEA.L $28(A3),A6; MOVE.W D2,(A6)
        // Code8 to Code11, Patch8 to Patch11 ($B0A to $B56): a voice's sample, length and period (from D2,
        // or D1), as they are, and told the scopes.
        let patch8 = a.placed()
        a.w(0x2C6B, 0x0030, 0x2C88, 0x6100) // MOVEA.L $30(A3),A6; MOVE.L A0,(A6); BSR.W SetAdr
        a.displacement(to: setAdr)
        a.w(0x4E75)
        patches.add([0x2C6B, 0x0030, 0x2C88], patch: patch8)
        let patch9 = a.placed()
        a.w(0x2C6B, 0x0034, 0x3C82, 0x6100) // MOVEA.L $34(A3),A6; MOVE.W D2,(A6); BSR.W SetLen
        a.displacement(to: setLen)
        a.w(0x4E75)
        patches.add([0x2C6B, 0x0034, 0x3C82], patch: patch9)
        let patch10 = a.placed()
        a.w(0x2C6B, 0x002C, 0x3C82, 0x6100) // MOVEA.L $2C(A3),A6; MOVE.W D2,(A6); BSR.W SetPer
        a.displacement(to: setPer)
        a.w(0x4E75)
        patches.add([0x2C6B, 0x002C, 0x3C82], patch: patch10)
        let patch11 = a.placed()
        a.w(0x2C6B, 0x002C, 0x3C81, 0x2F02, 0x3401, 0x6100) // MOVEA.L $2C(A3),A6; MOVE.W D1,(A6); MOVE.L D2,-(SP); MOVE.W D1,D2; BSR.W SetPer
        a.displacement(to: setPer)
        a.w(0x241F, 0x4E75) // MOVE.L (SP)+,D2; RTS
        patches.add([0x2C6B, 0x002C, 0x3C81], patch: patch11)
        let patch12 = a.placed()
        writeVolume(&a, [0x2C6B, 0x0028, 0x2F00, 0x7000], double: false) // MOVEA.L $28(A3),A6; MOVE.L D0,-(SP); MOVEQ #0,D0
        a.w(0x201F, 0x4E75) // MOVE.L (SP)+,D0; RTS
        patches.add([0x2C6B, 0x0028, 0x4256], patch: patch12) // MOVEA.L $28(A3),A6; CLR.W (A6)
        // Code13, Patch13 ($B72, $B78): the module's audio interrupt's read of the interrupts' requests
        // made to wait for the next line of the beam and its position $16 in it, and to give only those
        // that are let through.
        let patch13 = a.placed(), line = a.label(), wait = a.label()
        a.w(0x1039, 0x00DF, 0xF006) // MOVE.B $DFF006,D0
        a.place(line)
        a.w(0xB039, 0x00DF, 0xF006) // CMP.B $DFF006,D0
        a.branch(0x6700, to: line) // BEQ.S .line
        a.place(wait)
        a.w(0x0C39, 0x0016, 0x00DF, 0xF007) // CMPI.B #$16,$DFF007
        a.branch(0x6500, to: wait) // BCS.B .wait
        a.w(0x3039, 0x00DF, 0xF01C, 0xC079, 0x00DF, 0xF01E, 0x4E75) // MOVE.W $DFF01C,D0; AND.W $DFF01E,D0; RTS
        patches.add([0x3039, 0x00DF, 0xF01E], patch: patch13) // MOVE.W $DFF01E,D0
        patches.assemble(&a)
        modulePtr = a.addressOf(module)
        twoFilesFlags = a.addressOf(twoFiles)
        songsPtr = a.addressOf(songs)
        speedPtr = a.addressOf(speed)
        initPtr = a.addressOf(initRoutine)
        playPtr = a.addressOf(play)
        track0Info = a.addressOf(track0)
        voicesPtr = a.addressOf(voices)
        intAddress = a.addressOf(structure) + 18
    }

    /// `InitPlayer` ($69A).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs {
        func refuse() -> TuneError { .malformed("a module of Kris Hatlelid's whose code is not as the player looks for") }
        // (It first counts the module's samples, its IFF forms, for EaglePlayer's list of them: not heard.)
        let data = try WantedTeamHeader.load(&host)
        guard let twoFiles = Self.twoFiles((0 ..< 72).map { host.machine.peek8(host.moduleAt + UInt32($0)) }) else { throw refuse() }
        let most = host.memorySize - DeliTrackerHost.room
        let module: UInt32
        var songs = 1
        if twoFiles {
            // The replayer, `songplay` in the module's folder ($6F2 to $71E), loaded; the module's code
            // called for the place of its songs' table in A0, and the songs counted: the table's longs up to
            // one of nought, or up to the first song, which the first long points at ($72C to $742).
            guard let replayer = host.loadSegment(Array(Self.replayerName.utf8)) else {
                throw .missingCompanion("a module of Kris Hatlelid's music whose replayer, \(Self.replayerName), is not beside it")
            }
            module = replayer
            _ = try host.call(data)
            let table = host.machine.cpu.registers[8]
            host.machine.poke32(songsPtr, table)
            let firstSong = host.machine.peek32(table)
            var at = table
            songs = 0
            while Int(at) + 4 <= most, songs < 256 {
                let long = host.machine.peek32(at)
                at += 4
                if long == 0 { break }
                songs += 1
                if at == firstSong { break }
            }
        } else {
            module = data
        }
        host.machine.poke32(modulePtr, module)
        host.machine.poke16(twoFilesFlags, twoFiles ? 0xFFFF : 0)
        func find(_ words: [UInt16], from: UInt32) throws(TuneError) -> UInt32 {
            guard from < most, let at = WantedTeamSearch.find(host, words, from: from, most: most - Int(from)) else { throw refuse() }
            return at
        }
        func relative(_ at: UInt32) -> UInt32 { at &+ UInt32(bitPattern: Int32(Int16(bitPattern: host.machine.peek16(at)))) }
        // `FindSpeed` ($770): the routine for a speed, where `CMP.W #$DE,...; BEQ.W` goes.
        var at = try find([0x00DE, 0x6700], from: module) + 4
        host.machine.poke32(speedPtr, relative(at))
        // `FindVol` ($784): the flag the module's writes of a volume are made by (the long that its
        // `MOVE.W $1E(A3),D0` is followed by a TST.W of), put into `Code6`; and from there the first RTE,
        // the end of its audio interrupt, made an RTS.
        at = try find([0x302B, 0x001E], from: at)
        host.machine.poke32(patches.patternAt[6] + 6, host.machine.peek32(at + 6))
        at = try find([0x4E73], from: at)
        host.machine.poke16(at, 0x4E75)
        // `FindZero` ($7A4): the start, two bytes past where the routine for nought goes (`CMP.W #0,D0;
        // BEQ.W`); the first `LEA abs.L,A1` after it made an RTS (so that the start is only what comes
        // before it); then the routine for a tick and the audio interrupt, which the next two `LEA d16(PC),A1`
        // point at; and the four tracks' places, the address of the first `LEA abs.L,A0` past the audio
        // interrupt's start.
        let initAt = relative(try find([0xB07C, 0x0000], from: module) + 6) &+ 2
        host.machine.poke32(initPtr, initAt)
        at = try find([0x43F9], from: initAt)
        host.machine.poke16(at, 0x4E75)
        at = try find([0x43FA], from: at + 2) + 2
        host.machine.poke32(playPtr, relative(at))
        at = relative(try find([0x43FA], from: at) + 2)
        host.machine.poke32(intAddress, at)
        at = try find([0x41F9], from: at) + 2
        host.machine.poke32(track0Info, host.machine.peek32(at))
        if !twoFiles {
            // `OldFormat` ($7F2): the voices' table, the address of the first `LEA abs.L,A0` of the routine
            // for one.
            at = relative(try find([0xB07C, 0x0001], from: module) + 6)
            at = try find([0x41F9], from: at) + 2
            host.machine.poke32(voicesPtr, host.machine.peek32(at))
        }
        // `ModuleChange` ($26E): the patches made in the 2,600 bytes of the code from its start.
        patches.apply(&host, from: module, length: 2600)
        return WantedTeamSongs(first: 0, count: songs)
    }

    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError) {
        _ = try host.call(setVolume)
    }

    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError) {
        try host.initSound(initSoundAt)
    }
}
