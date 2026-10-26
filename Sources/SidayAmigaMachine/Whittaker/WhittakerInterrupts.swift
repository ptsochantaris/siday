// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for David Whittaker's modules ("David Whittaker player module
// V1.0 (11 Nov 2000)", carried by UADE as players/DavidWhittaker), of which there is no source, as UADE's
// host (amigasrc/score/score.s) runs it, which `DeliTrackerHost` does. The addresses given are of the
// player's code hunk, as a disassembly of it has them.

import SidayChips
import SidayFoundation

/// A module of Rob Hubbard's that the player of David Whittaker's plays, whose driver runs from Paula's
/// interrupts as well as from its tick (Q-Ball's): it puts its routine for them at the level 4
/// interrupt's vector itself as a song starts, and its notes ask for them, the routine pointing each
/// voice that has taken up its sample at silence to go on with, so that a sample is played once.
///
/// It is run as the player has it run: the driver's RTE in the routine made an RTS, and its putting of
/// it at the vector made NOPs ($858); the song started (`DTP_InitSound`, $888), and then the routine
/// given to exec by SetIntVector for each of Paula's four interrupts ($992), which UADE's host turns on;
/// and the driver's tick called by the host's timer (`DTP_Interrupt`, $948). The machine runs as the
/// Amiga does, on `DeliTrackerHost`, so that each interrupt comes when Paula asks for it.
///
/// The player's patches of the module are made as `WhittakerPlayer.patch` makes them, each calling the
/// player's own code for it here, which says a song's end to the host as the player's does
/// (`dtg_SongEnd`).
/// (A class, so that `WhittakerPlayer` may hold one or none.)
final class WhittakerInterrupts {
    private var host: DeliTrackerHost
    private(set) var ticks: DeliTicks
    private let code: [UInt8]
    private let layout: WhittakerModule
    /// Where the player's routines and variables here are.
    private let initSound: UInt32, volume: UInt32, interrupt: UInt32
    private let interruptCode: UInt32
    /// A count the patch of the music's stopping keeps, other than its saying the song's end, for the
    /// player to tell a song that has stopped from one that has come round.
    private let stoppedCount: UInt32
    private var stopsSeen: UInt16 = 0
    /// Whether the driver has gone wrong (and the machine has stopped).
    private(set) var failed = false

    var memory: UnsafeMutablePointer<UInt8> { host.memory }
    var memorySize: Int { host.memorySize }
    var busyCycles: Int64 { host.busyCycles }

    /// - Parameters:
    ///   - data: the module as it is.
    ///   - layout: what the player found in it, with its routine for the interrupts.
    init(_ data: [UInt8], _ layout: WhittakerModule) throws(TuneError) {
        guard let routine = layout.audioInterrupt, routine >= 0, routine < data.count else {
            throw .malformed("a module of Rob Hubbard's whose routine for Paula's interrupts is not in it")
        }
        self.layout = layout
        var a = AmigaAssembly(at: DeliTrackerHost.clientCode)
        let made = Self.assemble(&a, layout)
        code = a.assembled()
        initSound = a.addressOf(made.initSound)
        volume = a.addressOf(made.volume)
        interrupt = a.addressOf(made.interrupt)
        interruptCode = a.addressOf(made.structure) + 18
        stoppedCount = a.addressOf(made.stopped)
        // The player's changes to the module: its patches, and the routine for the interrupts made to come
        // back by RTS, its first RTE made one ($866), and the driver's putting of it at the vector made NOPs
        // ($874), the MOVE.L A0,$70 that the player found it by.
        var image = WhittakerPlayer.patch(data, layout, made.patches.map { (pattern: $0.pattern, at: a.addressOf($0.routine)) })
        var at = routine
        while at + 1 < image.count, !(image[at] == 0x4E && image[at + 1] == 0x73) { at += 2 }
        guard at + 1 < image.count else {
            throw .malformed("a module of Rob Hubbard's whose routine for Paula's interrupts does not end")
        }
        image[at + 1] = 0x75
        if let vector = layout.setsVector {
            for i in stride(from: vector, to: vector + 6, by: 2) where i + 1 < image.count {
                image[i] = 0x4E
                image[i + 1] = 0x71
            }
        }
        host = try DeliTrackerHost(moduleAt: WhittakerPlayer.moduleAddress, module: image)
        ticks = DeliTicks(memorySize: host.memorySize)
    }

