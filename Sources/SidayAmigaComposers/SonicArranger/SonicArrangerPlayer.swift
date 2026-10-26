// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the 68000 code of Sonic Arranger's player, version 2.18 (by Carsten Schlote, Branko Mikić
// and Carsten Herbst, 1991 to 1995), in the two forms UADE runs it in: Wanted Team's EaglePlayer module
// of it ("Sonic Arranger 2.18 player module V1.0 (28 Feb 2009)", players/SonicArranger, whose source
// UADE carries as amigasrc/players/wanted_team/Sonic_Arranger/Sonic Arranger_v1.asm: the labels given
// are that source's, which are the addresses of the replayer it was made from), and the replayer a
// module carries in front of itself, which UADE's `SonicArranger-pc-all` runs as it is (where it does
// otherwise, its addresses are given too, of the build whose table of periods is at $1714).

import SidayChips
import SidayFoundation

/// Sonic Arranger's music (UnExoticA's, from Ambermoon, Lionheart, Dimo's Quest and Marvin's
/// Marvellous Adventure). A song is a list of positions, each giving each of the four voices where its
/// rows begin and how far its notes and instruments are transposed; a row is a note, an instrument and a
/// command. An instrument is a sample, or a synthesised wave of up to 128 bytes, which the player copies
/// into a buffer of the voice's own that Paula plays and then works on as it plays, tick by tick, with
/// one of seventeen effects (negating, adding, rotating, filtering, blending towards another wave...);
/// and either kind has tables for its volume (an envelope, with a sustain) and its pitch, three tables
/// of arpeggios, a vibrato and a slide.
///
/// This is the player's own code, as it tells Paula what to do, tick by tick, and as it writes its
/// voices' buffers: what it tells her is the same as UADE's running of that code for the files of
/// UnExoticA's collection. It owns the memory Paula plays from: the module, room after it, and the
/// voices of Wanted Team's player (each 206 bytes, of which the first 128 are the wave Paula plays),
/// which the player's own replayer keeps in the module, in front of the song, where it is.
///
/// The two players differ where Wanted Team mended the replayer: theirs starts the master volume at
/// 64, not 63, and lets a command set it to 64; it keeps an instrument's number to those there are;
/// it waits for Paula to stop a voice before starting a new sample on it, as the replayer does not (it
/// tells her a length of one word and a period of $72 instead); it clears its voices for each song;
/// and it sets Paula's location whole, where the replayer, ending a note, sets its upper word alone
/// to the lower word of where its silence is, and clears the upper word of where the voice's
/// instrument is, leaving the lower (no file of UnExoticA's does either: see `endNote`). Both run as
/// often as the song says, as the replayer sets its own timer to (see `timer(ticksASecond:)`); UADE
/// runs the replayer fifty times a second, whatever its song says, from a timer of its own, which the
/// replayer's does not set.
struct SonicArrangerPlayer: ~Copyable {
    /// The module and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    /// How many bytes of `memory` are the module's.
    let size: Int
    var silenceAt: Int { size }
    /// Room after the module, as for any player of `PaulaTickRenderer`'s, for no mixing.
    var mixingAt: Int { size + 0x20000 }
    static let mixingSpace = 2048
    /// Where Wanted Team's player keeps its four voices (and after them two bytes of silence,
    /// `lbL0003F4`), which it has Paula read from: after the room.
    var playerAt: Int { mixingAt + Self.mixingSpace }
    /// How many bytes Paula may read of `memory`.
    let memoryCapacity: Int

    /// Which player plays the file, and where its parts are.
    let replayer: SonicArrangerLayout.Replayer
    private let songsAt: Int
    private let positionsAt: Int
    private let rowsAt: Int
    private let instrumentsAt: Int
    private let instrumentCount: Int
    private let wavesAt: Int
    private let volumeTablesAt: Int
    private let pitchTablesAt: Int
    /// Where each of the 128 entries of the player's table of samples points: nought for none.
    private let samples: [Int]
    /// Where the player's voices are (`lbL0000BC`, 206 bytes each) and its two bytes of silence.
    let voicesAt: Int
    var emptyAt: Int { voicesAt + 4 * Self.voiceSize }
    static let voiceSize = 0xCE
    /// The module as the player has it before it plays: put back for each song.
    private let pristine: [UInt8]

    let songCount: Int
    private(set) var song = 0
    /// The filter the power light shows, as the E command last set it (`PaulaTickRenderer` plays it).
    private(set) var lightFilter = false

    /// The song's six words (`lbW000618` to `lbW000622`): the speed, the rows of a position, the first
    /// position, the last, the one gone back to after it and the ticks a second.
    private var speed: UInt16 = 0
    private var rowsPerPosition: UInt16 = 0
    private var firstPosition: UInt16 = 0
    private var lastPosition: UInt16 = 0
    private var restartPosition: UInt16 = 0
    private var ticksASecond: UInt16 = 0
    /// Whether the song moves on through its positions (`lbW000624`): -1 once it has begun.
    private var running: UInt16 = 0
    /// The master volume, 0 to 64 (`lbW000626`).
    private var master: UInt16 = 0
    /// The voices whose sample was started in the tick before and whose loop is to be set (`lbB000628`).
    private var loopDue = InlineArray<4, Bool>(repeating: false)
    /// The tick of the row, the row of the position and the position (`lbW00063C` to `lbW000640`).
    private var tick: UInt16 = 0
    private var row: UInt16 = 0
    private var position: UInt16 = 0
    /// Each voice's transposes, of its instrument (upper byte) and note (lower) (`lbW000642`), where its
    /// row is (`lbL00064A`) and what it holds (`lbL00065A`).
    private var transposes = InlineArray<4, UInt16>(repeating: 0)
    private var rowAt = InlineArray<4, Int>(repeating: 0)
    private var rowData = InlineArray<4, UInt32>(repeating: 0)
    /// The voices to be turned on as the tick ends (`lbW00066A`).
    private var turnOn: UInt16 = 0
    /// What was last written to Paula's registers.
    private var paulaPeriods = InlineArray<4, UInt16>(repeating: 0)
    private var paulaVolumes = InlineArray<4, UInt16>(repeating: 0)
    private var paulaLocations = InlineArray<4, Int>(repeating: 0)
    private var paulaLengths = InlineArray<4, UInt16>(repeating: 0)
    /// The CIA timer the player is run by, and Paula's clocks since the song began.
    private(set) var timer: UInt16 = 0x376B
    private var clock: UInt64 = 0

    private(set) var endings = 0
    /// True from a jump back in the song or its last position's end until its next position begins,
    /// where it has come round.
    private var comesRound = false
    /// The song's length, in ticks, as the player plays it through before it begins; nil for one that
    /// does not come back to its beginning in 59 minutes.
    private(set) var lengthTicks: Int?

    /// Where Paula is told to play from by the replayer's ending of a note (see `endNote`): nowhere
    /// in the Amiga's memory that is the music's, read here as noughts, and by Paula as silence.
    static let nowhere = -0x4000_0000

