// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for David Whittaker's modules ("David Whittaker player module
// V1.0 (11 Nov 2000)", carried by UADE as players/DavidWhittaker), of which there is no source, and
// UADE's own host for such players (amigasrc/score/score.s), which calls them. The addresses given are
// of the player's code hunk, as a disassembly of it has them.

import SidayChips
import SidayFoundation
import SidayM68000

/// David Whittaker's music for the Amiga, played by his own driver: each module is the 68000 code he
/// wrote to play it, which writes Paula's registers itself, with the music and the samples after it.
/// It is run on an emulated Amiga (`AmigaMachine`), as UADE runs it with Wanted Team's EaglePlayer:
/// the song started by its routine for that, with the song's number, and then its routine for a tick
/// called fifty times a second (a little less: by the CIA's timer DeliTracker and UADE set for a player
/// that has no timer of its own, `TFMXTiming.fiftyTimes`). What it writes to Paula is heard at the
/// moment it writes it within the tick.
///
/// Before it is run, the module is changed as the player changes it (see `WhittakerModule` and
/// `patch(_:)`), and its songs end as the player has them end: when every voice has gone back to the
/// start of its list of patterns since the song began or last ended, or when the driver stops the music
/// (`MOVE.W #$FF,$DFF09E`, which only its routine that stops it writes) other than as a song is started.
/// Each song's length is found by playing it through in silence.
struct WhittakerPlayer: ~Copyable {
    /// Where the module is put: where UADE puts it, past the player and its own code.
    static let moduleAddress: UInt32 = 0x11000
    /// The stack, below the module, and the player's own code for its patches, below that.
    private static let stackTop: UInt32 = 0x10000
    private static let patchCode: UInt32 = AmigaMachine.hostSpace + 0x10
    /// An envelope of volume that stays at nothing, which the player gives a voice before it has one
    /// (its own, at $1000: eight bytes of $80, each an end that is not stepped past, of volume nought).
    private static let emptyEnvelope: UInt32 = AmigaMachine.hostSpace
    /// What the patches tell the host through its port: a voice gone back to the start of its list of
    /// patterns (a long, the voice's registers' address in A6), and the music stopped.
    private static let wrappedPort: UInt32 = AmigaChips.hostPort
    private static let stoppedPort: UInt32 = AmigaChips.hostPort + 4
    /// The room after the module that is kept empty, and where a voice that is pointed nowhere plays.
    private static let room = 0x20000 + 2048
    static let tickClocks = TFMXTiming.fiftyTimes
    /// How long a song is played through to find its end, at most: ten minutes, which is longer than
    /// UADE plays a song that does not end (512 seconds) and longer than any of UnExoticA's that does
    /// (323 seconds). (Running the driver's code costs more than a player's own tick does, and a module
    /// may have a dozen songs that never end, each played through as the module is loaded.)
    private static let mostTicks = 50 * 60 * 10
    /// The processor's time a call is given: a song's start a fifth of a second (the most any of
    /// UnExoticA's modules takes is 12,000 cycles), and a tick the whole of its frame (the most is
    /// 18,000), more than which no Amiga had to give it.
    private static let startBudget = 10 * AmigaMachine.frameCycles
    private static let tickBudget = AmigaMachine.frameCycles
    /// The processor's time a song's playing through in silence is given, and all of a module's songs':
    /// six times what the busiest of UnExoticA's takes for ten minutes (93 million cycles), and more than
    /// twice what its modules of the most songs that never end take (1.33 billion), and no more, for a
    /// module that is broken.
    private static let dryRunBudget: Int64 = 600_000_000
    private static let dryRunsBudget: Int64 = 3_000_000_000

    let layout: WhittakerModule
    /// The module as the player has changed it, put into the machine afresh for each song.
    private let image: [UInt8]
    private var machine: AmigaMachine
    private var feed: AmigaPaulaFeed
    private(set) var writes: [AmigaWrite] = []
    private var signals: [AmigaWrite] = []
    /// What the song's start wrote to Paula, heard as its first tick begins.
    private(set) var startWrites: [AmigaWrite] = []
    /// The voices that have not yet gone back to the start of their lists since the song began or last
    /// ended, a byte each as the player keeps them ($23C): a song of three voices has its fourth's clear.
    private var notWrapped: UInt32 = 0
    private let allVoices: UInt32
    /// The upper word of the voice's address a patch is telling.
    private var wrappedHigh: UInt16 = 0
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
    var songCount: Int { layout.songCount }

