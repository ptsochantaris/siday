// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Ben Daglish's modules ("Benn Daglish player module V1.2
// (6 Mar 2004)", by Mr.Larmer, carried by UADE as players/BenDaglish; its source is UADE's
// amigasrc/players/wanted_team/BennDaglish/Benn Daglishv3.asm), and UADE's own host for such players
// (amigasrc/score/score.s), which calls them. The addresses given are of the player's code hunk, as a
// disassembly of the one UADE installs has them.

import SidayChips
import SidayFoundation
import SidayM68000

/// Ben Daglish's music for the Amiga, played by his own driver (Colin Dooley's sound player, as he
/// adapted it from game to game): each module is the 68000 code that plays it, which writes Paula's
/// registers itself, with the music and the samples after it. It is run on an emulated Amiga
/// (`AmigaMachine`), as UADE runs it with Wanted Team's EaglePlayer: the song started by the routine for
/// that, with the song's number, and then the routine for a tick called fifty times a second (a little
/// less: by the CIA's timer DeliTracker and UADE set for a player that has no timer of its own,
/// `TFMXTiming.fiftyTimes`). What it writes to Paula is heard at the moment it writes it within the tick.
///
/// The driver stops a sample that is not to go round again by Paula's interrupts: two ticks after the
/// sample begins (past the interrupt Paula asks for as she starts it), the voice's interrupt is cleared and
/// enabled, and the player's routine for it (`Audio`, $9EA) turns her DMA off as she next comes to the
/// end of the sample; the driver, finding it off, lets the note go. siday's Amiga has no interrupts, and Paula's timing is kept for them here
/// (`DaglishPaula`), and they are answered as the player's routine answers them, at the moment they come,
/// while the driver runs and between its ticks.
///
/// Before it is run, the module is changed as the player changes it (see `DaglishModule.Change`), and
/// its songs end as the player has them end: when the byte at 8 the driver keeps set while a song
/// plays is clear after a tick, and the song is started again, in the same tick ($910). Each song's
/// length is found by playing it through in silence.
struct DaglishPlayer: ~Copyable {
    /// Where the module is put: where UADE puts it, past the player and its own code.
    static let moduleAddress: UInt32 = 0xF000
    /// The stack, below the module, and the player's own code for its changes, below that.
    private static let stackTop: UInt32 = 0xE000
    private static let patchCode: UInt32 = AmigaMachine.hostSpace
    /// The room after the module that is kept empty, and where a voice that is pointed nowhere plays.
    private static let room = 0x20000 + 2048
    static let tickClocks = TFMXTiming.fiftyTimes
    /// How long a song is played through to find its end, at most: ten minutes, which is longer than
    /// UADE plays a song that does not end (512 seconds) and longer than any of UnExoticA's (338 seconds).
    private static let mostTicks = 50 * 60 * 10
    /// The processor's time a call is given: a song's start a fifth of a second, and a tick the whole of
    /// its frame, more than which no Amiga had to give it.
    private static let startBudget = 10 * AmigaMachine.frameCycles
    private static let tickBudget = AmigaMachine.frameCycles
    /// The processor's time a song's playing through in silence is given, and all of a module's songs'.
    private static let dryRunBudget: Int64 = 600_000_000
    private static let dryRunsBudget: Int64 = 3_000_000_000
    /// How often, in the processor's cycles, the driver is stopped as it runs, to take what it wrote and
    /// whether it has enabled an interrupt (it is also stopped as an interrupt may come or be answered).
    private static let slice = 64
    /// How long after a voice asks for her interrupt the player's routine has turned her DMA off: the
    /// 68000's taking the interrupt, UADE's host's finding whose it is (score.s, `mylevel4`) and the
    /// player's `Audio`. Found against UADE: of the times from none to 280 of Paula's clocks, those from
    /// 100 to 150 have the most of UnExoticA's songs written tick for tick as UADE writes them (where the
    /// end of a sample falls so near the driver's look at the DMA that it decides which tick it sees it in).
    private static let answerClocks: UInt64 = 150
    private func time(_ cycles: Int) -> UInt64 { machine.chips.now(cycles) }