    // MARK: The player's code

    /// The player's routines, as it has them but for what they do for EaglePlayer's scopes and its
    /// position in the song, which is not heard: `DTP_Volume`, `DTP_InitSound`, `DTP_Interrupt`, and the
    /// patches, each with the pattern of the module's code it is called in place of, in the order of the
    /// player's table of them ($C1A for a module of kind 0, $C70 for the others).
    private static func assemble(_ a: inout AmigaAssembly, _ layout: WhittakerModule)
        -> (initSound: Int, volume: Int, interrupt: Int, structure: Int, stopped: Int, patches: [(pattern: [UInt16], routine: Int)])
    {
        let module = WhittakerPlayer.moduleAddress
        func address(_ offset: Int) -> UInt32 { module &+ UInt32(truncatingIfNeeded: offset) }
        // The variables: the voices not yet back at the start of their lists (`L23C`, a byte each, from
        // `L238`, which a song of three voices has its fourth's clear: $8A0); a song starting (`L237`);
        // the globals (`L232`); the interrupt's structure and the vectors it replaced (`La1C`, `La0C`).
        let all: UInt32 = layout.voices == 4 ? 0x5754_5754 : 0x5754_5700
        let start = a.variable(long: all), voices = a.variable(long: all)
        _ = a.variable(word: 0) // (L240, the position, which a song's end clears.)
        let starting = a.variable(word: 0)
        let stopped = a.variable(word: 0)
        let eagleBase = a.eagleBase()
        let structure = a.interruptStructure()
        let old = (0 ..< 4).map { _ in a.variable(long: 0) }
        // An envelope of volume that stays at nothing ($1000), for the patch of a module of kind 0 or 1.
        let emptyEnvelope = a.placed()
        a.w(0x8080, 0x8080, 0x8080, 0x8080)

        // `DTP_Volume` ($A4E): each voice's volume written again, which is nought before any note, as
        // DeliTracker's volume and balance leave it.
        let volume = a.placed()
        a.w(0x7200, 0x4DF9, 0x00DF, 0xF000) // MOVEQ #0,D1; LEA $DFF000,A6
        for v in 0 ..< 4 { a.w(0x3D41, UInt16(0xA8 + v * 16)) } // MOVE.W D1,$A8+16v(A6)
        a.w(0x4E75)
        // `DTP_InitSound` ($888): the routine some modules have called first, if this one has; the song
        // in D0 started, `L237` set while it starts; then the interrupts' routine given to exec ($992).
        let setAudioVector = a.setAudioVector(structure: structure, old: old)
        let initSound = a.placed()
        if let setUp = layout.setUpAt {
            a.w(0x207C)
            a.long(address(setUp)) // MOVEA.L #setUp,A0
            a.w(0x4E90) // JSR (A0)
        }
        a.w(0x7000, 0x302D, UInt16(DeliTrackerHost.dtgSndNum)) // MOVEQ #0,D0; MOVE.W dtg_SndNum(A5),D0
        a.w(0x33FC, 0x0001)
        a.address(of: starting) // MOVE.W #1,starting
        a.w(0x207C)
        a.long(address(layout.initAt)) // MOVEA.L #init,A0
        a.w(0x4E90, 0x4279) // JSR (A0); CLR.W starting
        a.address(of: starting)
        a.w(0x6000)
        a.displacement(to: setAudioVector) // BRA.W SetAudioVector
        // `DTP_Interrupt` ($948): the driver's tick, called with its address in A0, every register but D0
        // kept; and for the one module whose driver turns its volume down, the word of it put back to 64.
        let interrupt = a.placed()
        a.w(0x48E7, 0x7FFE) // MOVEM.L D1-D7/A0-A6,-(A7)
        if layout.restoresVolume {
            a.w(0x33FC, 0x0040)
            a.long(address(layout.playAt + 1478)) // MOVE.W #$40,1478(play)
        }
        a.w(0x207C)
        a.long(address(layout.playAt)) // MOVEA.L #play,A0
        a.w(0x4E90, 0x4CDF, 0x7FFE, 0x7000, 0x4E75) // JSR (A0); MOVEM.L (A7)+,D1-D7/A0-A6; MOVEQ #0,D0; RTS

        var patches: [(pattern: [UInt16], routine: Int)] = []
        // A voice back at the start of its list: its byte of `L23C` cleared, by the voice whose registers
        // are A6 (and, in a module of Rob Hubbard's, the first voice's too when the second's is: $D64), and
        // once every one is, the bytes set again and the song's end said ($D00, $D8A).
        func wrapped(hubbard: Bool) {
            let check = a.label()
            a.w(0x43FA)
            a.displacement(to: voices) // LEA L23C(PC),A1
            for v in 0 ..< 4 {
                let next = a.label()
                a.w(0xBDFC, 0x00DF, 0xF000 + UInt16(v * 16)) // CMPA.L #$DFF0x0,A6
                a.branch(0x6600, to: next) // BNE.S next
                a.w(v == 0 ? 0x4211 : 0x4229) // CLR.B v(A1)
                if v > 0 { a.w(UInt16(v)) }
                if v == 1, hubbard { a.w(0x4211) } // CLR.B (A1)
                if v < 3 { a.branch(0x6000, to: check) } // BRA.S check
                a.place(next)
            }
            let notAll = a.label()
            a.place(check)
            a.w(0x4A91) // TST.L (A1)
            a.branch(0x6600, to: notAll) // BNE.S notAll
            a.w(0x22FA)
            a.displacement(to: start) // MOVE.L L238(PC),(A1)+
            a.w(0x4251) // CLR.W (A1)
            a.callSongEnd(eagleBase: eagleBase)
            a.place(notAll)
        }
        // The list of words ($CAE, $CBE): TST.W 0(A3,A2.W); BNE +6; MOVEA.W 8(A0),A2; MOVEQ #2,D0;
        // MOVEA.W 0(A3,A2.W),A1.
        do {
            let routine = a.placed(), going = a.label()
            a.w(0x48E7, 0x4044, 0x4A73, 0xA000) // MOVEM.L D1/A1/A5,-(A7); TST.W 0(A3,A2.W)
            a.branch(0x6600, to: going) // BNE.S going
            wrapped(hubbard: false)
            a.w(0x3468, 0x0008, 0x7002) // MOVEA.W 8(A0),A2; MOVEQ #2,D0
            a.place(going)
            a.w(0x4CDF, 0x2202, 0x3273, 0xA000, 0x4E75) // MOVEM.L (A7)+,D1/A1/A5; MOVEA.W 0(A3,A2.W),A1; RTS
            patches.append(([0x4A73, 0xA000, 0x6606, 0x3468, 0x0008, 0x7002, 0x3273, 0xA000], routine))
        }
        if layout.flag != 0 {
            // The list of longs ($D34, $D40): TST.L (A2); BNE +6; MOVEA.L 8(A0),A2; MOVEQ #4,D0;
            // MOVEA.L (A2),A1.
            let routine = a.placed(), going = a.label()
            a.w(0x48E7, 0x0044, 0x4A92) // MOVEM.L A1/A5,-(A7); TST.L (A2)
            a.branch(0x6600, to: going) // BNE.S going
            wrapped(hubbard: true)
            a.w(0x2468, 0x0008, 0x7004) // MOVEA.L 8(A0),A2; MOVEQ #4,D0
            a.place(going)
            a.w(0x4CDF, 0x2200, 0x2252, 0x4E75) // MOVEM.L (A7)+,A1/A5; MOVEA.L (A2),A1; RTS
            patches.append(([0x4A92, 0x6606, 0x2468, 0x0008, 0x7004, 0x2252], routine))
        }
        // The music stopped ($F6C, $F74): MOVE.W #$FF,$DFF09E; and, unless a song is starting, the song's
        // end said (and counted here).
        do {
            let routine = a.placed(), skip = a.label()
            a.w(0x33FC, 0x00FF, 0x00DF, 0xF09E) // MOVE.W #$FF,$DFF09E
            a.unlessStarting(flag: starting, skip: skip)
            a.w(0x5279)
            a.address(of: stopped) // ADDQ.W #1,stopped
            a.callSongEnd(eagleBase: eagleBase)
            a.place(skip)
            a.w(0x4E75)
            patches.append(([0x33FC, 0x00FF, 0x00DF, 0xF09E], routine))
        }
        if layout.flag != 0 {
            // A wait for the DMA, by the processor's time, made a wait of nine lines of the beam ($FA6,
            // $FB2): MOVE.W #$100,D1; DBF D1,*.
            patches.append(([0x323C, 0x0100, 0x51C9, 0xFFFE], a.dmaWait(lines: 8)))
        }
        if layout.flag != 0xFF {
            // A voice readied as a song starts, given the empty envelope and the first sample's header
            // ($FD0, $FD8): MOVE.L A0,12(A1); MOVE.L A0,16(A1).
            let routine = a.placed()
            a.w(0x2348, 0x000C, 0x2348, 0x0010, 0x237C)
            a.address(of: emptyEnvelope)
            a.w(0x0026) // MOVE.L #envelope,38(A1)
            if let header = layout.firstSampleHeader {
                a.w(0x237C)
                a.long(address(header))
                a.w(0x0018) // MOVE.L #header,24(A1)
            }
            a.w(0x4E75)
            patches.append(([0x2348, 0x000C, 0x2348, 0x0010], routine))
        }
        return (initSound, volume, interrupt, structure, stopped, patches)
    }

