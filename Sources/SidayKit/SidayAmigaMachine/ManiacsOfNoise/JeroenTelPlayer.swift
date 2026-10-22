// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Jeroen Tel's modules ("Jeroen Tel player module V1.0 (27 Oct
// 2004)", carried by UADE as players/JeroenTel, whose source UADE carries as amigasrc/players/wanted_team/
// JeroenTel/Jeroen Tel_v1.asm: its routines and labels are named here as it names them), and UADE's host
// for such players (amigasrc/score/score.s), which calls them.

/// The music of the Maniacs of Noise of 1989 and 1990 (Jeroen Tel's, Charles Deenen's and their
/// friends'), played by their driver of then: each module is the driver's 68000 code with the music and
/// the samples after it, as it was taken out of a game's memory, at the addresses it had there. It is
/// put back at them on an emulated Amiga (`AmigaMachine`), and run as UADE runs Wanted Team's copy of it:
/// a song started as the player starts it, and then, fifty times a second (a little less: by the CIA's
/// timer DeliTracker and UADE set for a player that has no timer of its own, `TFMXTiming.fiftyTimes`),
/// the driver's first half of a tick called, a wait for nine lines of the beam, and its second half.
/// What it writes to Paula is heard at the moment it writes it within the tick.
///
/// The player does not call the file's own code, but its own copy of the driver of "Unreal" (`Play_1`,
/// `Play_2`), with every address the driver reads moved from where the game had it to where the file
/// is, and a few changes of Wanted Team's. The file's driver is the same (see `JeroenTelModule`), and is
/// run here with those changes made to it (`patch`): the table of periods read no further than its
/// end, a voice's volume given no louder than 64, a sample of no address played from a silence, and the
/// player told of the song's end. Its variables are set as the player sets its copy's (`InitSound`),
/// rather than by the driver's own start, which is not in every file.
///
/// A song ends as the player has it end: when one of its voices comes to the end of its list of patterns
/// (where the driver sets every voice back to where it starts again), or when its list says to stop the
/// music. Each song's length is found by playing it through in silence.
struct JeroenTelPlayer: ~Copyable {
    /// The room after the module that is kept empty, where a voice that is pointed nowhere plays, and
    /// where in it the silence is (`Fix`, 34 bytes of nought) that the player gives a sample of no address.
    private static let room = 0x20000 + 2048
    private static let silence = 64
    /// The host's own code (the patches and the calls), and below it its stack, after the room.
    private static let hostSize: UInt32 = 0x1000
    static let tickClocks = TFMXTiming.fiftyTimes
    /// How long a song is played through to find its end, at most: ten minutes, which is longer than
    /// UADE plays a song that does not end (512 seconds).
    private static let mostTicks = 50 * 60 * 10
    /// The processor's time a call is given: a song's start a fifth of a second, and a tick the whole of
    /// its frame, more than which no Amiga had to give it.
    private static let startBudget = 10 * AmigaMachine.frameCycles
    private static let tickBudget = AmigaMachine.frameCycles
    /// The processor's time a song's playing through in silence is given, and all of a module's songs'.
    private static let dryRunBudget: Int64 = 600_000_000
    private static let dryRunsBudget: Int64 = 3_000_000_000
    /// What the patches tell the host through its port: a voice at the end of its list of patterns, and
    /// the music stopped.
    private static let wrappedPort: UInt32 = AmigaChips.hostPort
    private static let stoppedPort: UInt32 = AmigaChips.hostPort + 4

    let layout: JeroenTelModule
    /// The file as the player's changes make it, put into the machine afresh for each song.
    private let image: [UInt8]
    /// Where the host's space is (its stack, then its code), its code, and in it the calls of a tick and
    /// of a song's start.
    private let hostAt: UInt32
    private let hostCode: [UInt16]
    private let tickAt: UInt32
    private let startAt: UInt32
    private var machine: AmigaMachine
    private var feed: AmigaPaulaFeed
    private(set) var writes: [AmigaWrite] = []
    private var signals: [AmigaWrite] = []
    /// What the song's start wrote to Paula, heard as its first tick begins.
    private(set) var startWrites: [AmigaWrite] = []
    /// The processor's cycles the last tick took, and all the playings through so far.
    private(set) var tickCycles = 0
    private(set) var dryRuns: Int64 = 0

    private(set) var song = 0
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    private var lengths: [UInt64??]

    var memory: UnsafeMutablePointer<UInt8> { machine.memory }
    var memoryCapacity: Int { machine.memorySize }
    var silenceAt: Int { Int(layout.origin) + image.count + Self.room / 2 }
    var mixingAt: Int { silenceAt }
    var songCount: Int { layout.songCount }

