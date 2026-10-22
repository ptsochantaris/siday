// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Special FX's modules ("Special FX player module V1.1 (25 Mar
// 2007)", carried by UADE as players/Special-FX; its source is UADE's amigasrc/players/wanted_team/
// SpecialFX/"Special FX_v2.asm"), and UADE's own host for such players (amigasrc/score/score.s), which
// calls them. The routines and labels named are those sources'.

import SidayChips
import SidayFoundation
import SidayM68000

/// Special FX's music for the Amiga, played by the studio's own driver: each module is the 68000 code
/// that plays it, which writes Paula's registers itself, with the music and the samples after it. It is
/// run on an emulated Amiga (`AmigaMachine`), as UADE runs it with Wanted Team's EaglePlayer: the driver
/// moved to where it is put (see `SpecialFXModule`) and patched as the player patches it (`patch(_:_:)`),
/// its samples readied by the routine at its start, a song started by its routine for that, with the
/// song's number, and then its routine for a tick called fifty times a second (a little less: by the
/// CIA's timer DeliTracker and UADE set for a player that has no timer of its own,
/// `TFMXTiming.fiftyTimes`; the driver sets none). What it writes to Paula is heard at the moment it
/// writes it within the tick.
///
/// A song ends as the player has it end: when every voice it uses has come to the end of its list of
/// patterns since the song began or last ended (`SongEndTest`), or at once, and on every tick, for a song
/// that uses no voice. Each song's length is found by playing it through in silence.
struct SpecialFXPlayer: ~Copyable {
    /// Where the module is put: where UADE puts it, past the player (`uade.c`: the player loaded at $9000
    /// and moved to $D000, and the module put 8 KB on from the start of the last 4 KB the player's 2,616
    /// bytes reach into).
    static let moduleAddress: UInt32 = 0xF000
    /// The stack, below the module.
    private static let stackTop: UInt32 = 0xEF00
    /// The player's variables and its code for its patches, from the start of the host's space.
    private static let leftVolume = AmigaMachine.hostSpace
    private static let rightVolume = AmigaMachine.hostSpace + 2
    private static let voiceMasks = AmigaMachine.hostSpace + 4
    private static let songEnd = AmigaMachine.hostSpace + 12
    private static let songEndTemp = AmigaMachine.hostSpace + 16
    private static let originVariable = AmigaMachine.hostSpace + 20
    private static let modulePointer = AmigaMachine.hostSpace + 24
    /// What EaglePlayer's scopes are told (`StructAdr`), ten bytes for each voice: its sample's address,
    /// length and period, and its volume.
    private static let scopes = AmigaMachine.hostSpace + 32
    private static let codeAt = AmigaMachine.hostSpace + 96
    /// Where the patches tell the host a song has ended (in place of the player's call of `dtg_SongEnd`).
    private static let endedPort = AmigaChips.hostPort
    /// The room after the module that is kept empty, and where a voice that is pointed nowhere plays.
    private static let room = 0x20000 + 2048
    static let tickClocks = TFMXTiming.fiftyTimes
    /// How long a song is played through to find its end, at most: ten minutes, over three times the
    /// longest of UnExoticA's that ends (181 seconds).
    private static let mostTicks = 50 * 60 * 10
    /// The processor's time a call is given: the readying of the samples and a song's start a fifth of
    /// a second each, and a tick the whole of its frame, more than which no Amiga had to give it.
    private static let startBudget = 10 * AmigaMachine.frameCycles
    private static let tickBudget = AmigaMachine.frameCycles
    /// The processor's time a song's playing through in silence is given, and all of a module's songs'.
    private static let dryRunBudget: Int64 = 600_000_000
    private static let dryRunsBudget: Int64 = 3_000_000_000