    let layout: DaglishModule
    /// The module as the player has changed it, put into the machine afresh for each song, and the
    /// player's routines its changes call, each at its address.
    private let image: [UInt8]
    private let routines: [(at: UInt32, code: [UInt16])]
    private var machine: AmigaMachine
    private var paula: DaglishPaula
    private var feed: AmigaPaulaFeed
    /// What the tick wrote, each at its time in the tick (the processor's cycles, two to each of Paula's
    /// clocks), what a call wrote so far, and what the song's start wrote, heard as its first tick begins.
    private(set) var writes: [AmigaWrite] = []
    private var taken: [AmigaWrite] = []
    private(set) var startWrites: [AmigaWrite] = []
    /// Paula's time as the tick began.
    private var tickStart: UInt64 = 0
    /// The processor's cycles the song's start took, and the last tick.
    private(set) var startCycles = 0
    private(set) var tickCycles = 0
    /// The processor's cycles all the playings through so far have taken.
    private(set) var dryRuns: Int64 = 0
    /// How many interrupts of Paula's have been answered since the song began, and those taken and not
    /// yet answered: when their answer falls, and whose they are (their bits of INTREQ).
    private(set) var answered = 0
    private var answers: [(at: UInt64, voices: UInt16)] = []

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
    static func isOne(_ data: [UInt8]) -> Bool { DaglishModule.isOne(data) }

    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        var refusal: TuneError?
        let layout: DaglishModule
        do {
            layout = try DaglishModule(data)
        } catch {
            layout = .none
            refusal = error
        }
        self.layout = layout
        let made = Self.patch(data, layout)
        image = made.image
        routines = made.routines
        let size = (Int(Self.moduleAddress) + data.count + Self.room + 0xFFF) & ~0xFFF
        machine = AmigaMachine(chipRAM: size)
        paula = DaglishPaula(machine.chips)
        feed = AmigaPaulaFeed(memorySize: machine.memorySize)
        lengths = [UInt64??](repeating: nil, count: layout.songCount)
        // (Refused only once it is all made.)
        if let refusal { throw refusal }
        guard Int(Self.moduleAddress) + data.count + Self.room <= machine.memorySize else {
            throw .unsupported("a module of Ben Daglish's larger than the Amiga's chip RAM")
        }
        // (Its songs are played through, to find how long they are, when the renderer asks: `measure`.)
        self.song = song >= 0 && song < layout.songCount ? song : 0
        try start(self.song)
    }

    // MARK: The player's changes

    /// The module as the player changes it before it is run (`DTP_InitPlayer`, $79C to $84A), and the
    /// routines its calls go to. Of the player's routines, what is kept is what they do to the driver:
    /// each does the instructions it stands in place of, with the volume as the player's `ChangeVolume`
    /// ($218) leaves it (times its volume of 64, a sixty-fourth of it: as it was, but in D0, whose upper
    /// word that leaves as a MULU leaves it). What they also keep for EaglePlayer's scopes and its muting
    /// of voices changes nothing that is heard.
    static func patch(_ data: [UInt8], _ layout: DaglishModule) -> (image: [UInt8], routines: [(at: UInt32, code: [UInt16])]) {
        var bytes = data
        func put(_ words: [UInt16], at: Int) {
            for (i, word) in words.enumerated() where at + 2 * i + 1 < bytes.count && at + 2 * i >= 0 {
                bytes[at + 2 * i] = UInt8(word >> 8)
                bytes[at + 2 * i + 1] = UInt8(word & 0xFF)
            }
        }
        var routines: [(at: UInt32, code: [UInt16])] = []
        var next = patchCode
        func call(_ code: [UInt16], at: Int) {
            put([0x4E71, 0x4EB9, UInt16(next >> 16), UInt16(next & 0xFFFF)], at: at)
            routines.append((next, code + [0x4E75]))
            next += UInt32(code.count * 2 + 2)
        }
        // MULU.W #64,D0; LSR.W #6,D0: ChangeVolume's.
        let volume: [UInt16] = [0xC0FC, 0x0040, 0xEC48]
        for (change, at) in layout.changes {
            switch change {
            case .masking: put([0x4E71, 0x4E71, 0x4E71], at: at)
            case .returnFromException: put([0x4E75], at: at)
            case .restoring: put([0x4E71], at: at)
            case .vector: put([0x4E71, 0x4E71], at: at)
            case .sample:
                // MOVE.L A3,(A2); MOVE.W 8(A0),4(A2).
                call([0x248B, 0x3568, 0x0008, 0x0004], at: at)
            case let .earlyVolume(louder):
                if louder { put([0x4E71], at: at - 2) }
                // MOVE.W D0,8(A2); MOVE.L A3,26(A1).
                call(volume + [0x3540, 0x0008, 0x234B, 0x001A], at: at)
            case let .volume(after):
                // MOVE.W D0,8(A1), and the instruction after it.
                call(volume + [0x3340, 0x0008, UInt16(after >> 16), UInt16(after & 0xFFFF)], at: at)
            case let .noteVolume(after):
                // MOVE.L D0,-(A7); MOVE.L D2,D0; MOVE.W D0,8(A2); MOVE.L (A7)+,D0, and the instruction
                // after it.
                call([0x2F00, 0x2002] + volume + [0x3540, 0x0008, 0x201F, UInt16(after >> 16), UInt16(after & 0xFFFF)], at: at)
            }
        }
        return (bytes, routines)
    }

    // MARK: Playing

    /// Starts a song afresh, as UADE does: the machine switched on, the module put into it, and the
    /// song started as the player's `DTP_InitSound` ($862) starts it: the driver's routine for that (the
    /// first branch of its table) called with the song's number in D0. (The player first makes its
    /// routine Paula's interrupts', which enables them, $936; the driver disables them all again.)
    private mutating func start(_ song: Int) throws(TuneError) {
        machine.powerOn()
        for routine in routines {
            for (i, word) in routine.code.enumerated() { machine.poke16(routine.at + UInt32(2 * i), word) }
        }
        machine.load(image, at: Self.moduleAddress)
        machine.quietPaula()
        machine.chips.write16(AmigaChips.custom + 0x9A, 0xC780)
        paula.reset()
        feed.reset()
        endings = 0
        stops = 0
        answered = 0
        answers.removeAll()
        writes.removeAll(keepingCapacity: true)
        tickStart = 0
        guard call(0, d0: UInt32(song), budget: Self.startBudget) else {
            throw .malformed("Ben Daglish's driver did not come back as it should")
        }
        startCycles = machine.cycles
        machine.advance(clocks: startCycles / 2)
        catchUp(to: machine.chips.clock)
        swap(&startWrites, &writes)
        writes.removeAll(keepingCapacity: true)
        for i in startWrites.indices { startWrites[i].cycles = 0 }
        tickStart = machine.chips.clock
    }

    /// Calls the driver at `offset` into the module, with A0 the module's address (as the player calls
    /// it) and D0 as given, stopping it every `slice` cycles to take what it wrote and to answer Paula's
    /// interrupts. False if it did not come back as it should.
    private mutating func call(_ offset: Int, d0: UInt32, budget: Int) -> Bool {
        for r in 0 ..< 16 { machine.cpu.registers[r] = 0 }
        machine.cpu.registers[0] = d0
        let address = Self.moduleAddress &+ UInt32(truncatingIfNeeded: offset)
        machine.cpu.registers[8] = Self.moduleAddress
        machine.poke32(Self.stackTop &- 4, AmigaMachine.returnAddress)
        machine.cpu.registers[15] = Self.stackTop &- 4
        machine.cpu.pc = address
        var stop = machine.cpu.run(cycles: min(budget, Self.slice))
        while true {
            take()
            catchUp(to: time(machine.cycles))
            // (One the driver enabled, or that it left asked for as it enabled it, is taken at once.)
            interrupted(at: time(machine.cycles))
            switch stop {
            case .outOfTime where machine.cycles < budget:
                stop = machine.cpu.resume(cycles: min(budget, nextStop()))
            case .reset:
                return true
            default:
                return false
            }
        }
    }

    /// Where the driver is next stopped, in the processor's cycles into the call: a slice on, or sooner,
    /// as an answer to an interrupt falls, or as a voice whose interrupt is enabled may ask for one.
    private func nextStop() -> Int {
        let now = machine.cycles
        let chips = machine.chips
        var at = answers.first?.at ?? .max
        if chips.intena & 0x4000 != 0, let step = paula.nextStep(of: chips.intena) { at = min(at, step) }
        var soonest = now + Self.slice
        if at != .max, at > chips.clock {
            soonest = min(soonest, Int(min((at - chips.clock) * 2, 1 << 30)) + 1)
        }
        return max(now + 1, soonest)
    }

    /// Takes what the driver wrote since this was last done: each write told Paula's timing at its time,
    /// and kept for the tick at its time in it.
    private mutating func take() {
        machine.takeWrites(into: &taken)
        for write in taken {
            let at = time(write.cycles)
            catchUp(to: at)
            while let asked = paula.write(write.register, write.value, at: at) { interrupted(at: asked) }
            writes.append(AmigaWrite(cycles: Int(2 * (at &- tickStart)), register: write.register, value: write.value))
        }
    }

    /// Takes Paula's time on to `time`, answering her interrupts as their answers fall.
    private mutating func catchUp(to time: UInt64) {
        while true {
            let next = answers.first?.at ?? .max
            if let asked = paula.run(to: min(next, time)) {
                interrupted(at: asked)
            } else if next <= time {
                let first = answers.removeFirst()
                answer(first.voices, at: first.at)
            } else {
                return
            }
        }
    }

    /// An interrupt of Paula's, asked for at `time`: taken if it is enabled, as UADE's host takes it
    /// (score.s, `mylevel4`, which hands it to the player's routine for it), and answered (`answer`)
    /// `answerClocks` later, the driver waiting meanwhile.
    private mutating func interrupted(at time: UInt64) {
        let chips = machine.chips
        guard chips.intena & 0x4000 != 0 else { return }
        var voices = chips.intena & chips.intreq & 0x0780
        for waiting in answers { voices &= ~waiting.voices }
        guard voices != 0 else { return }
        answers.append((time + Self.answerClocks, voices))
    }

    /// The answer of the player's `Audio` ($9EA) to interrupts of Paula's: each voice's interrupt
    /// disabled and cleared, and her DMA turned off: in the machine, as the driver will next find it; in
    /// Paula's timing; and heard as it falls, kept with the tick's writes (not the machine's, which are the
    /// driver's).
    private mutating func answer(_ voices: UInt16, at time: UInt64) {
        let chips = machine.chips
        answered += 1
        chips.write16(AmigaChips.custom + 0x9A, voices)
        chips.write16(AmigaChips.custom + 0x9C, voices)
        chips.write16(AmigaChips.custom + 0x96, voices >> 7)
        chips.writes.removeLast()
        while let asked = paula.write(0x096, voices >> 7, at: time) { interrupted(at: asked) }
        writes.append(AmigaWrite(cycles: Int(2 * (max(time, tickStart) - tickStart)), register: 0x096, value: voices >> 7))
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < layout.songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        try measure(song)
        lengthClocks = lengths[song] ?? nil
        try start(song)
    }

    var measured: [UInt64??]? { lengths }

    mutating func measure(_ song: Int) throws(TuneError) {
        guard lengths.indices.contains(song), lengths[song] == nil else { return }
        // Played through in silence to its end: the tick it ends in is its last.
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
        lengths[song] = .some(endings > 0 || stops > 0 ? UInt64(ticks) * UInt64(Self.tickClocks) : nil)
    }

    mutating func adopt(_ given: [UInt64?]) {
        lengths = given.map { .some($0) }
    }

    /// Runs a tick as the player's `DTP_Interrupt` ($8E2) does: the driver's routine for it (the second
    /// branch of its table) called, and, if the byte at 8 is then clear, the song's end told and the song
    /// started again ($910). What it wrote, and what answering Paula's interrupts in the tick did, is
    /// told `output` at the moments they fell. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        feed.beginTick()
        if !startWrites.isEmpty {
            feed.tell(startWrites, &output)
            startWrites.removeAll(keepingCapacity: true)
        }
        writes.removeAll(keepingCapacity: true)
        tickStart = machine.chips.clock
        var failed = !call(4, d0: 0, budget: Self.tickBudget)
        tickCycles = machine.cycles
        if !failed, machine.peek8(Self.moduleAddress + 8) == 0 {
            endings += 1
            machine.advance(clocks: tickCycles / 2)
            failed = !call(0, d0: UInt32(song), budget: Self.startBudget)
            tickCycles += machine.cycles
        }
        let end = tickStart + UInt64(Self.tickClocks)
        catchUp(to: end - 1)
        take()
        // (Nothing is heard past the tick's end: an answer that would be is heard as it ends.)
        let last = 2 * (Self.tickClocks - 1)
        for i in writes.indices where writes[i].cycles > last { writes[i].cycles = last }
        Self.sortByTime(&writes)
        feed.tell(writes, &output)
        machine.advance(clocks: end > machine.chips.clock ? Int(end - machine.chips.clock) : 0)
        // (Code that does not come back has gone wrong, and the song is over.)
        if failed { stops += 1 }
        return 20
    }

    /// Puts the writes in the order of their times, keeping the order of those at the same time.
    private static func sortByTime(_ list: inout [AmigaWrite]) {
        guard list.count > 1 else { return }
        for i in 1 ..< list.count {
            let write = list[i]
            var j = i
            while j > 0, list[j - 1].cycles > write.cycles {
                list[j] = list[j - 1]
                j -= 1
            }
            list[j] = write
        }
    }

    private struct Unheard: TFMXOutput {
        mutating func on(_: Int) {}
        mutating func off(_: Int) {}
        mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
        func loopCount(_: Int) -> UInt16 { 0 }
    }
}

/// Ben Daglish's music, played on Paula by `PaulaTickRenderer`.
extension DaglishPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        TuneInfo(format: "Ben Daglish")
    }

    /// Ben Daglish's music is louder on the Amiga's chip than ProTracker's is, by 6.4 dB in the middle
    /// of UnExoticA's 41 files, and is turned down by that (2026-10-19).
    var gain: Float { 0.22 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }

    /// What Paula's registers held as the tick began (see `AmigaPaulaFeed`).
    func period(_ voice: Int) -> UInt16 { feed.periods[voice] }
    func volume(_ voice: Int) -> UInt16 { feed.volumes[voice] }
    var lightFilter: Bool { feed.lightFilter }
}