    /// True for a module the player's check (`DTP_Check2`) takes.
    static func isOne(_ data: [UInt8]) -> Bool { JeroenTelModule.driver(in: data) != nil }

    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        var refusal: TuneError?
        let layout: JeroenTelModule
        do {
            layout = try JeroenTelModule(data)
        } catch {
            layout = .none
            refusal = error
        }
        self.layout = layout
        let hostAt = (layout.origin &+ UInt32(data.count) &+ UInt32(Self.room) &+ 0xFF) & ~0xFF
        self.hostAt = hostAt
        let made = Self.patch(data, layout, code: hostAt &+ Self.hostSize / 2,
                              silence: layout.origin &+ UInt32(data.count) &+ UInt32(Self.silence))
        image = made.image
        hostCode = made.code
        tickAt = made.tick
        startAt = made.start
        machine = AmigaMachine(chipRAM: Int(hostAt &+ Self.hostSize))
        feed = AmigaPaulaFeed(memorySize: machine.memorySize)
        lengths = [UInt64??](repeating: nil, count: layout.songCount)
        // (Refused only once it is all made.)
        if let refusal { throw refusal }
        guard Int(hostAt &+ Self.hostSize) <= machine.memorySize else {
            throw .unsupported("a module of Jeroen Tel's larger than the Amiga's chip RAM")
        }
        try select(song: song >= 0 && song < layout.songCount ? song : 0)
    }

    // MARK: The player's changes

    /// The file as the player's changes make it, and the host's code, put at `code`: each instruction of
    /// the driver's that the player has otherwise made a JSR to the host's code for it (and NOPs), which
    /// does what the player's does, with the driver's own instructions; and the host's calls of the
    /// driver, for a tick and for a song's start.
    static func patch(_ data: [UInt8], _ layout: JeroenTelModule, code at: UInt32, silence: UInt32)
        -> (image: [UInt8], code: [UInt16], tick: UInt32, start: UInt32)
    {
        var bytes = data
        var code: [UInt16] = []
        guard layout.songCount > 0 else { return (bytes, code, at, at) }
        func long(_ value: UInt32) -> [UInt16] { [UInt16(value >> 16), UInt16(value & 0xFFFF)] }
        func word(_ offset: Int) -> UInt16 {
            offset >= 0 && offset + 1 < data.count ? UInt16(data[offset]) << 8 | UInt16(data[offset + 1]) : 0
        }
        func words(_ offset: Int, _ count: Int) -> [UInt16] { (0 ..< count).map { word(offset + 2 * $0) } }
        func replace(_ offset: Int, _ length: Int, with routine: [UInt16]) {
            let jsr = [0x4EB9] + long(at &+ UInt32(code.count * 2)) + [UInt16](repeating: 0x4E71, count: (length - 6) / 2)
            code += routine
            guard offset >= 0, offset + length <= bytes.count else { return }
            for (i, word) in jsr.enumerated() {
                bytes[offset + 2 * i] = UInt8(word >> 8)
                bytes[offset + 2 * i + 1] = UInt8(word & 0xFF)
            }
        }
        let rts: UInt16 = 0x4E75
        // The end of a voice's list of patterns (`SongEnd`, at `lbC000078`): told, and the positions set
        // back as the driver sets them.
        replace(layout.wrapAt, layout.wrapLength,
                with: [0x33FC, 0x0001] + long(wrappedPort) + words(layout.wrapAt, layout.wrapLength / 2) + [rts])
        // The music stopped (`lbC000586`): told, and stopped (and in "Onslaught", whose driver only turns
        // the DMA off, the driver stopped too, as the player's is).
        let stopping: [UInt16] = layout.stopLength == 8 ? [0x4239] + long(layout.playing) : []
        replace(layout.stopAt, layout.stopLength,
                with: [0x33FC, 0x0001] + long(stoppedPort) + stopping + words(layout.stopAt, layout.stopLength / 2) + [rts])
        // The table of periods read no further than its 36th (`PerOk1`, `PerOk2`): an index of 72 or more
        // made 70. ASL.B #1,D2; MOVEA.L #periods,A3; CMP.W #72,D2; BLT.S +2; MOVEQ #70,D2; MOVE.W
        // 0(A3,D2),D2. And MOVEA.L #periods,A3; ASL.B #1,D1; CMP.W #72,D1; BLT.S +2; MOVEQ #70,D1;
        // MOVE.W 0(A3,D1),14(A5).
        let first = layout.periodReads[0], second = layout.periodReads[1]
        replace(first, 12, with: words(first, 4) + [0xB47C, 0x0048, 0x6D02, 0x7446] + words(first + 8, 2) + [rts])
        replace(second, 14, with: words(second, 4) + [0xB27C, 0x0048, 0x6D02, 0x7246] + words(second + 8, 3) + [rts])
        // A voice's volume no more than 64 (`NoMaxVol`): MOVE.W 18(A5),D0; CMP.W #64,D0; BLE.S +2; MOVEQ
        // #64,D0; MOVE.W D0,2(A4,D3).
        replace(layout.volumeAt, 6,
                with: [0x302D, 0x0012, 0xB07C, 0x0040, 0x6F02, 0x7040, 0x3980, word(layout.volumeAt + 4), rts])
        // The sample a voice goes on to, if it has no address, the silence (`NoZero`, `Fix`): TST.L 8(A3);
        // BNE.S +10; MOVE.L #silence,0(A4,D3); RTS; MOVE.L 8(A3),0(A4,D3).
        replace(layout.loopAt, 6, with: [0x4AAB, 0x0008, 0x660A, 0x29BC] + long(silence) + [word(layout.loopAt + 4), rts]
            + words(layout.loopAt, 3) + [rts])
        // A tick (`Interrupt`): the first half, a wait for nine lines of the beam (`DMAWait`), the second.
        let tick = at &+ UInt32(code.count * 2)
        code += [0x4EB9] + long(layout.origin &+ UInt32(layout.playAt))
        code += [0x7008, 0x1239, 0x00DF, 0xF006, 0xB239, 0x00DF, 0xF006, 0x67F8, 0x57C8, 0xFFF0]
        code += [0x4EB9] + long(layout.origin &+ UInt32(layout.secondAt)) + [0x4E70]
        // A song's start (`Init`): every voice's DMA off.
        let start = at &+ UInt32(code.count * 2)
        code += [0x33FC, 0x000F, 0x00DF, 0xF096, 0x4E70]
        return (bytes, code, tick, start)
    }

    // MARK: Playing

    /// Starts a song afresh, as UADE does: the machine switched on, the file put back where it was, and
    /// the driver's variables set as the player's `InitSound` sets its copy's: all of them cleared but
    /// for each voice's bit of the DMA, to turn it off and on, and the offset of its registers from
    /// Paula's first; the song's lists of patterns given to its voices (`Init`), each voice's envelope
    /// put at its sustain (2, at 5 in the voice's variables), the song's voices and the ticks of its steps;
    /// every voice's DMA turned off, the driver set playing, and each voice given the silence for its
    /// instrument (`FixUp`).
    private mutating func start(_ song: Int) throws(TuneError) {
        machine.powerOn()
        machine.load(image, at: layout.origin)
        var at = hostAt &+ Self.hostSize / 2
        for word in hostCode {
            machine.poke16(at, word)
            at += 2
        }
        machine.quietPaula()
        feed.reset()
        endings = 0
        stops = 0
        var address = layout.playing &- 4
        while address < layout.voiceTable {
            machine.poke8(address, 0)
            address += 1
        }
        let entry = layout.origin &+ UInt32(layout.songTable + 18 * song)
        for (v, voice) in layout.voices.enumerated() {
            machine.poke16(voice &+ 0x14, 1 << UInt16(v))
            machine.poke16(voice &+ 0x16, 0x8000 | 1 << UInt16(v))
            machine.poke16(voice &+ 8, UInt16(v * 16) << 8)
            machine.poke8(voice &+ 5, 2)
            machine.poke32(voice &+ 0x1C, machine.peek32(entry &+ UInt32(4 * v)))
        }
        machine.poke8(layout.playing &- 1, machine.peek8(entry &+ 16))
        machine.poke8(layout.playing &- 2, machine.peek8(entry &+ 17))
        try call(startAt, budget: Self.startBudget)
        let used = machine.cycles
        machine.poke8(layout.playing, 1)
        let silence = layout.origin &+ UInt32(image.count) &+ UInt32(Self.silence)
        for voice in layout.voices { machine.poke32(voice &+ 0x18, silence) }
        machine.takeWrites(into: &startWrites)
        for i in startWrites.indices { startWrites[i].cycles = 0 }
        machine.advance(clocks: used / 2)
    }

    private mutating func call(_ address: UInt32, budget: Int) throws(TuneError) {
        for r in 0 ..< 16 { machine.cpu.registers[r] = 0 }
        let outcome = machine.call(address, stack: hostAt &+ Self.hostSize / 2, budget: budget)
        takeSignals()
        guard outcome == .returned else { throw .malformed("Jeroen Tel's driver did not come back as it should") }
    }

    /// What the patches have told the host: the end of a voice's list, which is the song's end, and the
    /// music stopped.
    private mutating func takeSignals() {
        machine.takeSignals(into: &signals)
        for signal in signals {
            switch UInt32(signal.register) {
            case 0: endings += 1
            case 4: stops += 1
            default: break
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

    /// Runs a tick, as the player's `Interrupt` does (see `patch`), and tells `output` what the driver
    /// wrote at the moments it wrote it. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        feed.beginTick()
        if !startWrites.isEmpty {
            feed.tell(startWrites, &output)
            startWrites.removeAll(keepingCapacity: true)
        }
        var failed = false
        do throws(TuneError) {
            try call(tickAt, budget: Self.tickBudget)
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

/// Jeroen Tel's music, played on Paula by `PaulaTickRenderer`.
extension JeroenTelPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Jeroen Tel")
        info.comment = layout.text
        return info
    }

    /// Jeroen Tel's music is quieter on the Amiga's chip than ProTracker's is, by 1.0 dB in the middle of
    /// UnExoticA's 17 files, and is turned up by that (2026-10-19).
    var gain: Float { 0.52 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }

    /// What Paula's registers held as the tick began (see `AmigaPaulaFeed`).
    func period(_ voice: Int) -> UInt16 { feed.periods[voice] }
    func volume(_ voice: Int) -> UInt16 { feed.volumes[voice] }
    var lightFilter: Bool { feed.lightFilter }
}