    let layout: SpecialFXModule
    /// The module as the player has moved and patched it, put into the machine afresh for each song; and
    /// the player's own code, put below it.
    private let image: [UInt8]
    private let hostCode: HostCode
    private var machine: AmigaMachine
    private var feed: AmigaPaulaFeed
    private(set) var writes: [AmigaWrite] = []
    private var signals: [AmigaWrite] = []
    /// What the readying of the samples and the song's start wrote to Paula, heard as its first tick
    /// begins.
    private(set) var startWrites: [AmigaWrite] = []
    /// How many voices the song uses.
    private var voices = 0
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
    var songCount: Int { layout.songCount }

    /// True for a module the player's check takes.
    static func isOne(_ data: [UInt8]) -> Bool { SpecialFXModule.isOne(data) }

    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        let code = HostCode.made()
        var refusal: TuneError?
        let layout: SpecialFXModule
        do {
            layout = try SpecialFXModule(data, at: Self.moduleAddress, initFix: code.initFix)
        } catch {
            layout = .none
            refusal = error
        }
        self.layout = layout
        hostCode = code
        image = Self.patch(layout.image, layout, code)
        let size = (Int(Self.moduleAddress) + data.count + Self.room + 0xFFF) & ~0xFFF
        machine = AmigaMachine(chipRAM: size)
        feed = AmigaPaulaFeed(memorySize: machine.memorySize)
        lengths = [UInt64??](repeating: nil, count: layout.songCount)
        // (Refused only once it is all made.)
        if let refusal { throw refusal }
        guard Int(Self.moduleAddress) + data.count + Self.room <= machine.memorySize else {
            throw .unsupported("a module of Special FX's larger than the Amiga's chip RAM")
        }
        try select(song: song >= 0 && song < layout.songCount ? song : 0)
    }

    // MARK: The player's patches

    /// The module as the player patches it (`EP_ModuleChange`), as UADE's host makes the patches
    /// (`epg_modulechange`): each of the player's patterns found, a word at a time, through the driver's
    /// code, and made a JSR to the player's code for it, followed by NOPs.
    static func patch(_ data: [UInt8], _ layout: SpecialFXModule, _ code: HostCode) -> [UInt8] {
        var bytes = data
        for (pattern, address) in code.patches {
            var a0 = layout.firstCode
            var left = layout.codeEnd - layout.firstCode
            while left > 0 {
                if a0 + pattern.count * 2 <= bytes.count,
                   pattern.indices.allSatisfy({ UInt16(bytes[a0 + 2 * $0]) << 8 | UInt16(bytes[a0 + 2 * $0 + 1]) == pattern[$0] })
                {
                    let jsr: [UInt16] = [0x4EB9, UInt16(address >> 16), UInt16(address & 0xFFFF)]
                    for i in pattern.indices {
                        let word = i < 3 ? jsr[i] : 0x4E71
                        bytes[a0 + 2 * i] = UInt8(word >> 8)
                        bytes[a0 + 2 * i + 1] = UInt8(word & 0xFF)
                    }
                    a0 += (pattern.count - 1) * 2
                    left -= (pattern.count - 1) * 2
                }
                a0 += 2
                left -= 2
            }
        }
        return bytes
    }

    /// The player's own code, as it is put below the module: its variables, the code a `LEA $A8.W,A1`
    /// is made a call of (`InitFix`), and its patches, each with the pattern of the driver's it is put in
    /// place of (`PatchTable`). Written here instruction for instruction as the player has them, but for
    /// its call of EaglePlayer at a song's end, which here tells the host through its port; so that the
    /// driver takes the time it takes in UADE.
    struct HostCode {
        let words: [UInt16]
        let initFix: UInt32
        let patches: [(pattern: [UInt16], at: UInt32)]

        private struct Writer {
            var words: [UInt16] = []
            var here: UInt32 { SpecialFXPlayer.codeAt + UInt32(words.count * 2) }
            mutating func w(_ values: UInt16...) { words += values }
            /// A displacement to `target` from this word's own place, as d16(PC) and BSR.W have it.
            mutating func to(_ target: UInt32) { words.append(UInt16(truncatingIfNeeded: Int(target) - Int(here))) }
            /// A short branch, whose place is given back to be pointed at its target (`land`).
            mutating func branch(_ op: UInt16) -> Int {
                words.append(op)
                return words.count - 1
            }

            mutating func land(_ branch: Int) {
                words[branch] |= UInt16(truncatingIfNeeded: words.count * 2 - (branch * 2 + 2)) & 0xFF
            }
        }

        static func made() -> HostCode {
            var c = Writer()
            let initFix = c.here
            c.w(0x43F9, 0x00DF, 0xF0A8, 0x4E75) // LEA $DFF0A8,A1; RTS
            var patches: [(pattern: [UInt16], at: UInt32)] = []

            // The wait for the DMA (`Patch0`), in place of the driver's, which waits for Paula's audio
            // interrupts (`Code0`): nine lines of the beam. MOVEM.L D0/D1,-(SP); MOVEQ #8,D0; .dma1
            // MOVE.B $DFF006,D1; .dma2 CMP.B $DFF006,D1; BEQ.B .dma2; DBEQ D0,.dma1; MOVEM.L (SP)+,D0/D1.
            patches.append(([0x342E, 0x001E, 0xC441, 0xB441, 0x66F6, 0x7402, 0x362E, 0x0006, 0x0243, 0xFF00,
                             0x382E, 0x0006, 0x0244, 0xFF00, 0xB644, 0x67F4, 0x3604, 0x51CA, 0xFFF0], c.here))
            c.w(0x48E7, 0xC000, 0x7008, 0x1239, 0x00DF, 0xF006, 0xB239, 0x00DF, 0xF006, 0x67F8, 0x57C8, 0xFFF0,
                0x4CDF, 0x0003, 0x4E75)

            // Rambo III's samples (`Patch1`): the address the driver takes from its table of them, which
            // the player does not move, moved where it is taken. ADDQ.L #8,A0; MOVE.L A0,D0; SUB.L (A2),D0;
            // SUBA.L Origin(PC),A0; ADDA.L ModulePtr(PC),A0. (The player then counts the sample, for
            // EaglePlayer, which changes nothing the driver does: its flags are set anew by the NEG.L the
            // driver has next.)
            patches.append(([0x5088, 0x2008, 0x9092], c.here))
            c.w(0x5088, 0x2008, 0x9092, 0x91FA)
            c.to(SpecialFXPlayer.originVariable)
            c.w(0xD1FA)
            c.to(SpecialFXPlayer.modulePointer)
            c.w(0x4E75)

            // A voice's volume taken by EaglePlayer's volume and balance and its muting of the voice
            // (`Left1` and the rest): MULU.W volume(PC),D3; AND.W voice(PC),D3; LSR.W #6,D3. The first
            // and fourth voice are on the left, the others on the right.
            let sides: [(volume: UInt32, voice: Int)] = [(SpecialFXPlayer.leftVolume, 3), (SpecialFXPlayer.leftVolume, 0),
                                                        (SpecialFXPlayer.rightVolume, 1), (SpecialFXPlayer.rightVolume, 2)]
            var sideAt = [UInt32](repeating: 0, count: 4)
            var toEx: [Int] = []
            for (i, side) in sides.enumerated() {
                sideAt[side.voice] = c.here
                c.w(0xC6FA)
                c.to(side.volume)
                c.w(0xC67A)
                c.to(SpecialFXPlayer.voiceMasks + UInt32(side.voice * 2))
                if i < 3 { toEx.append(c.branch(0x6000)) }
            }
            for b in toEx { c.land(b) }
            c.w(0xEC4B, 0x4E75)
            // What a voice's volume is, for EaglePlayer's scopes (`SetVol1` and the rest): MOVE.L A2,-(A7);
            // LEA volume(PC),A2; MOVE.W D3,(A2); MOVE.L (A7)+,A2.
            var setVolAt = [UInt32](repeating: 0, count: 4)
            var toSet: [Int] = []
            for v in 0 ..< 4 {
                setVolAt[v] = c.here
                c.w(0x2F0A, 0x45FA)
                c.to(SpecialFXPlayer.scopes + UInt32(v * 10 + 8))
                if v < 3 { toSet.append(c.branch(0x6000)) }
            }
            for b in toSet { c.land(b) }
            c.w(0x3483, 0x245F, 0x4E75)

            for v in 0 ..< 4 {
                let audio = UInt16(0xA0 + v * 16)
                // A voice's volume and period written (`Patch2`, 4, 6, 8): MOVE.W D3,AUDxVOL(A6) and MOVE.W
                // $4A(A0),AUDxPER(A6), after BSR.W to the voice's volume and its scope's.
                patches.append(([0x3D43, audio + 8, 0x3D68, 0x004A, audio + 6], c.here))
                c.w(0x6100)
                c.to(sideAt[v])
                c.w(0x6100)
                c.to(setVolAt[v])
                c.w(0x3D43, audio + 8, 0x3D68, 0x004A, audio + 6, 0x4E75)
                // Its sample's length and address written (`Patch3`, 5, 7, 9): MOVE.W $42(A0),AUDxLEN(A6);
                // MOVE.L $3E(A0),AUDxLC(A6); then the same, and its period, for its scope: MOVE.L A1,-(SP);
                // LEA scope(PC),A1; MOVE.L $3E(A0),(A1)+; MOVE.W $42(A0),(A1)+; MOVE.W $4A(A0),(A1);
                // MOVE.L (SP)+,A1.
                patches.append(([0x3D68, 0x0042, audio + 4, 0x2D68, 0x003E, audio], c.here))
                c.w(0x3D68, 0x0042, audio + 4, 0x2D68, 0x003E, audio, 0x2F09, 0x43FA)
                c.to(SpecialFXPlayer.scopes + UInt32(v * 10))
                c.w(0x22E8, 0x003E, 0x32E8, 0x0042, 0x32A8, 0x004A, 0x225F, 0x4E75)
            }

            // A voice come to the end of its list of patterns (`SongEndTest`), in place of the driver's
            // MOVEA.L 2(A4),A3; CMPA.W #0,A3, which takes the place in the list to go back to: the voice's
            // byte of the player's long cleared, by its bit of the DMA ($54(A4)); and once all are, the
            // long set again to the song's voices, and the song's end told.
            patches.append(([0x266C, 0x0002, 0xB6FC, 0x0000], c.here))
            c.w(0x48E7, 0x0044, 0x43FA) // MOVEM.L A1/A5,-(A7); LEA Songend(PC),A1
            c.to(SpecialFXPlayer.songEnd)
            var toTest: [Int] = []
            for v in 0 ..< 4 {
                c.w(0x0C6C, UInt16(1 << v), 0x0054) // CMP.W #bit,$54(A4)
                let next = c.branch(0x6600) // BNE.B next
                if v == 0 { c.w(0x4211) } else { c.w(0x4229, UInt16(v)) } // CLR.B v(A1)
                if v < 3 { toTest.append(c.branch(0x6000)) } // BRA.B test
                c.land(next)
            }
            for b in toTest { c.land(b) }
            c.w(0x4A91) // TST.L (A1)
            let skip = c.branch(0x6600) // BNE.B SkipEnd
            c.w(0x22BA) // MOVE.L SongEndTemp(PC),(A1)
            c.to(SpecialFXPlayer.songEndTemp)
            c.w(0x33FC, 0x0001, UInt16(SpecialFXPlayer.endedPort >> 16), UInt16(SpecialFXPlayer.endedPort & 0xFFFF))
            c.land(skip)
            c.w(0x4CDF, 0x2200, 0x266C, 0x0002, 0xB6FC, 0x0000, 0x4E75) // MOVEM.L (A7)+,A1/A5; and the driver's
            return HostCode(words: c.words, initFix: initFix, patches: patches)
        }
    }

    // MARK: Playing

    /// Starts a song afresh, as UADE does: the machine switched on, the player's code and the module put
    /// into it, Paula quietened, the samples readied as the player's `InitPlayer` has them readied (the
    /// module's start called), and the song started as its `InitSound` starts it: its routine for that
    /// called with the song's number, from 1, in D0.
    private mutating func start(_ song: Int) throws(TuneError) {
        machine.powerOn()
        var at = Self.codeAt
        for word in hostCode.words {
            machine.poke16(at, word)
            at += 2
        }
        machine.poke16(Self.leftVolume, 64)
        machine.poke16(Self.rightVolume, 64)
        for v in 0 ..< 4 { machine.poke16(Self.voiceMasks + UInt32(v * 2), 0xFFFF) }
        machine.poke32(Self.originVariable, layout.origin)
        machine.poke32(Self.modulePointer, Self.moduleAddress)
        machine.load(image, at: Self.moduleAddress)
        machine.quietPaula()
        feed.reset()
        endings = 0
        stops = 0
        try call(0, d0: 0, budget: Self.startBudget)
        var used = machine.cycles
        var readying: [AmigaWrite] = []
        machine.takeWrites(into: &readying)
        let (count, waiting) = layout.voices(song, at: Self.moduleAddress)
        voices = count
        machine.poke32(Self.songEnd, waiting)
        machine.poke32(Self.songEndTemp, waiting)
        try call(layout.initAt, d0: UInt32(song + 1), budget: Self.startBudget)
        used += machine.cycles
        // (A song's end is looked for only once it has begun.)
        endings = 0
        machine.takeWrites(into: &startWrites)
        startWrites = readying + startWrites
        for i in startWrites.indices { startWrites[i].cycles = 0 }
        startCycles = used
        machine.advance(clocks: used / 2)
    }

    private mutating func call(_ offset: Int, d0: UInt32, budget: Int) throws(TuneError) {
        for r in 0 ..< 16 { machine.cpu.registers[r] = 0 }
        machine.cpu.registers[0] = d0
        let address = Self.moduleAddress &+ UInt32(truncatingIfNeeded: offset)
        machine.cpu.registers[8] = address
        let outcome = machine.call(address, stack: Self.stackTop, budget: budget)
        machine.takeSignals(into: &signals)
        for signal in signals where signal.register == 0 {
            endings += 1
        }
        guard outcome == .returned else { throw .malformed("Special FX's driver did not come back as it should") }
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < layout.songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        if lengths[song] == nil {
            // Played through in silence to its end: the tick it ends in is the first of it again, or the
            // first of the silence after it.
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

    /// Runs a tick: the driver's routine for it called, as the player's `DTP_Interrupt` calls it (after
    /// telling EaglePlayer the song has ended, for a song of no voices), and what it wrote told `output`
    /// at the moments it wrote it. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        feed.beginTick()
        if !startWrites.isEmpty {
            feed.tell(startWrites, &output)
            startWrites.removeAll(keepingCapacity: true)
        }
        if voices == 0 { endings += 1 }
        var failed = false
        do throws(TuneError) {
            try call(layout.playAt, d0: 0, budget: Self.tickBudget)
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

/// Special FX's music, played on Paula by `PaulaTickRenderer`.
extension SpecialFXPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Special FX")
        info.comment = layout.text
        info.detail = "Special FX's driver, of \(layout.sevenBranches ? "seven" : "four") ways in"
        return info
    }

    /// Special FX's music is louder on the Amiga's chip than ProTracker's is, by 1.7 dB in the middle of
    /// UnExoticA's 29 files, and is turned down by that (2026-10-19).
    var gain: Float { 0.38 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }

    /// What Paula's registers held as the tick began (see `AmigaPaulaFeed`).
    func period(_ voice: Int) -> UInt16 { feed.periods[voice] }
    func volume(_ voice: Int) -> UInt16 { feed.volumes[voice] }
    var lightFilter: Bool { feed.lightFilter }
}