    /// True for a module the player's check takes.
    static func isOne(_ data: [UInt8]) -> Bool { WhittakerModule.kind(of: data) != nil }

    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        var refusal: TuneError?
        let layout: WhittakerModule
        do {
            layout = try WhittakerModule(data)
        } catch {
            layout = .none
            refusal = error
        }
        self.layout = layout
        image = Self.patch(data, layout)
        allVoices = layout.voices == 4 ? 0x0101_0101 : 0x0101_0100
        let size = (Int(Self.moduleAddress) + data.count + Self.room + 0xFFF) & ~0xFFF
        machine = AmigaMachine(chipRAM: size)
        feed = AmigaPaulaFeed(memorySize: machine.memorySize)
        lengths = [UInt64??](repeating: nil, count: layout.songCount)
        // (Refused only once it is all made.)
        if let refusal { throw refusal }
        guard Int(Self.moduleAddress) + data.count + Self.room <= machine.memorySize else {
            throw .unsupported("a module of David Whittaker's larger than the Amiga's chip RAM")
        }
        guard layout.audioInterrupt == nil else {
            throw .unsupported("a module of Rob Hubbard's whose driver runs from Paula's interrupts, which are not run here")
        }
        try select(song: song >= 0 && song < layout.songCount ? song : 0)
    }

    // MARK: The player's changes

    /// The module as the player changes it before it is run: the flags of a driver that has readied its
    /// samples cleared, the choosing of a song at random made NOPs ($5E0), and the patches of its
    /// `EP_ModuleChange` ($46A), as UADE's host makes them (`epg_modulechange`): each of the patterns
    /// below found, a word at a time, from the module's start to its table of songs, and made a JSR to
    /// the player's code for it, followed by NOPs.
    ///
    /// The player has more patterns than these, for EaglePlayer's scopes, its volume and its muting of
    /// voices, which change nothing that is heard (as Paula takes them); they are left out, as they
    /// meet none of these in any of UnExoticA's modules. What is made of those that are kept does what the
    /// player's does, and tells the host through its port where the player calls EaglePlayer.
    static func patch(_ data: [UInt8], _ layout: WhittakerModule) -> [UInt8] {
        var bytes = data
        for at in layout.cleared where at >= 0 && at < bytes.count { bytes[at] = 0 }
        if let nops = layout.madeNOPs {
            for at in stride(from: nops.lowerBound, to: nops.upperBound - 1, by: 2) where at + 1 < bytes.count {
                bytes[at] = 0x4E
                bytes[at + 1] = 0x71
            }
        }
        var routines: [(pattern: [UInt16], at: UInt32)] = []
        var at = patchCode
        for routine in Self.patches(layout) {
            routines.append((routine.pattern, at))
            at += UInt32(routine.code.count * 2)
        }
        let length = layout.songTable
        for (pattern, address) in routines {
            var a0 = 0
            var left = length
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

    /// The patterns kept, in the order of the player's table of them ($C70 for a module of kind 0, $C1A
    /// for the others), and the code each is made a call of.
    private static func patches(_ layout: WhittakerModule) -> [(pattern: [UInt16], code: [UInt16])] {
        let wrapped = [0x23CE, UInt16(wrappedPort >> 16), UInt16(wrappedPort & 0xFFFF)]
        var list: [(pattern: [UInt16], code: [UInt16])] = []
        // A voice's list of patterns: at its end (a nought), back to its start ($CAE, $CBE). TST.W
        // 0(A3,A2.W); BNE +6; MOVEA.W 8(A0),A2; MOVEQ #2,D0; MOVEA.W 0(A3,A2.W),A1.
        list.append(([0x4A73, 0xA000, 0x6606, 0x3468, 0x0008, 0x7002, 0x3273, 0xA000],
                     [0x4A73, 0xA000, 0x660C] + wrapped + [0x3468, 0x0008, 0x7002, 0x3273, 0xA000, 0x4E75]))
        if layout.flag != 0 {
            // The same, of longs ($D34, $D40). TST.L (A2); BNE +6; MOVEA.L 8(A0),A2; MOVEQ #4,D0;
            // MOVEA.L (A2),A1.
            list.append(([0x4A92, 0x6606, 0x2468, 0x0008, 0x7004, 0x2252],
                         [0x4A92, 0x660C] + wrapped + [0x2468, 0x0008, 0x7004, 0x2252, 0x4E75]))
        }
        // The music stopped ($F6C, $F74): MOVE.W #$FF,$DFF09E.
        list.append(([0x33FC, 0x00FF, 0x00DF, 0xF09E],
                     [0x33FC, 0x00FF, 0x00DF, 0xF09E,
                      0x33FC, 0x0001, UInt16(stoppedPort >> 16), UInt16(stoppedPort & 0xFFFF), 0x4E75]))
        if layout.flag != 0 {
            // A wait for the DMA, by the processor's time, made a wait of nine lines of the beam ($FA6,
            // $FB2): MOVE.W #$100,D1; DBF D1,*.
            list.append(([0x323C, 0x0100, 0x51C9, 0xFFFE],
                         [0x48E7, 0xC000, 0x7008, 0x1239, 0x00DF, 0xF006, 0xB239, 0x00DF, 0xF006, 0x67F8,
                          0x57C8, 0xFFF0, 0x4CDF, 0x0003, 0x4E75]))
        }
        if layout.flag != 0xFF {
            // A voice readied as a song starts, given the empty envelope and the first sample's header,
            // where the driver gives it neither before its first note ($FD0, $FD8): MOVE.L A0,12(A1);
            // MOVE.L A0,16(A1).
            var code: [UInt16] = [0x2348, 0x000C, 0x2348, 0x0010,
                                  0x237C, UInt16(emptyEnvelope >> 16), UInt16(emptyEnvelope & 0xFFFF), 0x0026]
            if let header = layout.firstSampleHeader {
                let address = moduleAddress &+ UInt32(truncatingIfNeeded: header)
                code += [0x237C, UInt16(address >> 16), UInt16(address & 0xFFFF), 0x0018]
            }
            list.append(([0x2348, 0x000C, 0x2348, 0x0010], code + [0x4E75]))
        }
        return list
    }

    // MARK: Playing

    /// Starts a song afresh, as UADE does: the machine switched on, the module put into it, and the
    /// song started as the player's `DTP_InitSound` ($888) starts it: its routine for that called with
    /// the song's number in D0, after the seventh of its table if it has one.
    private mutating func start(_ song: Int) throws(TuneError) {
        machine.powerOn()
        var at = Self.patchCode
        for routine in Self.patches(layout) {
            for word in routine.code {
                machine.poke16(at, word)
                at += 2
            }
        }
        for i in 0 ..< 8 { machine.poke8(Self.emptyEnvelope + UInt32(i), 0x80) }
        machine.load(image, at: Self.moduleAddress)
        machine.quietPaula()
        feed.reset()
        notWrapped = allVoices
        endings = 0
        stops = 0
        startingSong = true
        defer { startingSong = false }
        var used = 0
        if let setUp = layout.setUpAt {
            try call(setUp, d0: 0, budget: Self.startBudget)
            used += machine.cycles
        }
        try call(layout.initAt, d0: UInt32(song), budget: Self.startBudget)
        used += machine.cycles
        machine.takeWrites(into: &startWrites)
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
        takeSignals()
        guard outcome == .returned else { throw .malformed("David Whittaker's driver did not come back as it should") }
    }

    /// What the patches have told the host: a voice gone back to its start, and the song's end once
    /// every voice has since it began or last ended ($CBE, $D40); and the music stopped ($F74), which is
    /// the song's end unless a song is being started.
    private mutating func takeSignals() {
        machine.takeSignals(into: &signals)
        for signal in signals {
            switch UInt32(signal.register) {
            case 0:
                wrappedHigh = signal.value
            case 2:
                let a6 = UInt32(wrappedHigh) << 16 | UInt32(signal.value)
                if a6 >= AmigaChips.custom, a6 <= AmigaChips.custom + 0x30, a6 & 0xF == 0 {
                    notWrapped &= ~(0xFF00_0000 >> ((a6 - AmigaChips.custom) >> 1))
                }
                if notWrapped == 0 {
                    notWrapped = allVoices
                    endings += 1
                }
            case 4:
                if !startingSong { stops += 1 }
            default:
                break
            }
        }
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

    /// Runs a tick: the driver's routine for it called ($948), as the player's `DTP_Interrupt` calls it,
    /// and what it wrote told `output` at the moments it wrote it. Returns the tick's length in
    /// milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        feed.beginTick()
        if !startWrites.isEmpty {
            feed.tell(startWrites, &output)
            startWrites.removeAll(keepingCapacity: true)
        }
        if layout.restoresVolume {
            // (Before each tick, the player puts a word of the driver's back to 64, $96E.)
            machine.poke16(Self.moduleAddress &+ UInt32(layout.playAt + 1478), 0x40)
        }
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

/// David Whittaker's music, played on Paula by `PaulaTickRenderer`.
extension WhittakerPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        TuneInfo(format: "David Whittaker")
    }

    /// David Whittaker's music is louder on the Amiga's chip than ProTracker's is, by 4.6 dB in the
    /// middle of UnExoticA's 115 modules, and is turned down by that (2026-10-19).
    var gain: Float { 0.27 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }

    /// What Paula's registers held as the tick began (see `AmigaPaulaFeed`).
    func period(_ voice: Int) -> UInt16 { feed.periods[voice] }
    func volume(_ voice: Int) -> UInt16 { feed.volumes[voice] }
    var lightFilter: Bool { feed.lightFilter }
}