    /// True for a file the player that UADE would play it with takes for one of its own (see
    /// `SonicArrangerLayout`).
    static func isOne(_ data: [UInt8]) -> Bool { SonicArrangerLayout.isOne(data) }

    /// Reads the module as the player's setting up does, and starts song `song` (counting from nought).
    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        let layout = try SonicArrangerLayout.read(data)
        replayer = layout.replayer
        songsAt = layout.songsAt
        positionsAt = layout.positionsAt
        rowsAt = layout.rowsAt
        instrumentsAt = layout.instrumentsAt
        instrumentCount = layout.instrumentCount
        wavesAt = layout.wavesAt
        volumeTablesAt = layout.volumeTablesAt
        pitchTablesAt = layout.pitchTablesAt
        songCount = layout.songCount
        size = data.count
        var table = [Int](repeating: 0, count: SonicArrangerLayout.mostSamples)
        for (i, at) in layout.samples.enumerated() { table[i] = at }
        samples = table
        var module = data
        if let text = layout.text {
            // Wanted Team's player inverts the text after the song back, where it is ("Notuj").
            for i in text.start ..< text.end where i < module.count { module[i] = ~module[i] }
        }
        let playerAt = data.count + 0x20000 + Self.mixingSpace
        switch layout.replayer {
        case .wantedTeam:
            voicesAt = playerAt
        case .own:
            // The replayer's voices are in front of the song, in its own code (`lbL0000BC`), and so is its
            // table of samples ($418), which its setting up fills (and which a sample of a number past
            // those it has reads on from).
            voicesAt = 0xBC
            for (i, at) in table.enumerated() {
                let entry = 0x418 + 4 * i
                for k in 0 ..< 4 where entry + k < module.count {
                    module[entry + k] = UInt8(truncatingIfNeeded: UInt32(at) >> (24 - 8 * k))
                }
            }
        }
        pristine = module
        memoryCapacity = playerAt + 4 * Self.voiceSize + 2 + 64
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        begin(song)
    }

    deinit { memory.deallocate() }

    // MARK: Memory

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < memoryCapacity ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at + 1)) }
    @inline(__always) private func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }

    /// A byte written by the player: to the module, or Wanted Team's voices. (Anywhere else would be
    /// past either, in memory that is not the music's, and is not written here.)
    @inline(__always) private func setByte(_ at: Int, _ value: UInt8) {
        if (at >= 0 && at < size) || (at >= playerAt && at < memoryCapacity) { memory[at] = value }
    }

    @inline(__always) private func setWord(_ at: Int, _ value: UInt16) {
        setByte(at, UInt8(value >> 8))
        setByte(at + 1, UInt8(truncatingIfNeeded: value))
    }

    @inline(__always) private func setLong(_ at: Int, _ value: UInt32) {
        setWord(at, UInt16(value >> 16))
        setWord(at + 2, UInt16(truncatingIfNeeded: value))
    }

    /// Where voice `v`'s 206 bytes are.
    @inline(__always) private func voice(_ v: Int) -> Int { voicesAt + v * Self.voiceSize }

    // The fields of a voice, as offsets into its 206 bytes, of which the first 128 are its wave.
    private static let note = 0x80, lastNote = 0x82, periodOffset = 0x84, slide = 0x86
    private static let instrumentNumber = 0x88, instrument = 0x8A, volume = 0x8E, volumeSlide = 0x90
    private static let vibratoAt = 0x92, vibratoDelay = 0x94, vibratoSpeed = 0x96, vibratoLevel = 0x98
    private static let portamento = 0x9A, portamentoPeriod = 0x9C, volumeAt = 0x9E, sustainCount = 0xA0
    private static let volumeDelay = 0xA2, pitchAt = 0xA4, pitchDelay = 0xA6, effectAt = 0xA8
    private static let effectCount = 0xAA, effectDelay = 0xAC, arpeggioAt = 0xAE, arpeggioStep = 0xB0
    private static let level = 0xB2, flags = 0xB4, dmaBit = 0xB6, length = 0xB8, synthetic = 0xBA
    private static let wave = 0xBC, waveExtra = 0xC0

    @inline(__always) private func field(_ v: Int, _ at: Int) -> UInt16 { word(voice(v) + at) }
    @inline(__always) private func setField(_ v: Int, _ at: Int, _ value: UInt16) { setWord(voice(v) + at, value) }
    /// The low byte of the voice's flags ($B5): 1, its instrument has ended; 2, 4 and 8, its effects'
    /// own.
    @inline(__always) private func flag(_ v: Int, _ bit: UInt8) -> Bool { byte(voice(v) + 0xB5) & bit != 0 }
    @inline(__always) private func setFlag(_ v: Int, _ bit: UInt8) { setByte(voice(v) + 0xB5, byte(voice(v) + 0xB5) | bit) }
    @inline(__always) private func clearFlag(_ v: Int, _ bit: UInt8) { setByte(voice(v) + 0xB5, byte(voice(v) + 0xB5) & ~bit) }

    /// The voice's instrument (152 bytes), as the player keeps where it is, and a word of it.
    @inline(__always) private func instrument(_ v: Int) -> Int { SonicArrangerLayout.place(long(voice(v) + Self.instrument)) }
    @inline(__always) private func setting(_ instrument: Int, _ at: Int) -> UInt16 { word(instrument + at) }

    /// A word of the player's table of periods, `at` bytes on from its first (`lbW001716`), which a
    /// note past the table reads on from: in the module, for its own replayer; in Wanted Team's player,
    /// the table of the vibrato and then nought.
    private func tableWord(_ at: Int) -> UInt16 {
        switch replayer {
        case let .own(periodsAt): return word(periodsAt + at)
        case .wantedTeam: return UInt16(SonicArrangerTables.byte(at)) << 8 | UInt16(SonicArrangerTables.byte(at + 1))
        }
    }

    /// A byte of the vibrato's table (`lbL0017F2`), straight after the periods'.
    private func vibratoByte(_ n: Int) -> UInt8 {
        switch replayer {
        case let .own(periodsAt): return byte(periodsAt + 220 + n)
        case .wantedTeam: return SonicArrangerTables.byte(220 + n)
        }
    }

    /// The player's table of samples (`lbL000418`), read by a word's offset (four bytes each).
    private func sampleEntry(_ offset: Int16) -> Int {
        switch replayer {
        case .own: return SonicArrangerLayout.place(long(0x418 + Int(offset)))
        case .wantedTeam:
            let i = Int(offset) >> 2
            return offset >= 0 && i < samples.count ? samples[i] : 0
        }
    }

    // MARK: Songs

    /// Starts song `song` (one past the last is the first), as a player newly set up would; and finds
    /// how long it is, played through for up to 59 minutes.
    mutating func select(song: Int) throws(TuneError) { begin(song) }

    private mutating func begin(_ song: Int) {
        self.song = song >= 0 && song < songCount ? song : 0
        start()
        // Only the rows move the song on (nothing of a tick between them does, nor anything of a voice's
        // tick), so the song is played through a row at a time: each as many ticks after the one
        // before as its speed then is, or one for a speed of one or less.
        var none = TFMXSilentOutput()
        var ticks = 0
        lengthTicks = nil
        let longest = Int(UInt64(59 * 60) * 3_546_895 / UInt64(tickClocks))
        while ticks < longest {
            tick = 0
            nextRow(&none)
            if endings > 0 {
                lengthTicks = ticks
                break
            }
            ticks += max(1, Int(Int16(bitPattern: speed)))
        }
        start()
    }

    /// The song from its beginning: the module as it was set up, the voices as new, and the player's
    /// `InitSong` (`lbC00066C`) and its starting of the sound (`InitSound`, and the replayer's own at
    /// $822).
    private mutating func start() {
        lightFilter = false
        for i in 0 ..< size { memory[i] = pristine[i] }
        for i in playerAt ..< memoryCapacity { memory[i] = 0 }
        // `lbC000804`: each voice's instrument has ended (and Wanted Team's player clears them first,
        // as they are for the replayer before its first song).
        for v in 0 ..< 4 { setFlag(v, 1) }
        loopDue = InlineArray(repeating: false)
        let entry = songsAt + 12 * song
        speed = word(entry)
        rowsPerPosition = word(entry + 2)
        firstPosition = word(entry + 4)
        lastPosition = word(entry + 6)
        restartPosition = word(entry + 8)
        ticksASecond = word(entry + 10)
        position = firstPosition &- 1
        tick = speed
        row = rowsPerPosition
        master = replayer == .wantedTeam ? 64 : 0x3F
        running = 0xFFFF
        transposes = InlineArray(repeating: 0)
        rowAt = InlineArray(repeating: 0)
        rowData = InlineArray(repeating: 0)
        turnOn = 0
        paulaPeriods = InlineArray(repeating: 0)
        paulaVolumes = InlineArray(repeating: 0)
        paulaLocations = InlineArray(repeating: 0)
        paulaLengths = InlineArray(repeating: 0)
        timer = Self.timer(ticksASecond: ticksASecond)
        clock = 0
        endings = 0
        comesRound = false
    }

    /// The CIA timer the player is run by, as the replayer sets its own (`lbC0007D6`): $AD303, the CIA's
    /// count for a second on a PAL Amiga ("only PAL clock", Wanted Team's source of it says), over the
    /// song's ticks a second; none leaves it fifty a second, $376B, and a division too big for a word
    /// leaves its dividend, of which the lower word is taken. (Wanted Team's player sets UADE's timer to
    /// fifty times its own instead, 709,350 over them, a little faster; and UADE runs a module's own
    /// replayer fifty times a second whatever its song says.)
    static func timer(ticksASecond: UInt16) -> UInt16 {
        guard ticksASecond != 0 else { return 0x376B }
        let quotient = 0xAD303 / UInt32(ticksASecond)
        return UInt16(truncatingIfNeeded: quotient > 0xFFFF ? 0xAD303 : quotient)
    }

    /// How long a tick is, in Paula's clocks: the CIA's timer comes round every one more of its clocks
    /// than it is set to, each five of Paula's. (Measured in UADE's dumps of Paula's registers: 70,940
    /// between ticks at fifty a second.)
    var tickClocks: Int { (Int(timer) + 1) * 5 }

    // MARK: Ticks

    /// Runs the player for one tick (`Play`, `lbC000908`), telling `output` what Paula is to do. Returns
    /// the tick's length in Paula's clocks.
    @discardableResult
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        if loopDue[0] || loopDue[1] || loopDue[2] || loopDue[3] {
            for v in 0 ..< 4 where loopDue[v] { setLoop(v, &output) }
            loopDue = InlineArray(repeating: false)
        }
        tick &+= 1
        if Int16(bitPattern: tick) >= Int16(bitPattern: speed) {
            tick = 0
            if running != 0 { nextRow(&output) }
        }
        for v in 0 ..< 4 { playTick(v, &output) }
        if turnOn != 0 {
            for v in 0 ..< 4 where turnOn & 1 << v != 0 { output.on(v) }
            turnOn = 0
        }
        clock += UInt64(tickClocks)
        return tickClocks
    }

    /// The loop of a sample started in the tick before (`lbC000870`): what follows its first part, as
    /// long as its instrument says; a loop of one word, silence; one of nought, the whole sample again.
    private mutating func setLoop<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let instrument = instrument(v)
        let loop = setting(instrument, 6)
        if loop == 0 { return }
        let start = SonicArrangerLayout.place(long(voice(v) + Self.wave))
        if loop == 1 || start == 0 {
            tell(v, location: emptyAt, length: 1, &output)
            return
        }
        // (`movem.w` takes the first part's length as a signed word.)
        let first = Int(Int16(bitPattern: setting(instrument, 4))) * 2
        tell(v, location: start + first, length: loop, &output)
    }

    /// Paula told where to play from and for how many words, both at once.
    private mutating func tell<Output: TFMXOutput>(_ v: Int, location: Int, length: UInt16, _ output: inout Output) {
        paulaLocations[v] = location
        paulaLengths[v] = length
        output.takeNextBuffer(v, start: location, length: length)
    }

    /// The next row (`lbC000998`): of this position, or the first of the next, after the last the one
    /// gone back to, which is the song's end (and Wanted Team's player says so, `SongEnd`).
    private mutating func nextRow<Output: TFMXOutput>(_ output: inout Output) {
        row &+= 1
        if Int16(bitPattern: rowsPerPosition) > Int16(bitPattern: row) {
            for v in 0 ..< 4 {
                rowAt[v] += 4
                rowData[v] = long(rowAt[v])
            }
        } else {
            row = 0
            if Int16(bitPattern: running) <= 0 {
                position &+= 1
                if Int16(bitPattern: lastPosition) < Int16(bitPattern: position) {
                    position = restartPosition
                    comesRound = true
                }
            }
            if comesRound {
                endings += 1
                comesRound = false
            }
            let at = positionsAt + Int(position) * 16
            for v in 0 ..< 4 {
                rowAt[v] = rowsAt + Int(word(at + 4 * v)) * 4
                rowData[v] = long(rowAt[v])
                transposes[v] = word(at + 4 * v + 2)
            }
        }
        // `lbC000A4C`: each voice's row, and the voices started by them turned on at the tick's end.
        var started: UInt16 = 0
        for v in 0 ..< 4 { playRow(v, &started, &output) }
        turnOn = started | 0x8000
    }

    /// A voice's row (`lbC000C60`): its note (none, $80 for none and for holding the volume's sustain,
    /// $7F to end the note), transposed by its position unless the command's top bit says not; its
    /// instrument, transposed unless the bit below says not (for none, the one it has); and its command.
    private mutating func playRow<Output: TFMXOutput>(_ v: Int, _ started: inout UInt16, _ output: inout Output) {
        let data = rowData[v]
        var note = UInt16(data >> 24)
        var number = UInt16(data >> 16 & 0xFF)
        if note == 0 {
            if number != 0 { setInstrument(v, number) }
            command(v, data)
            return
        }
        if note == 0x80 {
            command(v, data)
            return
        }
        if note == 0x7F {
            endNote(v, &output)
            command(v, data)
            return
        }
        let marks = UInt16(truncatingIfNeeded: data) >> 12 & 12
        if marks & 4 == 0 { note &+= UInt16(bitPattern: Int16(Int8(bitPattern: UInt8(truncatingIfNeeded: transposes[v])))) }
        if number != 0, marks & 8 == 0 {
            number &+= UInt16(bitPattern: Int16(Int8(bitPattern: UInt8(transposes[v] >> 8))))
        }
        number &= 0xFF
        setField(v, Self.lastNote, field(v, Self.note))
        setField(v, Self.note, note)
        if field(v, Self.lastNote) == 0 { setField(v, Self.lastNote, note) }
        if field(v, Self.synthetic) == 0 {
            // A voice playing a sample is stopped first: Wanted Team's player sets its period to one, for
            // Paula to come to the end of the word she is playing at once, and waits for her to stop;
            // the replayer turns it off and tells her a length of a word and a period of $72 ($CDE).
            switch replayer {
            case .wantedTeam:
                paulaPeriods[v] = 1
                output.off(v)
            case .own:
                output.off(v)
                tell(v, location: paulaLocations[v], length: 1, &output)
                paulaPeriods[v] = 0x72
            }
        }
        let instrument: Int
        if number == 0 {
            instrument = self.instrument(v)
            if instrument == 0 {
                // (Branched to, not called: the row's command is not played.)
                endNote(v, &output)
                return
            }
            startInstrument(v, instrument)
        } else {
            instrument = setInstrument(v, number)
        }
        setField(v, Self.synthetic, setting(instrument, 0))
        if setting(instrument, 0) == 0 {
            startSample(v, instrument, &started, &output)
        } else {
            startWave(v, instrument, &started, &output)
        }
        command(v, data)
    }

    /// A sample started (`lbC000D1C`): the whole of its first part and its loop, the loop to be set
    /// next tick. One the table has not ends the voice.
    private mutating func startSample<Output: TFMXOutput>(_ v: Int, _ instrument: Int, _ started: inout UInt16, _ output: inout Output) {
        let at = sampleEntry(Int16(bitPattern: setting(instrument, 2) &* 4))
        if at == 0 {
            setFlag(v, 1)
            endNote(v, &output)
            loopDue[v] = false
            return
        }
        let loop = setting(instrument, 6)
        let length = setting(instrument, 4) &+ (loop == 1 ? 0 : loop)
        tell(v, location: at, length: length, &output)
        setLong(voice(v) + Self.wave, UInt32(truncatingIfNeeded: at))
        setField(v, Self.length, length)
        started |= 1 << UInt16(v)
        setField(v, Self.dmaBit, 1 << UInt16(v))
        loopDue[v] = true
    }

    /// A synthesised wave started (`lbC000D6C`): its waveform copied into the voice's buffer, sixteen
    /// bytes at a time for as many words as it is long, which Paula plays over and over.
    private mutating func startWave<Output: TFMXOutput>(_ v: Int, _ instrument: Int, _ started: inout UInt16, _ output: inout Output) {
        var from = wavesAt + Int(setting(instrument, 2)) << 7
        setLong(voice(v) + Self.wave, UInt32(truncatingIfNeeded: from))
        setLong(voice(v) + Self.waveExtra, 0)
        var to = voice(v)
        let length = setting(instrument, 4)
        tell(v, location: to, length: length, &output)
        setField(v, Self.length, length)
        // (`dbra` from the length less one over eight: for a length of nought, 65,536 times.)
        let blocks = Int(UInt16(bitPattern: Int16(bitPattern: length &- 1) >> 3)) + 1
        for _ in 0 ..< blocks {
            for _ in 0 ..< 16 {
                setByte(to, byte(from))
                to += 1
                from += 1
            }
        }
        started |= 1 << UInt16(v)
        setField(v, Self.dmaBit, 1 << UInt16(v))
        loopDue[v] = false
    }

    /// An instrument given (`lbC000DAE`): its number, which Wanted Team's player keeps to those there
    /// are, and its volume, slide, portamento and vibrato; then it starts (`startInstrument`). Returns
    /// where it is.
    @discardableResult
    private mutating func setInstrument(_ v: Int, _ given: UInt16) -> Int {
        var number = given & 0xFF
        setField(v, Self.instrumentNumber, number)
        if replayer == .wantedTeam, UInt16(truncatingIfNeeded: instrumentCount) < number {
            number = UInt16(truncatingIfNeeded: instrumentCount)
        }
        // (`subq.l` and `mulu.w`: the number less one, in a word, times 152.)
        let at = instrumentsAt + Int(number &- 1) * 152
        setLong(voice(v) + Self.instrument, UInt32(truncatingIfNeeded: at))
        setField(v, Self.volume, setting(at, 0x10))
        setField(v, Self.portamento, setting(at, 0x14))
        setField(v, Self.portamentoPeriod, 0)
        setField(v, Self.vibratoAt, 0)
        setField(v, Self.vibratoDelay, setting(at, 0x16))
        setField(v, Self.vibratoSpeed, setting(at, 0x18))
        setField(v, Self.vibratoLevel, setting(at, 0x1A))
        startInstrument(v, at)
        return at
    }

    /// An instrument started afresh (`lbC000DF0`): its tuning, its envelopes and effect from their
    /// beginnings, its arpeggio from its first step, and its flags cleared.
    private mutating func startInstrument(_ v: Int, _ at: Int) {
        setField(v, Self.periodOffset, UInt16(bitPattern: Int16(Int8(bitPattern: UInt8(truncatingIfNeeded: setting(at, 0x12))))))
        setField(v, Self.volumeDelay, setting(at, 0x26))
        setField(v, Self.volumeAt, 0)
        setField(v, Self.sustainCount, 0)
        setField(v, Self.pitchDelay, setting(at, 0x1E))
        setField(v, Self.pitchAt, 0)
        setField(v, Self.effectAt, setting(at, 0x44))
        setField(v, Self.effectCount, 0)
        setField(v, Self.effectDelay, setting(at, 0x48))
        setField(v, Self.arpeggioAt, 0)
        setField(v, Self.arpeggioStep, 0)
        setField(v, Self.level, UInt16(truncatingIfNeeded: (UInt32(field(v, Self.volume)) * UInt32(master)) >> 6) &<< 2)
        setField(v, Self.flags, 0)
    }

    /// The note ended (`lbC000E3C`): silence, and the voice's instrument let go. (The replayer, as
    /// Wanted Team found, sets only the upper word of Paula's location, to the lower word of where its
    /// silence is, which is nowhere that is anything, at a volume of nought; and clears only the upper
    /// word of where the instrument is, so that the voice goes on as if one were at its lower word, in
    /// memory that is not the music's. No file of UnExoticA's ends a note so: here such a voice is
    /// played from nowhere, which is silence, and its instrument read as noughts.)
    private mutating func endNote<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        paulaVolumes[v] = 0
        switch replayer {
        case .wantedTeam:
            tell(v, location: emptyAt, length: 1, &output)
            setLong(voice(v) + Self.instrument, 0)
        case .own:
            tell(v, location: Self.nowhere, length: 1, &output)
            setWord(voice(v) + Self.instrument, 0)
        }
        setField(v, Self.volume, 0)
        setField(v, Self.level, 0)
        setField(v, Self.instrumentNumber, 0)
        loopDue[v] = false
    }

    /// The row's command (`lbC000B60`), after its note. The slides of the period and the volume last
    /// for the row only.
    private mutating func command(_ v: Int, _ data: UInt32) {
        setField(v, Self.slide, 0)
        setField(v, Self.volumeSlide, 0)
        let parameter = UInt16(truncatingIfNeeded: data) & 0xFF
        let signed = UInt16(bitPattern: Int16(Int8(bitPattern: UInt8(parameter))))
        switch data >> 8 & 0xF {
        case 0x1: setField(v, Self.slide, signed)
        case 0x2: setField(v, Self.volumeAt, parameter)
        case 0x4:
            // The vibrato begins now (its speed and depth are set too, but the vibrato reads the
            // instrument's own).
            setField(v, Self.vibratoDelay, 0)
            setField(v, Self.vibratoSpeed, (parameter & 0xF0) >> 3)
            setField(v, Self.vibratoLevel, 0xA0 &- (parameter & 15) << 4)
        case 0x6:
            // The master volume: Wanted Team's player lets it be 64; the replayer keeps six bits.
            master = replayer == .wantedTeam && parameter == 64 ? 64 : parameter & 0x3F
        case 0x7: setField(v, Self.portamento, parameter)
        case 0x8: setField(v, Self.portamento, 0)
        case 0x9:
            if parameter > 0, parameter <= 0x40 { rowsPerPosition = parameter }
        case 0xA: setField(v, Self.volumeSlide, signed)
        case 0xB:
            // A jump to a position, made at the next row. One back to where the song has been is where
            // it comes round (which the player does not say).
            if Int16(bitPattern: parameter &- 1) < Int16(bitPattern: position) { comesRound = true }
            position = parameter &- 1
            row = rowsPerPosition
        case 0xC:
            let volume = min(parameter, 0x40)
            setField(v, Self.volume, volume)
            setField(v, Self.level, UInt16(truncatingIfNeeded: (UInt32(volume) * UInt32(master)) >> 6) &<< 2)
        case 0xD: row = rowsPerPosition
        case 0xF:
            if Int8(bitPattern: UInt8(parameter)) > 0, parameter <= 0x10 { speed = parameter }
        case 0xE:
            // The filter, through the power light: on for nought (`bclr #1,$bfe001`, $1102 of Wanted
            // Team's player, and the same in the replayer the songs with one carry), off otherwise.
            lightFilter = parameter == 0
        default:
            // 0 (its arpeggio is played on every tick), 3 and 5 (the replayer's "sync", for a game to
            // read).
            break
        }
    }

    /// A voice's tick (`lbC000EB0`): for one whose instrument has ended, or that has none, silence;
    /// otherwise its period, from its note, arpeggio, portamento, vibrato, pitch table, tuning and slide;
    /// its wave's effect; and its volume, from its envelope.
    private mutating func playTick<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let data = rowData[v]
        let instrument = instrument(v)
        if flag(v, 1) || instrument == 0 {
            paulaVolumes[v] = 0
            tell(v, location: emptyAt, length: 1, &output)
            if field(v, Self.level) != 0 { setField(v, Self.level, field(v, Self.level) &- 4) }
            return
        }
        var note = UInt32(field(v, Self.note))
        var last = UInt32(field(v, Self.lastNote))
        let table = Int(UInt16(truncatingIfNeeded: data) >> 12 & 3)
        if table != 0 {
            // One of the instrument's three arpeggios: a byte of steps, a byte of the steps it goes back
            // over, and fourteen steps, each added to the note's lower byte.
            let at = instrument + 0x4A + (table - 1) * 16
            let step = field(v, Self.arpeggioAt)
            let add = byte(at + 2 + Int(Int16(bitPattern: step)))
            note = note & ~0xFF | UInt32(UInt8(truncatingIfNeeded: note) &+ add)
            last = last & ~0xFF | UInt32(UInt8(truncatingIfNeeded: last) &+ add)
            setField(v, Self.arpeggioAt, step &+ 1)
            let end = UInt16(byte(at) &+ byte(at + 1))
            if Int16(bitPattern: end) <= Int16(bitPattern: field(v, Self.arpeggioAt)) {
                setField(v, Self.arpeggioAt, UInt16(byte(at)))
            }
        } else if UInt16(truncatingIfNeeded: data) & 0xF00 == 0, data & 0xFF != 0 {
            // Command 0: the note, then the upper nibble's semitones above it, then the lower's.
            var semitones = UInt16(data & 0xFF)
            let step = field(v, Self.arpeggioStep)
            if step == 0 {
                setField(v, Self.arpeggioStep, 1)
                semitones = 0
            } else if step == 1 {
                setField(v, Self.arpeggioStep, 2)
                semitones >>= 4
            } else {
                setField(v, Self.arpeggioStep, 0)
            }
            semitones &= 15
            note = note & ~0xFFFF | UInt32(UInt16(truncatingIfNeeded: note) &+ semitones)
            last = last & ~0xFFFF | UInt32(UInt16(truncatingIfNeeded: last) &+ semitones)
        }
        // The periods of the two notes, by their words' offsets into the table.
        note &+= note
        last &+= last
        note = note & ~0xFFFF | UInt32(tableWord(Int(Int16(truncatingIfNeeded: note))))
        last = last & ~0xFFFF | UInt32(tableWord(Int(Int16(truncatingIfNeeded: last))))
        var period = note
        // The portamento, from the last note's period to this one's.
        let glide = field(v, Self.portamento)
        if glide != 0 {
            if field(v, Self.portamentoPeriod) == 0 { setField(v, Self.portamentoPeriod, UInt16(truncatingIfNeeded: last)) }
            last = last & ~0xFFFF | UInt32(field(v, Self.portamentoPeriod))
            var apart = Int32(bitPattern: period &- last)
            if apart < 0 { apart = -apart }
            if Int16(truncatingIfNeeded: apart) &- Int16(bitPattern: glide) < 0 {
                setField(v, Self.portamento, 0)
            } else {
                let now = Int32(bitPattern: last) >= Int32(bitPattern: period)
                    ? UInt16(truncatingIfNeeded: last) &- glide : UInt16(truncatingIfNeeded: last) &+ glide
                setField(v, Self.portamentoPeriod, now)
                period = period & ~0xFFFF | UInt32(now)
            }
        }
        // The vibrato, after its delay (which, with a lower byte of $FF, is for ever), by the instrument's
        // own speed and depth.
        if byte(voice(v) + Self.vibratoDelay + 1) != 0xFF {
            if field(v, Self.vibratoDelay) != 0 {
                setField(v, Self.vibratoDelay, field(v, Self.vibratoDelay) &- 1)
            } else {
                let at = field(v, Self.vibratoAt)
                let swing = Int32(Int8(bitPattern: vibratoByte(Int(Int16(bitPattern: at)))))
                let depth = Int16(bitPattern: setting(instrument, 0x1A))
                if depth != 0 {
                    period = period & ~0xFFFF | UInt32(UInt16(truncatingIfNeeded: period) &+ UInt16(truncatingIfNeeded: swing * 4 / Int32(depth)))
                }
                setField(v, Self.vibratoAt, (at &+ setting(instrument, 0x18)) & 0xFF)
            }
        }
        // The pitch table: a signed byte taken from the period, a step on after so many ticks, and at its
        // end its repeat (or, for none, its last step for ever).
        let pitchSteps = setting(instrument, 0x20) &+ setting(instrument, 0x22)
        if pitchSteps != 0 {
            let at = pitchTablesAt + Int(setting(instrument, 0x1C)) << 7
            let step = field(v, Self.pitchAt)
            let bend = UInt16(bitPattern: Int16(Int8(bitPattern: byte(at + Int(Int16(bitPattern: step))))))
            period = period & ~0xFFFF | UInt32(UInt16(truncatingIfNeeded: period) &- bend)
            setField(v, Self.pitchDelay, field(v, Self.pitchDelay) &- 1)
            if field(v, Self.pitchDelay) == 0 {
                setField(v, Self.pitchDelay, setting(instrument, 0x1E))
                setField(v, Self.pitchAt, step &+ 1)
                if Int16(bitPattern: pitchSteps) <= Int16(bitPattern: step &+ 1) {
                    var back = setting(instrument, 0x20)
                    if setting(instrument, 0x22) == 0 { back &-= 1 }
                    setField(v, Self.pitchAt, back)
                }
            }
        }
        var paulaPeriod = UInt16(truncatingIfNeeded: period) &- field(v, Self.periodOffset)
        if Int16(bitPattern: paulaPeriod) < 0x71 { paulaPeriod = 0x71 }
        if tick != 0 { setField(v, Self.periodOffset, field(v, Self.periodOffset) &+ field(v, Self.slide)) }
        paulaPeriods[v] = paulaPeriod
        if setting(instrument, 0) != 0 { waveEffect(v, instrument) }
        playVolume(v, instrument, data)
    }

    /// The voice's volume for the tick (from `lbC00106C`): the instrument's, times the master's, and
    /// times its envelope's, if it has one, which moves on a step after so many ticks, waits at its
    /// sustain while the row holds the note ($80), and at its end repeats, or, for none, holds its last
    /// step, and if that is nought ends the instrument. Then the row's slide of it.
    private mutating func playVolume(_ v: Int, _ instrument: Int, _ data: UInt32) {
        let steps = setting(instrument, 0x28) &+ setting(instrument, 0x2A)
        if steps == 0 {
            setVolume(v, (UInt32(field(v, Self.volume)) * UInt32(master)) >> 6)
            if field(v, Self.level) != 0 { setField(v, Self.level, field(v, Self.level) &- 4) }
        } else {
            let at = volumeTablesAt + Int(Int16(bitPattern: setting(instrument, 0x24) &<< 7))
            let envelope = UInt32(byte(at + Int(Int16(bitPattern: field(v, Self.volumeAt)))))
            let scaled = (envelope * UInt32(master)) >> 6
            let volume = setVolume(v, (UInt32(field(v, Self.volume)) * (scaled & 0xFFFF)) >> 6)
            setField(v, Self.level, UInt16(truncatingIfNeeded: volume) &<< 2)
            var moves = true
            if data >> 24 == 0x80, Int16(bitPattern: field(v, Self.volumeAt)) >= Int16(bitPattern: setting(instrument, 0x2C)) {
                if setting(instrument, 0x2E) == 0 {
                    moves = false
                } else if field(v, Self.sustainCount) != 0 {
                    setField(v, Self.sustainCount, field(v, Self.sustainCount) &- 1)
                    moves = false
                } else {
                    setField(v, Self.sustainCount, setting(instrument, 0x2E))
                }
            }
            if moves {
                setField(v, Self.volumeDelay, field(v, Self.volumeDelay) &- 1)
                if field(v, Self.volumeDelay) == 0 {
                    setField(v, Self.volumeDelay, setting(instrument, 0x26))
                    setField(v, Self.volumeAt, field(v, Self.volumeAt) &+ 1)
                    if Int16(bitPattern: steps) <= Int16(bitPattern: field(v, Self.volumeAt)) {
                        var back = setting(instrument, 0x28)
                        if setting(instrument, 0x2A) == 0 { back &-= 1 }
                        setField(v, Self.volumeAt, back)
                        if setting(instrument, 0x2A) == 0, UInt8(truncatingIfNeeded: scaled) == 0 { setFlag(v, 1) }
                    }
                }
            }
        }
        let slid = Int16(bitPattern: field(v, Self.volume) &+ field(v, Self.volumeSlide))
        setField(v, Self.volume, slid < 0 ? 0 : UInt16(bitPattern: slid) > 0x40 ? 0x40 : UInt16(bitPattern: slid))
    }

    /// Paula's volume written: by the replayer as it is; by Wanted Team's player, of its lower seven
    /// bits (`ChangeVolume`, at the full volume and balance UADE gives it). Returns what was written.
    @discardableResult
    private mutating func setVolume(_ v: Int, _ volume: UInt32) -> UInt16 {
        var written = UInt16(truncatingIfNeeded: volume)
        if replayer == .wantedTeam { written &= 0x7F }
        paulaVolumes[v] = written
        return written
    }

    // MARK: Waves

    /// Where the beam is across the screen, which two of the effects read as a random number ($DFF007):
    /// here, as near as can be told without the 68000's own timing, where the tick is on its line of 227
    /// of Paula's clocks and as many more as it takes the player to come to the effect, and to its byte.
    private func beam(_ later: Int) -> UInt8 { UInt8((Int(clock % 227) + 1400 + later * 25) % 227) }

    /// The wave's effect (`lbC00117A`), every so many ticks: one of seventeen, on the bytes of the
    /// voice's buffer from the instrument's second argument to its third, or the one its place has come
    /// to; most then move the place on, round from the third to the second.
    private mutating func waveEffect(_ v: Int, _ instrument: Int) {
        setField(v, Self.effectDelay, field(v, Self.effectDelay) &- 1)
        guard field(v, Self.effectDelay) == 0 else { return }
        setField(v, Self.effectDelay, setting(instrument, 0x48))
        let effect = Int16(bitPattern: setting(instrument, 0x42))
        guard effect > 0, effect <= 0x11 else { return }
        let buffer = voice(v)
        let argument = setting(instrument, 0x40)
        let from = setting(instrument, 0x44), to = setting(instrument, 0x46)
        let place = field(v, Self.effectAt)
        /// A waveform of the module's, by a number in a word, as the player finds it by a shift of the
        /// word (`asl.w #7`) and an offset of it signed.
        func waveAt(_ n: UInt16) -> Int { wavesAt + Int(Int16(bitPattern: n &<< 7)) }
        switch effect {
        case 1:
            // Negates the byte at its place (`lbC0011AC`).
            negate(buffer + Int(Int16(bitPattern: place)))
        case 2:
            freeNegator(v, instrument)
            return
        case 3:
            // Adds the argument to each byte (`lbC001280`).
            for at in span(buffer, from, to) { setByte(at, byte(at) &+ UInt8(truncatingIfNeeded: argument)) }
        case 4:
            // Rotates the bytes one to the left, the first going to the one after the last
            // (`lbC0012CE`).
            let start = buffer + Int(Int16(bitPattern: from))
            let first = byte(start)
            var at = start
            var count = Int16(bitPattern: to &- from)
            repeat {
                setByte(at, byte(at + 1))
                at += 1
                count &-= 1
            } while count >= 0
            setByte(at, first)
        case 5:
            // Adds the argument's waveform into the buffer, byte for byte (`lbC0012F0`), and does not move
            // on.
            let other = waveAt(argument) - buffer
            for at in span(buffer, from, to) { setByte(at, byte(at) &+ byte(at + other)) }
            return
        case 6:
            // Puts back the instrument's own byte at its place, and negates the one after it
            // (`lbC00135A`).
            let own = waveAt(setting(instrument, 2))
            let at = Int(Int16(bitPattern: place))
            setByte(buffer + at, byte(own + at))
            var next = place
            if Int16(bitPattern: place) >= Int16(bitPattern: to) { next = from &- 1 }
            negate(buffer + Int(Int16(bitPattern: next)) + 1)
        case 7:
            addFromWave(instrument, buffer: buffer, place: place)
        case 8:
            // As 7, and negates a byte that moves on through the span on its own (`lbC0013F6`).
            addFromWave(instrument, buffer: buffer, place: place)
            let count = field(v, Self.effectCount)
            negate(buffer + Int(Int16(bitPattern: from)) + Int(Int16(bitPattern: count)))
            setField(v, Self.effectCount, count &+ 1)
            if Int16(bitPattern: to &- from) &- Int16(bitPattern: count &+ 1) < 0 { setField(v, Self.effectCount, 0) }
        case 9, 15:
            blend(v, instrument)
            return
        case 10:
            // Slides the period by the second argument's lower byte, each time, the third's times
            // (`lbC001552`).
            if to > field(v, Self.effectCount) {
                let by = UInt16(bitPattern: Int16(Int8(bitPattern: UInt8(truncatingIfNeeded: from))))
                setField(v, Self.periodOffset, field(v, Self.periodOffset) &+ by)
                setField(v, Self.effectCount, field(v, Self.effectCount) &+ 1)
            }
        case 11:
            smooth(buffer, argument: argument, from: from, to: to)
        case 12:
            // Turns over the bits of the byte at its place by where the beam is (`lbC00160C`).
            let at = buffer + Int(Int16(bitPattern: place))
            setByte(at, byte(at) ^ beam(0))
        case 13:
            follow(buffer, from: from, to: to, limit: argument, limits: nil)
        case 14:
            // As 13, by the bytes of the argument's waveform from the third argument on, of seven bits
            // (`lbC00169E`).
            let limits = wavesAt + Int(argument) << 7 + Int(Int16(bitPattern: to))
            follow(buffer, from: from, to: to, limit: 0, limits: limits)
        case 16:
            // Stirs each byte, from the last back: turned over by five, its bits rotated two to the
            // left, and the beam added (`lbC001620`), and does not move on.
            let start = buffer + Int(Int16(bitPattern: from))
            var count = Int16(bitPattern: to &- from)
            var k = 0
            repeat {
                let at = start + Int(count)
                let turned = byte(at) ^ 5
                setByte(at, (turned << 2 | turned >> 6) &+ beam(k))
                k += 1
                count &-= 1
            } while count >= 0
            return
        case 17:
            // Takes the first argument times the second from the period's offset, each time; after the
            // third's, starts again from the instrument's tuning, of the whole word (`lbC001524`).
            if to <= field(v, Self.effectCount) {
                setField(v, Self.periodOffset, setting(instrument, 0x12))
                setField(v, Self.effectCount, 0)
            }
            setField(v, Self.periodOffset, field(v, Self.periodOffset) &- (argument &* from))
            setField(v, Self.effectCount, field(v, Self.effectCount) &+ 1)
        default:
            return
        }
        // `lbC001700`: the place moves on, past the third argument back to the second.
        setField(v, Self.effectAt, field(v, Self.effectAt) &+ 1)
        if field(v, Self.effectAt) > to { setField(v, Self.effectAt, from) }
    }

    private func negate(_ at: Int) { setByte(at, 0 &- byte(at)) }

    /// The bytes of the buffer from the second argument to the third, as the effects go through them:
    /// one at a time and then four, or as one goes past the other, none, or as the third is before the
    /// second (its count, in a word, below nought), the first.
    private func span(_ buffer: Int, _ from: UInt16, _ to: UInt16) -> [Int] {
        let start = buffer + Int(Int16(bitPattern: from))
        var count = Int16(bitPattern: to &- from)
        var at = start
        var out: [Int] = []
        if from & 1 != 0 {
            out.append(at)
            at += 1
            count &-= 1
            if count < 0 { return out }
        }
        while count >= 3 {
            out.append(contentsOf: [at, at + 1, at + 2, at + 3])
            at += 4
            count &-= 4
        }
        while count >= 0 {
            out.append(at)
            at += 1
            count &-= 1
        }
        return out
    }

    /// Effect 7 (`lbC001394`): adds to each byte of the span the byte of the argument's waveform at the
    /// effect's place, counted from the second argument.
    private mutating func addFromWave(_ instrument: Int, buffer: Int, place: UInt16) {
        let other = wavesAt + Int(Int16(bitPattern: setting(instrument, 0x40) &<< 7)) + Int(Int16(bitPattern: setting(instrument, 0x44)))
        let add = byte(other + Int(Int16(bitPattern: place)))
        for at in span(buffer, setting(instrument, 0x44), setting(instrument, 0x46)) { setByte(at, byte(at) &+ add) }
    }

    /// Effect 2, "free negator" (`lbC0011BC`): the instrument's own waveform copied in again, all but its
    /// first bytes, as many as the argument's waveform says at the effect's count (of seven bits),
    /// negated; the count moving on to the third argument past the second and round, or, for none,
    /// stopping where the argument's waveform says nought.
    private mutating func freeNegator(_ v: Int, _ instrument: Int) {
        if flag(v, 4) { return }
        let buffer = voice(v)
        let count = field(v, Self.effectCount)
        let argumentWave = wavesAt + Int(UInt32(setting(instrument, 0x40) &<< 7))
        var d0 = Int16(byte(argumentWave + Int(Int16(bitPattern: count))) & 0x7F)
        let negated = UInt8(d0)
        let own = wavesAt + Int(Int16(bitPattern: setting(instrument, 2) &<< 7))
        var d1 = Int16(bitPattern: setting(instrument, 4) &* 2)
        var a0 = buffer + Int(d1)
        var a1 = own + Int(d1)
        // From the end back, four bytes at a time, as they are, while what is left is no less than the
        // count; then back to the count, and the rest from there back, negated.
        while d1 > 0 {
            if d0 > d1 { break }
            a1 -= 4
            a0 -= 4
            for k in 0 ..< 4 { setByte(a0 + k, byte(a1 + k)) }
            d1 &-= 4
        }
        d0 = d0 &- d1
        d1 = d1 &+ d0
        a1 += Int(d0)
        a0 += Int(d0)
        if d1 > 0 {
            if d0 & 1 != 0 {
                a1 -= 1
                a0 -= 1
                setByte(a0, 0 &- byte(a1))
                d1 &-= 1
            }
            while d1 > 0 {
                a1 -= 4
                for k in (0 ..< 4).reversed() {
                    a0 -= 1
                    setByte(a0, 0 &- byte(a1 + k))
                }
                d1 &-= 4
            }
        }
        let next = count &+ 1
        setField(v, Self.effectCount, next)
        if next > setting(instrument, 0x44) &+ setting(instrument, 0x46) {
            setField(v, Self.effectCount, setting(instrument, 0x44))
            if setting(instrument, 0x46) == 0, negated == 0 { setFlag(v, 4) }
        }
    }

    /// Effects 9, "fade to wave" (`lbC001452`), and 15, "fade back and forth" (`lbC001422`): each byte
    /// of the span a step nearer the argument's waveform's, until none is left to move (and 15 then
    /// turns to the instrument's own waveform, and back).
    private mutating func blend(_ v: Int, _ instrument: Int) {
        var target = wavesAt + Int(Int16(bitPattern: setting(instrument, 0x40) &<< 7))
        if setting(instrument, 0x42) == 15 {
            if flag(v, 2) {
                setByte(voice(v) + 0xB5, byte(voice(v) + 0xB5) ^ 8)
                clearFlag(v, 2)
            }
            if flag(v, 8) { target = wavesAt + Int(Int16(bitPattern: setting(instrument, 2) &<< 7)) }
        } else if flag(v, 2) {
            return
        }
        let buffer = voice(v)
        let from = setting(instrument, 0x44)
        var moved = false
        let offset = target - buffer
        for at in span(buffer, from, setting(instrument, 0x46)) {
            let now = Int8(bitPattern: byte(at)), goal = Int8(bitPattern: byte(at + offset))
            guard now != goal else { continue }
            moved = true
            setByte(at, UInt8(bitPattern: now < goal ? now &+ 1 : now &- 1))
        }
        if !moved { setFlag(v, 2) }
    }

    /// Effect 11, "smooth" (`lbC00156E`): each byte of the span moved by the argument towards the byte
    /// after it. Four at a time, the 68000 adds and takes the argument as a word, which carries into or
    /// borrows from the byte it holds above (the one three on, or after the first, the one before).
    private mutating func smooth(_ buffer: Int, argument: UInt16, from: UInt16, to: UInt16) {
        var a0 = buffer + Int(Int16(bitPattern: from))
        var d1 = Int16(bitPattern: to &- from)
        func single() {
            let now = byte(a0)
            let moved = Int8(bitPattern: now) > Int8(bitPattern: byte(a0 + 1))
                ? now &- UInt8(truncatingIfNeeded: argument) : now &+ UInt8(truncatingIfNeeded: argument)
            setByte(a0, moved)
            a0 += 1
        }
        if from & 1 != 0 {
            single()
            d1 &-= 1
            if d1 < 0 { return }
        }
        while d1 >= 3 {
            var d0 = long(a0)
            var d4 = (d0 << 8 | d0 >> 24) & ~0xFF | UInt32(byte(a0 + 4))
            for _ in 0 ..< 4 {
                d0 = d0 << 8 | d0 >> 24
                d4 = d4 << 8 | d4 >> 24
                let low = UInt16(truncatingIfNeeded: d0)
                let moved = Int8(bitPattern: UInt8(truncatingIfNeeded: d0)) > Int8(bitPattern: UInt8(truncatingIfNeeded: d4))
                    ? low &- argument : low &+ argument
                d0 = d0 & 0xFFFF_0000 | UInt32(moved)
            }
            setLong(a0, d0)
            a0 += 4
            d1 &-= 4
        }
        while d1 >= 0 {
            single()
            d1 &-= 1
        }
    }

    /// Effects 13, "follow" (`lbC00164C`), and 14 (`lbC00169E`): each byte of the span, from the second
    /// argument to the third and the third's next being the second's, moved two towards the next where
    /// they are further apart than `limit`, or for 14 than the bytes from `limits` on, of seven bits.
    private mutating func follow(_ buffer: Int, from: UInt16, to: UInt16, limit: UInt16, limits: Int?) {
        let last = buffer + Int(Int16(bitPattern: to))
        let first = buffer + Int(Int16(bitPattern: from))
        // (The difference is compared as a word, its upper byte the second argument's.)
        let upper = Int16(bitPattern: from & 0xFF00)
        var at = first
        var i = 0
        while at <= last {
            let now = byte(at)
            let next = at == last ? byte(first) : byte(at + 1)
            let rising = Int8(bitPattern: now) <= Int8(bitPattern: next)
            var apart = now &- next
            if Int8(bitPattern: apart) < 0 { apart = 0 &- apart }
            let most = limits.map { Int16(byte($0 + i) & 0x7F) } ?? Int16(bitPattern: limit)
            if upper | Int16(apart) > most { setByte(at, rising ? byte(at) &+ 2 : byte(at) &- 2) }
            at += 1
            i += 1
        }
    }

    /// A song never stops: it goes round.
    var stops: Int { 0 }
    /// Paula's period and volume for the voice, as the player last set them.
    func period(_ voice: Int) -> UInt16 { paulaPeriods[voice] }
    func volume(_ voice: Int) -> UInt16 { paulaVolumes[voice] }
}

/// Sonic Arranger's modules, played on Paula by `PaulaTickRenderer`.
extension SonicArrangerPlayer: PaulaTickPlayer {
    var lengthClocks: UInt64? { lengthTicks.map { UInt64($0) * UInt64(tickClocks) } }
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "SA")
        info.detail = "Sonic Arranger"
        return info
    }

    /// Sonic Arranger's music is louder on the Amiga's chip than ProTracker's is, by 5.1 dB in the
    /// middle of UnExoticA's 116 files, and is turned down by that (2026-10-18).
    var gain: Float { 0.26 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { tickClocks }
}
