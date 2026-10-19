// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Martin Walker's modules ("Martin Walker player module V1.1
// (20 July 2001)", carried by UADE as players/MartinWalker), from its source as UADE has it
// (amigasrc/players/wanted_team/MartinWalker/src/Martin Walker_v2.asm), and UADE's own host for such
// players (amigasrc/score/score.s), which calls them. Its routines are named as the source names them.

/// Martin Walker's music for the Amiga, played by his own driver: each module is the 68000 code he wrote
/// to play it, which writes Paula's registers itself, with the music and the samples after it. It is run
/// on an emulated Amiga (`AmigaMachine`), as UADE runs it with Wanted Team's EaglePlayer: the song
/// started by its routine for that, with the song's number in D0 and D1 (`DTP_InitSound`), and then its
/// routine for a tick called fifty times a second (a little less: by the CIA's timer DeliTracker and
/// UADE set for a player that has no timer of its own, `TFMXTiming.fiftyTimes`). What it writes to Paula
/// is heard at the moment it writes it within the tick.
///
/// Before it is run, the module is changed as the player changes it (see `MartinWalkerModule` and
/// `patches`), and its songs end as the player has them end: when every voice has come to the end of its
/// list of steps since the song began or last ended, or when the driver stops the music (as it does at
/// the end of a song that does not go round, or of its fading out). Each song's length is found by
/// playing it through in silence.
struct MartinWalkerPlayer: ~Copyable {
    /// Where the module is put: where UADE puts it, past the player and its own code.
    static let moduleAddress: UInt32 = 0xF000
    /// The stack, below the module; and the player's own variables and code for its patches, at the
    /// bottom of the host's room: the four bytes it clears as the voices come to their ends (`SongEnd`),
    /// then the registers a song is started with (D0 to D2, `InitSound`), then the code.
    private static let stackTop: UInt32 = 0xE000
    private static let songEnd: UInt32 = AmigaMachine.hostSpace
    private static let startRegisters: UInt32 = AmigaMachine.hostSpace + 4
    private static let patchCode: UInt32 = AmigaMachine.hostSpace + 0x20
    /// What the patches tell the host through its port: the music stopped, and every voice at its end.
    private static let stoppedPort: UInt32 = AmigaChips.hostPort
    private static let endedPort: UInt32 = AmigaChips.hostPort + 4
    /// The room after the module that is kept empty, and where a voice that is pointed nowhere plays.
    private static let room = 0x20000 + 2048
    static let tickClocks = TFMXTiming.fiftyTimes
    /// How long a song is played through to find its end, at most: ten minutes, which is longer than
    /// UADE plays a song that does not end (512 seconds) and longer than any of UnExoticA's that does
    /// (234 seconds).
    private static let mostTicks = 50 * 60 * 10
    /// The processor's time a call is given: a song's start a fifth of a second, and a tick the whole of
    /// its frame, more than which no Amiga had to give it.
    private static let startBudget = 10 * AmigaMachine.frameCycles
    private static let tickBudget = AmigaMachine.frameCycles
    /// The processor's time a song's playing through in silence is given, and all of a module's songs'.
    private static let dryRunBudget: Int64 = 600_000_000
    private static let dryRunsBudget: Int64 = 3_000_000_000

    let layout: MartinWalkerModule
    /// The module as it was given (its start, for a module that has the player call it, is called again
    /// with each song), and as the player has changed it, put into the machine afresh for each song.
    private let original: [UInt8]
    private let image: [UInt8]
    private let routines: [(pattern: [UInt16], code: [UInt16])]
    private var machine: AmigaMachine
    private var feed: AmigaPaulaFeed
    private(set) var writes: [AmigaWrite] = []
    private var signals: [AmigaWrite] = []
    /// What the song's start wrote to Paula, heard as its first tick begins.
    private(set) var startWrites: [AmigaWrite] = []
    private var startingSong = false
    /// The processor's cycles the song's start took, and the last tick.
    private(set) var startCycles = 0
    private(set) var tickCycles = 0
    /// The processor's cycles all the playings through so far have taken.
    private(set) var dryRuns: Int64 = 0

    private(set) var song = 0
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    private var lengths: [UInt64??]

    var memory: UnsafeMutablePointer<UInt8> { machine.memory }
    var memoryCapacity: Int { machine.memorySize }
    var silenceAt: Int { Int(Self.moduleAddress) + image.count + Self.room / 2 }
    var mixingAt: Int { silenceAt }
    var songCount: Int { max(1, layout.songCount) }