    // MARK: Playing

    /// Starts a song afresh, as UADE does: the machine switched on with the module in it, the player's
    /// code put in, and the host's calls of the player in its order: the song set, `DTP_Volume`,
    /// `DTP_InitSound`, and its `DTP_Interrupt` set going from the host's timer.
    func start(_ song: Int) throws(TuneError) {
        failed = false
        try host.prepare()
        host.machine.load(code, at: DeliTrackerHost.clientCode)
        host.machine.poke32(interruptCode, WhittakerPlayer.moduleAddress &+ UInt32(truncatingIfNeeded: layout.audioInterrupt ?? 0))
        host.startInterrupts()
        host.setSong(song)
        _ = try host.call(volume)
        try host.initSound(initSound)
        host.playByTimer(interrupt)
        host.idle()
        stopsSeen = host.machine.peek16(stoppedCount)
        ticks.begin(&host)
    }

    /// Runs a tick: the machine run as the Amiga runs until the next is due, and what was written to
    /// Paula told `output` at the moments it was written. Returns how many times the song came round to
    /// its start in it, and how many times the music stopped (or the driver went wrong).
    func run<Output: TFMXOutput>(_ output: inout Output) -> (endings: Int, stops: Int) {
        if failed {
            ticks.idle()
            return (0, 0)
        }
        let (wrong, ends) = ticks.run(&host, &output)
        let count = host.machine.peek16(stoppedCount)
        let stopped = Int(count &- stopsSeen)
        stopsSeen = count
        if wrong {
            failed = true
            return (max(0, ends - stopped), stopped + 1)
        }
        return (max(0, ends - stopped), stopped)
    }
}