    /// True for a module the player's check takes.
    static func isOne(_ data: [UInt8]) -> Bool { MartinWalkerModule.check(data) != nil }

    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        var refusal: TuneError?
        let size = (Int(Self.moduleAddress) + data.count + Self.room + 0xFFF) & ~0xFFF
        machine = AmigaMachine(chipRAM: size)
        feed = AmigaPaulaFeed(memorySize: machine.memorySize)
        original = data
        var prepared = data
        var layout = MartinWalkerModule.none
        if Int(Self.moduleAddress) + data.count + Self.room > machine.memorySize {
            refusal = .unsupported("a module of Martin Walker's larger than the Amiga's chip RAM")
        } else if let fifth = MartinWalkerModule.check(data) {
            // The module's start called, if the player calls it, and the player's way found about what it
            // leaves.
            if MartinWalkerModule.setsUp(data) {
                machine.load(data, at: Self.moduleAddress)
                if Self.setUp(&machine) {
                    for i in prepared.indices { prepared[i] = machine.peek8(Self.moduleAddress + UInt32(i)) }
                } else {
                    refusal = .malformed("Martin Walker's driver did not come back as it should")
                }
            }
            if refusal == nil {
                do {
                    layout = try MartinWalkerModule(prepared, fifth: fifth)
                } catch {
                    refusal = error
                }
            }
        } else {
            refusal = .malformed("not a module of Martin Walker's")
        }
        self.layout = layout
        routines = Self.patches(layout)
        var addresses: [UInt32] = []
        var at = Self.patchCode
        for routine in routines {
            addresses.append(at)
            at += UInt32(routine.code.count * 2)
        }
        image = layout.patched(prepared, routines: addresses, patterns: routines.map(\.pattern))
        lengths = [UInt64??](repeating: nil, count: max(1, layout.songCount))
        // (Refused only once it is all made.)
        if let refusal { throw refusal }
        try select(song: song >= 0 && song < layout.songCount ? song : 0)
    }

    /// Calls the module's start, as the player's `InitPlayer` does (`JSR (A0)`) for a module that has it.
    private static func setUp(_ machine: inout AmigaMachine) -> Bool {
        for r in 0 ..< 16 { machine.cpu.registers[r] = 0 }
        machine.cpu.registers[8] = moduleAddress
        return machine.call(moduleAddress, stack: stackTop, budget: startBudget) == .returned
    }

    // MARK: The player's changes

    /// 68000 code, a word at a time, with its short branches to labels.
    private struct Code {
        var words: [UInt16] = []
        private var labels: [String: Int] = [:]
        private var branches: [(at: Int, label: String)] = []

        init(_ words: UInt16...) { self.words = words }

        mutating func w(_ values: UInt16...) { words += values }
        mutating func label(_ name: String) { labels[name] = words.count * 2 }
        /// A Bcc.S (its opcode's high byte) to a label.
        mutating func branch(_ op: UInt16, _ name: String) {
            branches.append((words.count, name))
            words.append(op << 8)
        }

        var assembled: [UInt16] {
            var words = self.words
            for (at, name) in branches {
                let displacement = (labels[name] ?? 0) - (at * 2 + 2)
                words[at] |= UInt16(UInt8(truncatingIfNeeded: displacement))
            }
            return words
        }
    }

    /// The player's patterns, in the order of its table of them (`PatchTable`), and for each the code its
    /// patch is made of here. Each does what the player's does, and leaves the registers and the flags as
    /// the player's leaves them (in fewer of the processor's cycles), but for what it does only for
    /// EaglePlayer: its scopes, its counter of positions, and its volume and
    /// balance, which it leaves full, and its voices, all of which it leaves on. Where the player's tells
    /// EaglePlayer of a song's end, this tells the host through its port.
    static func patches(_ layout: MartinWalkerModule) -> [(pattern: [UInt16], code: [UInt16])] {
        // `ChangeVolume`, as it is with the volume and the balance full and every voice on: D3 kept to
        // its lowest seven bits (`AND.W #$7F,D3; MULU.W #64,D3; LSR.W #6,D3`). (Its voice, in D2, is
        // always one of the four in these drivers.)
        let volume: [UInt16] = [0x0243, 0x007F, 0xC6FC, 0x0040, 0xEC4B]
        // What leaves the flags as the player's patches that keep D0 do as they put it back: TST.L D0.
        let keptD0: UInt16 = 0x4A80
        var list: [(pattern: [UInt16], code: [UInt16])] = []
        // `Code2`: MOVE.W D3,8(A6,D2.W); MOVE.W $50(A0,D1.W),D5.
        list.append(([0x3D83, 0x2008, 0x3A30, 0x1050], volume + [0x3D83, 0x2008, 0x3A30, 0x1050, 0x4E75]))
        // `Code3`: DIVU.W #$40,D3; MOVE.W D3,8(A6,D2.W).
        list.append(([0x86FC, 0x0040, 0x3D83, 0x2008], [0x86FC, 0x0040] + volume + [0x3D83, 0x2008, 0x4E75]))
        // `Code4`: a voice's volume, nought while its note's count is past the variable's, otherwise its
        // own, the instrument's and the song's: CMP.B v(A1,D0.W),D5; BHI.S +4; MOVEQ #0,D3; BRA.S +16;
        // MOVE.W 12(A0,D2.W),D3; MULU.W 10(A1,D1.W),D3; MULU.W 8(A1),D3; DIVU.W #$1000,D3; MOVE.W
        // D3,8(A6,D2.W).
        let fourth: [UInt16] = [0xBA31, layout.volumeOffset, 0x6204, 0x7600, 0x6010, 0x3630, 0x200C,
                                0xC6F1, 0x100A, 0xC6E9, 0x0008, 0x86FC, 0x1000]
        list.append((fourth + [0x3D83, 0x2008], fourth + volume + [0x3D83, 0x2008, 0x4E75]))
        // `Code5`: DIVU.W #$1000,D3; MOVE.W D3,8(A6,D2.W).
        list.append(([0x86FC, 0x1000, 0x3D83, 0x2008], [0x86FC, 0x1000] + volume + [0x3D83, 0x2008, 0x4E75]))
        // `Code6`: MOVE.L 0(A0,D2.W),0(A6,D2.W); MOVE.W 4(A0,D2.W),4(A6,D2.W).
        let sample: [UInt16] = [0x2DB0, 0x2000, 0x2000, 0x3DB0, 0x2004, 0x2004]
        list.append((sample, sample + [keptD0, 0x4E75]))
        // `Code7`: MOVE.W #$7E,6(A6,D2.W).
        list.append(([0x3DBC, 0x007E, 0x2006], [0x3DBC, 0x007E, 0x2006, keptD0, 0x4E75]))
        // `Code8`: MOVE.W 12(A0,D2.W),8(A6,D2.W), made of D3, which is kept (MOVE.L D3,-(A7); MOVE.W
        // 12(A0,D2.W),D3; ...; MOVE.W D3,8(A6,D2.W); MOVE.L (A7)+,D3).
        list.append(([0x3DB0, 0x200C, 0x2008], [0x2F03, 0x3630, 0x200C] + volume + [0x3D83, 0x2008, 0x261F, 0x4E75]))
        // `CodeA`: MOVE.L A2,0(A6,D2.W); MOVEA.W 4(A0,D2.W),A2; SUBA.W D5,A2; MOVE.W A2,4(A6,D2.W).
        let later: [UInt16] = [0x2D8A, 0x2000, 0x3470, 0x2004, 0x94C5, 0x3D8A, 0x2004]
        list.append((later, later + [keptD0, 0x4E75]))
        // `CodeB`, the music stopped: CLR.W $DFF0D8; MOVE.W #15,$DFF096. The player tells EaglePlayer the
        // song has ended, and starts it again as `InitSound` does: SongEnd set afresh to 'WTWT', and the
        // song's start called with D0 to D2 as it gave them (MOVEM.L A1/A5,-(A7); ST stopped; MOVEM.L
        // registers,D0-D2; MOVE.L #'WTWT',SongEnd; MOVEA.L #start,A0; JSR (A0); MOVEM.L (A7)+,A1/A5).
        let stop: [UInt16] = [0x4279, 0x00DF, 0xF0D8, 0x33FC, 0x000F, 0x00DF, 0xF096]
        let start = moduleAddress &+ UInt32(truncatingIfNeeded: layout.initAt)
        list.append((stop, stop + [0x48E7, 0x0044,
                                   0x50F9, UInt16(stoppedPort >> 16), UInt16(stoppedPort & 0xFFFF),
                                   0x4CF9, 0x0007, UInt16(startRegisters >> 16), UInt16(startRegisters & 0xFFFF),
                                   0x23FC, 0x5754, 0x5754, UInt16(songEnd >> 16), UInt16(songEnd & 0xFFFF),
                                   0x207C, UInt16(start >> 16), UInt16(start & 0xFFFF),
                                   0x4E90, 0x4CDF, 0x2200, 0x4E75]))
        // `CodeC`, a voice's next step taken: ADDQ.B #1,D5; MOVE.B 0(A4,D5.W),s(A1,D0.W). The player keeps
        // the second voice's as the position (CMP.W #$10,D2; BNE.S +2; TST.W D5, as its MOVE.W D5 leaves
        // the flags).
        let step: [UInt16] = [0x5205, 0x13B4, 0x5000, layout.stepOffset]
        list.append((step, step + [0x0C42, 0x0010, 0x6602, 0x4A45, 0x4E75]))
        // `CodeD`, the start of each voice's part of a tick: ASL.W #1,D1; ASL.W #2,D3; ASL.W #4,D2. The
        // player sees whether the voice's step is the end of its list ($FF, a jump back), clears the
        // voice's byte of SongEnd if it is, and tells of the song's end once all four are clear, setting
        // them again (`PatchD`, as it is).
        var end = Code(0xE341, 0xE543, 0xE942, 0x0C31, 0x00FF, layout.stepOffset)
        end.branch(0x66, "noEnd")
        end.w(0x48E7, 0x0044, 0x43F9, UInt16(songEnd >> 16), UInt16(songEnd & 0xFFFF))
        end.w(0x4A42)
        end.branch(0x66, "1")
        end.w(0x4211)
        end.branch(0x60, "test")
        for (voice, offset) in [(1, 0x10), (2, 0x20), (3, 0x30)] as [(UInt16, UInt16)] {
            end.label("\(voice)")
            end.w(0x0C42, offset)
            end.branch(0x66, voice < 3 ? "\(voice + 1)" : "test")
            end.w(0x4229, voice)
            if voice < 3 { end.branch(0x60, "test") }
        }
        end.label("test")
        end.w(0x4A91)
        end.branch(0x66, "skipEnd")
        end.w(0x22BC, 0x5754, 0x5754, 0x50F9, UInt16(endedPort >> 16), UInt16(endedPort & 0xFFFF))
        end.label("skipEnd")
        end.w(0x4CDF, 0x2200)
        end.label("noEnd")
        end.w(0x4E75)
        list.append(([0xE341, 0xE543, 0xE942], end.assembled))
        // `CodeE` and `CodeF`, the driver's waits for the DMA by the processor's time (MOVE.L #$FF,D0 and
        // MOVEQ #$20,D0, each with DBRA D0,*), made the player's wait of nine lines of the beam
        // (`DMAWait`): MOVEM.L D0/D1,-(SP); MOVEQ #8,D0; MOVE.B $DFF006,D1; CMP.B $DFF006,D1; BEQ.S -8;
        // DBEQ D0,-16; MOVEM.L (SP)+,D0/D1.
        let wait: [UInt16] = [0x48E7, 0xC000, 0x7008, 0x1239, 0x00DF, 0xF006, 0xB239, 0x00DF, 0xF006, 0x67F8,
                              0x57C8, 0xFFF0, 0x4CDF, 0x0003, 0x4E75]
        list.append(([0x203C, 0x0000, 0x00FF, 0x51C8, 0xFFFE], wait))
        list.append(([0x7020, 0x51C8, 0xFFFE], wait))
        return list
    }

    // MARK: Playing

    /// Starts a song afresh, as UADE does: the machine switched on, the module put into it, its start
    /// called if the player calls it (`InitPlayer`), the module as the player has changed it put over
    /// it, and the song started as the player's `InitSound` starts it: SongEnd set to 'WTWT', and the
    /// driver's routine for that called with the song's number in D0 and D1, and in D2 the length of its
    /// list of steps (as the player works it out for EaglePlayer, from the song's entry in the table).
    private mutating func start(_ song: Int) throws(TuneError) {
        machine.powerOn()
        machine.load(original, at: Self.moduleAddress)
        machine.quietPaula()
        feed.reset()
        endings = 0
        stops = 0
        startingSong = true
        defer { startingSong = false }
        var used = 0
        if layout.setsUp {
            guard Self.setUp(&machine) else { throw .malformed("Martin Walker's driver did not come back as it should") }
            used += machine.cycles
        }
        machine.load(image, at: Self.moduleAddress)
        var at = Self.patchCode
        for routine in routines {
            for word in routine.code {
                machine.poke16(at, word)
                at += 2
            }
        }
        machine.poke32(Self.songEnd, 0x5754_5754)
        let entry = Self.moduleAddress &+ UInt32(truncatingIfNeeded: layout.songTable + 16 * song)
        let d2 = UInt32(((machine.peek16(entry &+ 4) &- machine.peek16(entry &+ 2) &- 2) >> 1))
        let n = UInt32(song)
        machine.poke32(Self.startRegisters, n)
        machine.poke32(Self.startRegisters + 4, n)
        machine.poke32(Self.startRegisters + 8, n << 4 & 0xFFFF_0000 | d2)
        for r in 0 ..< 16 { machine.cpu.registers[r] = 0 }
        machine.cpu.registers[0] = n
        machine.cpu.registers[1] = n
        machine.cpu.registers[2] = n << 4 & 0xFFFF_0000 | d2
        try call(layout.initAt, budget: Self.startBudget)
        used += machine.cycles
        machine.takeWrites(into: &startWrites)
        for i in startWrites.indices { startWrites[i].cycles = 0 }
        startCycles = used
        machine.advance(clocks: used / 2)
    }

    /// Calls a routine of the driver's with A0 at it (as the player's `JMP (A0)` and `JSR (A0)` have
    /// it), the other registers as they are set.
    private mutating func call(_ offset: Int, budget: Int) throws(TuneError) {
        let address = Self.moduleAddress &+ UInt32(truncatingIfNeeded: offset)
        machine.cpu.registers[8] = address
        let outcome = machine.call(address, stack: Self.stackTop, budget: budget)
        takeSignals()
        guard outcome == .returned else { throw .malformed("Martin Walker's driver did not come back as it should") }
    }

    /// What the patches have told the host: the music stopped, which is the song's end unless a song is
    /// being started; and every voice at the end of its list.
    private mutating func takeSignals() {
        machine.takeSignals(into: &signals)
        for signal in signals {
            switch UInt32(signal.register) {
            case 0:
                if !startingSong { stops += 1 }
            case 4:
                endings += 1
            default:
                break
            }
        }
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < layout.songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        if lengths[song] == nil {
            // Played through in silence to its end: the tick it ends in is the first after it.
            try start(song)
            var none = Unheard()
            var ticks = 0
            var used: Int64 = 0
            while endings == 0, stops == 0, ticks < Self.mostTicks, used < Self.dryRunBudget, dryRuns < Self.dryRunsBudget {
                _ = run(&none)
                ticks += 1
                used += Int64(tickCycles)
                dryRuns += Int64(tickCycles)
            }
            lengths[song] = .some(endings > 0 || stops > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil)
        }
        lengthClocks = lengths[song] ?? nil
        try start(song)
    }

    /// Runs a tick: the driver's routine for it called, as the player's `DTP_Interrupt` calls it, and what
    /// it wrote told `output` at the moments it wrote it. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        feed.beginTick()
        if !startWrites.isEmpty {
            feed.tell(startWrites, &output)
            startWrites.removeAll(keepingCapacity: true)
        }
        for r in 0 ..< 16 { machine.cpu.registers[r] = 0 }
        var failed = false
        do throws(TuneError) {
            try call(layout.playAt, budget: Self.tickBudget)
        } catch {
            failed = true
        }
        tickCycles = machine.cycles
        machine.takeWrites(into: &writes)
        feed.tell(writes, &output)
        machine.advance(clocks: Self.tickClocks)
        // (Code that does not come back has gone wrong, and the song is over.)
        if failed { stops += 1 }
        return 20
    }

    private struct Unheard: TFMXOutput {
        mutating func on(_: Int) {}
        mutating func off(_: Int) {}
        mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
        func loopCount(_: Int) -> UInt16 { 0 }
    }
}

/// Martin Walker's music, played on Paula by `PaulaTickRenderer`.
extension MartinWalkerPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        TuneInfo(format: "Martin Walker")
    }

    /// Martin Walker's music is louder on the Amiga's chip than ProTracker's is, by 6.0 dB in the middle
    /// of UnExoticA's 22 modules, and is turned down by that (2026-10-19).
    var gain: Float { 0.23 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }

    /// What Paula's registers held as the tick began (see `AmigaPaulaFeed`).
    func period(_ voice: Int) -> UInt16 { feed.periods[voice] }
    func volume(_ voice: Int) -> UInt16 { feed.volumes[voice] }
    var lightFilter: Bool { feed.lightFilter }
}
