// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Paul Hunter's music player, in the two versions Paul Shields' games carry (Airball, Jug, Goldrunner
// II and Amiga Soccer the first; Amnios the second), as Wanted Team adapted them for EaglePlayer ("Paul Shields
// player module V1.2 (4 Feb 2002)"), carried by UADE as players/PaulShields, whose source UADE also carries as
// amigasrc/players/wanted_team/PaulShields/src/Paul Shields_v3.asm. The labels given are that source's.

/// Paul Shields' music, played by Paul Hunter's player (UnExoticA's 14 files, named .ps; Wanted Team's prefix is
/// "PS."): a file of the song and then its 16 samples, one after the other. It comes in three layouts, which the
/// player's check (`Check2`) tells apart:
///
/// - the first (Airball, Jug, Goldrunner II): 16 instruments of 32 bytes, each a name of 22 bytes and the words
///   of its sample's length (in words), its volume, its loop's place in it (in bytes) and length (in words), and
///   its note's offset (in eighths of a semitone); then, from byte 512, the places of the tables of pitch and
///   volume envelopes, and each voice's volume and the place of its list of patterns;
/// - the second (Amiga Soccer): the same, but 16 instruments of 10 bytes (a word not used, its length, its loop's
///   place and length and its offset, and no volume) and the header from byte 160;
/// - Amnios's: instruments as the first's, and from byte 512 the place of a table of instruments (each three
///   words: which sample, in sixteenths, and the places of its volume and pitch envelopes), and each voice's
///   volume and list of patterns.
///
/// A voice reads its list of patterns as words: the place of a pattern (its top bit set for a count of times to
/// play it, in the word after), or $FFE8 and up, the list's commands (a slide of the voice's volume, of all
/// four's, an offset to the period, a transposition, the list begun again, the voice stopped). A pattern is bytes:
/// a note and its length (in ticks; nought and two bytes for a longer one), a rest that lets the note fade, a
/// slide from one note to another over the length, an instrument, a volume, an envelope of volume or of pitch, and
/// the pattern's end. An envelope is a count of ticks and then steps, signed bytes, one every so many ticks, $81
/// to go round and $80 to hold; the pitch's in the first version may also be in periods rather than notes. The
/// first version also has seven waves of its own (squares, triangles and the like, and 400 bytes of its own code
/// played as noise), Amnios' version two commands that turn the Amiga's filter on and off.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that player
/// tells her, tick by tick. It sets no timer of its own (it has only `DTP_Interrupt`), and so is run by
/// EaglePlayer's, which UADE runs from a CIA's timer of $376B: 70,940 of Paula's clocks, fifty times a second and
/// a little less. On every tick the voices whose notes were begun in the tick before are turned on, and each voice
/// (the fourth first) slides its volume, reads its pattern if its note's length is up (a note begun turns its
/// voice off and tells Paula its sample), and runs its envelopes; and once `DMAWait` has waited for the beam to
/// begin nine lines (of 227 of Paula's clocks), the loops of the samples of the voices turned on are told. (The
/// game's own player told them in the interrupt of the voice's sample having begun; Wanted Team's waits instead.)
/// Each of its writes is told Paula at its moment in the tick (`TFMXOutput.timed(at:)`), near where it falls in
/// UADE's dumps.
///
/// A song comes to its end when its second voice's list (Amnios', its first's) goes back to its beginning, and is
/// said to have done so then; one whose voices all stop, stops. Where the player would read past the file it
/// reads nought; where it would jump to a command that is none, or run on through commands for ever, the voice
/// stops; a slide over no ticks (where the 68000 would trap on its division) does not move; and an instrument or
/// note past the player's tables is silence.
struct PaulShieldsPlayer: ~Copyable {
    /// The three layouts (`Format`: $FF, 1 and nought).
    enum Layout {
        case first
        case second
        case amnios

        var name: String {
            switch self {
            case .first: "the first version"
            case .second: "the first version, Amiga Soccer's layout"
            case .amnios: "the second version (Amnios)"
            }
        }
    }

    /// The file, the player's waves and silences after it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: the player's noughts (`lbL001F10` and `lbL0009DC`), just
    /// after its waves, and noughts after them.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { trashAt + 0x200 + 0x20000 }
    static let mixingSpace = 2048
    /// Where the player's waves are (`lbL000B56` on), and the 400 bytes of its code it plays as noise
    /// (`lbC000394`).
    let wavesAt: Int
    let trashAt: Int
    /// The byte a voice reads first (`lbB0009DA`, the command for its list's next pattern), and the one after it
    /// (`lbB0009DB`, $80), where the envelopes are pointed before any is set.
    private let startAt: Int

    private let fileSize: Int
    let layout: Layout
    /// Where the samples begin (as `InitPlayer` finds them), and how many instruments have one.
    let samplesAt: Int
    let sampleCount: Int

    /// An instrument as the player keeps it (`lbL000746`, `lbL001B7A`: 16 bytes each): its sample and its length,
    /// its loop and the loop's length, its note's offset and its volume.
    private struct Instrument {
        var start = 0
        var length: UInt16 = 1
        var loopStart = 0
        var loopLength: UInt16 = 1
        var offset: UInt16 = 0
        var volume: UInt16 = 0
    }

    private var instruments: [Instrument] = []

    /// What the player keeps for each voice (`lbL000846` and the three after it, 96 bytes each; `lbL001C7A` on,
    /// 140): byte 0, whether it is playing (bit 0), letting its note fade (bit 1) and taking its pitch as a period
    /// (bit 3); an offset to its period (2), its transposition (4) and its instrument's (6); its sample and loop
    /// (8 to 19); where its list of patterns begins and is (20, 24), where its pattern begins and is (28, 32); the
    /// slide of its volume, every so many ticks, its count and goal (36 to 41); its volume (42); the volume set,
    /// the envelope's, the instrument's (44 to 49); its pitch, with 16 bits more (52), and the step a slide takes
    /// (56); its note's count of ticks (60), its pattern's count of times (62); and its pitch and volume envelopes,
    /// where each begins and is, and its every so many ticks and count (64 to 87).
    private struct Voice {
        var flags: UInt8 = 0
        var periodOffset: UInt16 = 0
        var transpose: UInt16 = 0
        var offset: UInt16 = 0
        var sampleStart = 0
        var sampleLength: UInt16 = 0
        var loopStart = 0
        var loopLength: UInt16 = 0
        var listStart = 0
        var list = 0
        var patternStart = 0
        var pattern = 0
        var slideEvery: UInt16 = 0
        var slideCount: UInt16 = 0
        var slideGoal: UInt16 = 0
        var volume: UInt16 = 0
        var volumeSet: UInt16 = 0
        var envelopeVolume: UInt16 = 0
        var instrumentVolume: UInt16 = 0
        var pitch: UInt32 = 0
        var step: UInt32 = 0
        var count: UInt16 = 0
        var repeats: UInt16 = 0
        var pitchStart = 0
        var pitchAt = 0
        var pitchEvery: UInt8 = 0
        var pitchCount: UInt8 = 0
        var volumeStart = 0
        var volumeAt = 0
        var volumeEvery: UInt8 = 0
        var volumeCount: UInt8 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The player's variables (`lbL0009C6`, `lbL001EAA`): the tables of pitch and volume envelopes (Amnios', of
    /// instruments), the voices to be turned on and those whose loops are to be told, and what is taken off every
    /// volume (64).
    private var pitchTable = 0
    private var volumeTable = 0
    private var instrumentTable = 0
    private var turnOn: UInt16 = 0
    private static let volumeLess: UInt16 = 0x40
    private(set) var lightFilter = false

    /// Paula's location and length registers, as last written; and what each of her period and volume registers
    /// was last given, and what they held as the tick just run began (what `PaulaTickRenderer` sets Paula to
    /// then, before the tick's writes are told at their moments).
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)
    /// Paula's clocks since the song began, at the tick's start: where the beam is, for the wait.
    private var clock = 0

    let songCount = 1
    let song = 0
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    /// How many times a voice has stopped where the player would go astray (a command that is none, or
    /// commands without end), since the song began: nought for a file as the player has it.
    private(set) var astray = 0

    /// How long each tick is (see the type's comment).
    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60
    /// How many commands a voice may read in a tick before it is taken to be going round for ever.
    private static let mostCommands = 4096

    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (near the medians of its dumps): the
    /// voices turned on, as the interrupt begins (a guess: only the distances between them are heard), and the
    /// fourth voice's first write; for a voice, from its sample to its first write after it, and from that to the
    /// second, and from that to the next voice; and each loop.
    static let onClocks = 200
    static let firstWrite = 300
    static let sampleClocks = 240
    static let betweenClocks = 230
    static let nextClocks = 210
    static let idleClocks = 40
    static let loopClocks = 30

    /// When `DMAWait` begun `at` clocks into the tick returns: once the beam's line (227 of Paula's clocks) has
    /// changed nine times, the first at the next line's start; and some 80 clocks for the code around it.
    private func afterWait(_ at: Int) -> Int {
        let now = clock + at
        return (now / 227 + 9) * 227 + 80 - clock
    }

    /// The player's table of periods (before `lbC0006F2` and `lbC001AEA`): an octave in eighths of a semitone,
    /// at four times the lowest octave's periods.
    static let periodTable: [UInt16] = [
        0x6AE4, 0x6A1F, 0x695C, 0x689A, 0x67D9, 0x671A, 0x665C, 0x659F, 0x64E4, 0x642A, 0x6372, 0x62BB,
        0x6205, 0x6150, 0x609D, 0x5FEB, 0x5F3A, 0x5E8B, 0x5DDD, 0x5D30, 0x5C84, 0x5BDA, 0x5B31, 0x5A89,
        0x59E2, 0x593D, 0x5898, 0x57F5, 0x5753, 0x56B2, 0x5613, 0x5574, 0x54D7, 0x543A, 0x539F, 0x5305,
        0x526C, 0x51D5, 0x513E, 0x50A8, 0x5014, 0x4F80, 0x4EEE, 0x4E5C, 0x4DCC, 0x4D3D, 0x4CAF, 0x4C21,
        0x4B95, 0x4B0A, 0x4A80, 0x49F7, 0x496E, 0x48E7, 0x4861, 0x47DC, 0x4757, 0x46D4, 0x4651, 0x45D0,
        0x454F, 0x44D0, 0x4451, 0x43D3, 0x4356, 0x42DA, 0x425F, 0x41E5, 0x416B, 0x40F3, 0x407B, 0x4005,
        0x3F8F, 0x3F1A, 0x3EA5, 0x3E32, 0x3DBF, 0x3D4E, 0x3CDD, 0x3C6D, 0x3BFD, 0x3B8F, 0x3B21, 0x3AB4,
        0x3A48, 0x39DD, 0x3972, 0x3909, 0x38A0, 0x3837, 0x37D0, 0x3769, 0x3703, 0x369E, 0x3639, 0x35D5,
    ]

    /// The first version's waves (section `Synth`, `lbL000B56` to `lbL000B72`), as its instruments 16 to 21 play
    /// them: squares, triangles and steps of two and four words.
    static let waves: [UInt8] = [
        0x7F, 0x7F, 0x81, 0x81,
        0x7F, 0x7F, 0x7F, 0x7F, 0x81, 0x81, 0x81, 0x81,
        0x00, 0x7F, 0x00, 0x81,
        0x00, 0x59, 0x7F, 0x59, 0x00, 0xA7, 0x81, 0xA7,
        0x7F, 0x2A, 0xD5, 0x80,
        0x7F, 0x5A, 0x36, 0x11, 0xEE, 0xC9, 0xA5, 0x80,
    ]

    /// Where each wave begins in them, and its length in words.
    private static let waveParts: [(at: Int, length: UInt16)] = [
        (at: 0, length: 2), (at: 4, length: 4), (at: 12, length: 2), (at: 16, length: 4), (at: 24, length: 2),
        (at: 28, length: 4),
    ]

    /// The 400 bytes of the game's player's own code that its instrument 22 plays as noise (`lbC000394`, as Wanted
    /// Team's player carries them).
    static let trash: [UInt32] = [
        0x48E7_E0EE, 0x4BFA_078E, 0x4DF9_00DF, 0xF000_302D, 0x0018_0240, 0x0780_3D40, 0x009C_3D6D, 0x0018_009A,
        0x3D6D_0016, 0x0096_426D, 0x0016_426D, 0x0018_4A39, 0x0000_A8BC, 0x670C_0C6D, 0x0040_001A, 0x6704_536D,
        0x001A_4A39, 0x0000_A8BD, 0x670C_0C6D, 0x0080_001A, 0x6704_526D, 0x001A_41FA, 0x06DE_49EE, 0x00D0_343C,
        0x0003_0828, 0x0000_002C, 0x6700_031A, 0x5368_004E, 0x661C_3028, 0x0052_B068, 0x0050_6712, 0x6506_5368,
        0x0052_6004, 0x5268_0052, 0x3168_004C, 0x004E_5368, 0x0028_6600, 0x0242_2268, 0x000C_4240, 0x1019_4EFB,
        0x0002_6000, 0x01C4_6000, 0x03E4_6000, 0x01A8_6000, 0x002E_6000, 0x01A8_6000, 0x016A_6000, 0x0142_6000,
        0x016A_6000, 0x00CE_6000, 0x002E_6000, 0x0038_6000, 0x008A_6000, 0x00B6_6000, 0x0038_6000, 0x002E_5368,
        0x002A_6600, 0x009E_2468, 0x0004_301A, 0xB07C_FFE8, 0x656E_4EFB, 0x00EA_315A, 0x0050_3152, 0x004C_315A,
        0x004E_60E6, 0x315A_0030, 0x60E0_315A, 0x002E_60DA, 0x4850_301A, 0x321A_41FA, 0x0504_3140, 0x0050_3141,
        0x004C_3141, 0x004E_41FA, 0x0552_3140, 0x0050_3141, 0x004C_3141, 0x004E_41FA, 0x05A0_3140, 0x0050_3141,
        0x004C_3141, 0x004E_41FA, 0x05EE_3140, 0x0050_3141, 0x004C_3141, 0x004E_205F, 0x6090_2468, 0x0000_608A,
        0x317C_0001, 0x002A_0880, 0x000F_6704, 0x315A_002A, 0x226D_000A, 0xD2C0_2149, 0x0008_214A, 0x0004_6000,
        0xFF1A_2268, 0x0008_6000, 0xFF12_4268, 0x002C_6000,
    ]

    // MARK: - Reading

    /// A byte of the file, or of the two the player begins its voices on; nought anywhere else.
    @inline(__always) private func byte(_ at: Int) -> UInt8 {
        at >= 0 && (at < fileSize || at >= startAt && at < startAt + 2) ? memory[at] : 0
    }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at &+ 1)) }
    /// A word added to an address, as `ADDA.W` adds it: taken as a signed one.
    @inline(__always) private static func signed(_ value: UInt16) -> Int { Int(Int16(bitPattern: value)) }

    private static func word(_ data: [UInt8], _ at: Int) -> UInt16 {
        guard at >= 0, at + 1 < data.count else { return 0 }
        return UInt16(data[at]) << 8 | UInt16(data[at + 1])
    }

    // MARK: - Loading

    /// The layout the player's check (`Check2`) finds the file to be of, if any: ten bytes of nought; and either
    /// the four voices' volumes alike (at 164 or 516, every four bytes) and the first table they follow at the
    /// place the header gives (byte 160's word, $00B400B6; byte 512's, $02140216); or Amnios' (its volumes at 514
    /// alike, and its fourth voice's list, at the place byte 516 gives, after a word of $FFEC or $FFE8, a command
    /// that ends a list).
    static func layout(of data: [UInt8]) -> Layout? {
        guard data.count >= 178, data[0 ..< 10].allSatisfy({ $0 == 0 }) else { return nil }
        func alike(_ at: Int) -> Bool { (1 ... 3).allSatisfy { word(data, at + 4 * $0) == word(data, at) } }
        func place(_ at: Int) -> Int? {
            let value = Int16(bitPattern: word(data, at))
            return value > 0 && value & 1 == 0 ? Int(value) : nil
        }
        func long(_ at: Int) -> UInt32 { UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2)) }
        if alike(164), let at = place(160), at + 4 <= data.count, long(at) == 0x00B4_00B6 { return .second }
        guard data.count >= 530 else { return nil }
        if alike(516), let at = place(512), at + 4 <= data.count, long(at) == 0x0214_0216 { return .first }
        if alike(514), let at = place(516), at <= data.count {
            let end = word(data, at - 2)
            if end == 0xFFEC || end == 0xFFE8 { return .amnios }
        }
        return nil
    }

    /// Where the header is, and how far apart and where in each the instruments' lengths are.
    private static func header(_ layout: Layout) -> Int { layout == .second ? 0xA0 : 0x200 }
    private static func instrumentSize(_ layout: Layout) -> Int { layout == .second ? 10 : 32 }
    private static func lengthAt(_ layout: Layout) -> Int { layout == .second ? 2 : 22 }

    /// Where the samples begin, as `InitPlayer` finds them: after the list that begins furthest into the file, at
    /// the next word like the one before that list (its end, as the list before it ends); nil if there is none
    /// in the file.
    private static func samples(_ data: [UInt8], _ layout: Layout) -> Int? {
        // (The places of the lists: from 166, every four bytes, in the second layout; 518 in the first; 516 in
        // Amnios'. The furthest, as signed words, and nought at least.)
        let first = layout == .second ? 166 : layout == .first ? 518 : 516
        var furthest = 0
        for v in 0 ..< 4 {
            let at = Int(Int16(bitPattern: word(data, first + 4 * v)))
            if at >= furthest { furthest = at }
        }
        let end = word(data, furthest - 2)
        var at = furthest
        while at + 2 <= data.count {
            let value = word(data, at)
            at += 2
            if value == end { return at }
        }
        return nil
    }

    /// True for a file the player's check takes (`Check2`), and whose song and samples `InitPlayer` finds in it.
    /// (The check is of the header alone, and .ps is also PostScript's ending: this is stricter than the player,
    /// which would look past the file for the song's end and take what follows as samples.)
    static func isOne(_ data: [UInt8]) -> Bool {
        guard let layout = layout(of: data), let at = samples(data, layout) else { return false }
        return at + samplesLength(data, layout) <= data.count
    }

    /// The samples' length in all, as `InitPlayer` adds them up.
    private static func samplesLength(_ data: [UInt8], _ layout: Layout) -> Int {
        var total = 0
        for i in 0 ..< 16 { total += Int(word(data, instrumentSize(layout) * i + lengthAt(layout))) }
        return total * 2
    }

    /// Reads the file and starts its song.
    init(_ data: [UInt8], song _: Int = 0) throws(TuneError) {
        fileSize = data.count
        let found = Self.layout(of: data)
        let layout = found ?? .first
        self.layout = layout
        let samples = found.flatMap { Self.samples(data, $0) }
        samplesAt = samples ?? data.count
        var count = 0
        for i in 0 ..< 16 where Self.word(data, Self.instrumentSize(layout) * i + Self.lengthAt(layout)) != 0 { count += 1 }
        sampleCount = count
        // (The player's waves, its noughts, its noise and the byte a voice reads first, after room for a sample
        // that runs past the file.)
        wavesAt = ((data.count + 15) & ~15) + 0x100
        silenceAt = wavesAt + 36
        trashAt = silenceAt + 24
        startAt = trashAt + 400
        memoryCapacity = trashAt + 0x200 + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        for (i, b) in Self.waves.enumerated() { memory[wavesAt + i] = b }
        for (i, value) in Self.trash.enumerated() {
            for k in 0 ..< 4 { memory[trashAt + 4 * i + k] = UInt8(truncatingIfNeeded: value >> UInt32(24 - 8 * k)) }
        }
        memory[startAt] = layout == .amnios ? 0x90 : 12
        memory[startAt + 1] = 0x80
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard found != nil else { throw .malformed("not Paul Shields' music") }
        guard let samples else { throw .malformed("the end of its song is not in the file") }
        guard samples + Self.samplesLength(data, layout) <= data.count else { throw .malformed("too short for its samples") }

        setUpInstruments()
        // The song's length, from a playing of it in silence to its end.
        start()
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it came to its end in is the first of it again, or one not heard.)
        lengthClocks = endings > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil
        start()
    }

    deinit { memory.deallocate() }

    /// `InitSamplesOld`, `InitSamplesNew` and `InitSamples_2`: each instrument's sample, one after another from
    /// where the samples begin, and its loop (a loop shorter than two words is the player's noughts, two words
    /// long); and the first version's waves after them.
    private mutating func setUpInstruments() {
        let size = Self.instrumentSize(layout)
        var sample = samplesAt
        instruments = []
        for i in 0 ..< 16 {
            let at = size * i
            var instrument = Instrument()
            instrument.start = sample
            let length = word(at + Self.lengthAt(layout))
            instrument.length = length
            let fields = layout == .second ? at + 4 : at + 26
            var loopStart = sample &+ Self.signed(word(fields))
            var loopLength = word(fields + 2)
            if loopLength < 2 {
                // (The first version's sixteen noughts, `lbL0009DC`, after Amnios' eight, `lbL001F10`.)
                loopLength = 2
                loopStart = layout == .amnios ? silenceAt : silenceAt + 8
            }
            instrument.loopStart = loopStart
            instrument.loopLength = loopLength
            instrument.offset = word(fields + 4)
            instrument.volume = layout == .second ? 0 : word(at + 24)
            instruments.append(instrument)
            // (`ADD.W` of the length to the address, twice: as a signed word.)
            sample = sample &+ 2 &* Self.signed(length)
        }
        if layout != .amnios {
            for part in Self.waveParts {
                let at = wavesAt + part.at
                instruments.append(Instrument(start: at, length: part.length, loopStart: at, loopLength: part.length))
            }
            instruments.append(Instrument(start: trashAt, length: 200, loopStart: trashAt, loopLength: 200))
        }
    }

    /// `InitSong` and `InitSong_2`: the tables, and each voice's volume and list, its note's count at one and its
    /// first byte the command for the list's next pattern; its sample one of the player's (Wanted Team's: the
    /// first wave in the first version, its noughts in Amnios'), as is its loop.
    private mutating func start() {
        let header = Self.header(layout)
        var at: Int
        if layout == .amnios {
            instrumentTable = Self.signed(word(header))
            pitchTable = 0
            volumeTable = 0
            at = header + 2
            lightFilter = true
        } else {
            instrumentTable = 0
            pitchTable = Int(word(header))
            volumeTable = Int(word(header + 2))
            at = header + 4
            lightFilter = false
        }
        voices = .init(repeating: Voice())
        // (The header's first voice is the player's fourth, its last the first.)
        let idle = layout == .amnios ? silenceAt : wavesAt
        for v in (0 ..< 4).reversed() {
            var voice = Voice()
            voice.volume = word(at)
            voice.slideGoal = word(at)
            let list = layout == .amnios ? Self.signed(word(at + 2)) : Int(word(at + 2))
            at += 4
            voice.listStart = list
            voice.list = list
            voice.pattern = startAt
            voice.repeats = 1
            voice.count = 1
            voice.sampleLength = 1
            voice.loopLength = 1
            voice.sampleStart = idle
            voice.loopStart = idle
            voice.pitchStart = startAt + 1
            voice.pitchAt = startAt + 1
            voice.volumeStart = startAt + 1
            voice.volumeAt = startAt + 1
            voice.flags = 1
            voices[v] = voice
        }
        turnOn = 0
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = periods
        volumesBefore = volumes
        clock = 0
        endings = 0
        stops = 0
        astray = 0
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song == 0 else { throw .unsupported("there is no song \(song + 1)") }
        start()
    }

    private mutating func writePeriod<Output: TFMXOutput>(_ v: Int, _ period: UInt16, _ output: inout Output) {
        periods[v] = period
        output.writePeriod(v, period)
    }

    /// `ChangeVolume`: seven bits, times EaglePlayer's volume, 64, over 64.
    private mutating func writeVolume<Output: TFMXOutput>(_ v: Int, _ volume: UInt16, _ output: inout Output) {
        volumes[v] = volume & 0x7F
        output.writeVolume(v, volumes[v])
    }

    /// Runs the player for a tick (`Interrupt`), telling `output` what Paula is to do, in the order the player
    /// tells her. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        volumesBefore = volumes
        // (`Play_1`, `Play_2`: the voices of the notes begun in the tick before turned on, and those whose loops
        // are to be told this tick, the same.)
        let due = turnOn
        if turnOn != 0 {
            output.timed(at: Self.onClocks)
            for v in 0 ..< 4 where turnOn & 1 << UInt16(v) != 0 { output.on(v) }
            turnOn = 0
        }
        var at = Self.firstWrite
        let wasPlaying = (0 ..< 4).contains { voices[$0].flags & 1 != 0 }
        for v in (0 ..< 4).reversed() {
            if layout == .amnios { voiceTwo(v, &output, &at) } else { voiceOne(v, &output, &at) }
        }
        if wasPlaying, !(0 ..< 4).contains(where: { voices[$0].flags & 1 != 0 }) {
            // (Every voice stopped: the song with them.)
            endings += 1
            stops += 1
        }
        // `DMAWait`, and `Audio_1` or `Audio_2`: the loops told, the fourth voice's first.
        at = afterWait(at)
        for v in (0 ..< 4).reversed() where due & 1 << UInt16(v) != 0 {
            output.timed(at: at)
            output.takeNextBuffer(v, start: voices[v].loopStart, length: voices[v].loopLength)
            at += Self.loopClocks
        }
        // (Kept within a whole number of the beam's lines, of 227 clocks and of 227.5, which is all the wait asks
        // of it: a count of every clock would outgrow a whole number in a browser.)
        clock = (clock + Self.tickClocks) % 103_285
        return 20
    }

    /// The volume slide every voice that plays has, every so many ticks a step toward its goal.
    private mutating func slideVolume(_ v: Int) {
        voices[v].slideCount &-= 1
        guard voices[v].slideCount == 0 else { return }
        let volume = voices[v].volume
        guard volume != voices[v].slideGoal else { return }
        voices[v].volume = volume < voices[v].slideGoal ? volume &+ 1 : volume &- 1
        voices[v].slideCount = voices[v].slideEvery
    }

    /// `lbC000712`, `lbC001B10`: a note's count of ticks, a byte, or after a nought a word.
    private mutating func readCount(_ v: Int, _ at: inout Int) {
        var count = UInt16(byte(at))
        at &+= 1
        if count == 0 {
            count = word(at)
            at &+= 2
        }
        voices[v].count = count
    }

    /// The slide of a note's pitch from where it is set to `to` over its count of ticks (`lbC00042A`,
    /// `lbC001700`): its step, in 16 bits and 16 more. (Over no ticks the 68000 would trap: it does not move.)
    private mutating func slideStep(_ v: Int, to: UInt16) {
        let from = UInt16(truncatingIfNeeded: voices[v].pitch >> 16)
        let difference = to &- from
        let down = Int16(bitPattern: difference) < 0
        let distance = UInt32(down ? 0 &- difference : difference)
        let ticks = UInt32(voices[v].count)
        guard ticks != 0 else {
            voices[v].step = 0
            return
        }
        let whole = distance / ticks
        let part = ((distance % ticks) << 16) / ticks
        let step = (whole & 0xFFFF) << 16 | part & 0xFFFF
        voices[v].step = down ? 0 &- step : step
    }

    /// An instrument from the player's table, by its place in it in bytes; past the table, silence.
    private func instrument(_ place: Int) -> Instrument {
        guard place >= 0, place & 15 == 0, place / 16 < instruments.count else {
            return Instrument(start: silenceAt, length: 1, loopStart: silenceAt, loopLength: 1)
        }
        return instruments[place / 16]
    }

    private mutating func take(_ v: Int, _ instrument: Instrument) {
        voices[v].sampleStart = instrument.start
        voices[v].sampleLength = instrument.length
        voices[v].loopStart = instrument.loopStart
        voices[v].loopLength = instrument.loopLength
        voices[v].offset = instrument.offset
        voices[v].instrumentVolume = instrument.volume
    }

    /// An envelope set: its count of ticks first, and its steps from there.
    private mutating func setVolumeEnvelope(_ v: Int, _ at: Int) {
        voices[v].volumeEvery = byte(at)
        voices[v].volumeCount = byte(at)
        voices[v].volumeStart = at &+ 1
        voices[v].volumeAt = at &+ 1
    }

    private mutating func setPitchEnvelope(_ v: Int, _ at: Int) {
        voices[v].pitchEvery = byte(at)
        voices[v].pitchCount = byte(at)
        voices[v].pitchStart = at &+ 1
        voices[v].pitchAt = at &+ 1
    }

    /// The next step of an envelope, when its count is up: a signed byte, $81 to go back to its start, $80 to hold
    /// (its count left at nought, to come round again in 256 ticks). Nil for none.
    private func envelopeStep(at: inout Int, start: Int) -> UInt16? {
        var guardCount = 0
        while true {
            let step = byte(at)
            at &+= 1
            if step == 0x80 {
                at &-= 1
                return nil
            }
            if step == 0x81 {
                at = start
                guardCount += 1
                // (An envelope of nothing but going round: the 68000 would go round for ever.)
                if guardCount > 2 { return nil }
                continue
            }
            return UInt16(bitPattern: Int16(Int8(bitPattern: step)))
        }
    }

    /// The volume envelope's tick (`lbC00058A`, `lbC0017BC`).
    private mutating func volumeEnvelope(_ v: Int) {
        voices[v].volumeCount &-= 1
        guard voices[v].volumeCount == 0 else { return }
        var at = voices[v].volumeAt
        guard let step = envelopeStep(at: &at, start: voices[v].volumeStart) else { return }
        voices[v].envelopeVolume &+= step
        voices[v].volumeCount = voices[v].volumeEvery
        voices[v].volumeAt = at
    }

    /// The pitch envelope's tick (`lbC0005EC`, `lbC001828`): its steps on the pitch.
    private mutating func pitchEnvelope(_ v: Int) {
        voices[v].pitchCount &-= 1
        guard voices[v].pitchCount == 0 else { return }
        var at = voices[v].pitchAt
        guard let step = envelopeStep(at: &at, start: voices[v].pitchStart) else { return }
        voices[v].pitch &+= UInt32(step) << 16
        voices[v].pitchCount = voices[v].pitchEvery
        voices[v].pitchAt = at
    }

    /// The volume told Paula: the voice's, its envelope's, less 64, from nought to 64 (`lbC0005B8`, `lbC00184C`).
    private mutating func tellVolume<Output: TFMXOutput>(_ v: Int, _ output: inout Output, _ at: inout Int) {
        let sum = Int16(bitPattern: voices[v].volume &+ voices[v].envelopeVolume &- Self.volumeLess)
        output.timed(at: at)
        writeVolume(v, UInt16(max(0, min(64, sum))), &output)
    }

    /// `lbC0006F2`: a note, in eighths of a semitone, as a period: the voice's transposition and its instrument's
    /// added, its octave taken out, the table's period halved for each, and the voice's offset added. (Its
    /// octave found by taking 96 away until it is below nought; a note below nought so falls before the table,
    /// on the player's own code, and is taken here as the period nought, and the offset.)
    private func periodOne(_ v: Int, _ note: UInt16) -> UInt16 {
        var value = note &+ voices[v].transpose &+ voices[v].offset
        var octaves: UInt16 = 0xFFFF
        repeat {
            octaves &+= 1
            value &-= 0x60
        } while Int16(bitPattern: value) >= 0
        let index = Int(Int16(bitPattern: value &<< 1)) / 2 + 96
        var period: UInt16 = index >= 0 && index < 96 ? Self.periodTable[index] : 0
        let shift = octaves & 63
        period = shift >= 16 ? 0 : period >> shift
        return period &+ voices[v].periodOffset
    }

    /// `lbC001AEA`: as `periodOne`, but a note below nought is the period $FFFF.
    private func periodTwo(_ v: Int, _ note: UInt16) -> UInt16 {
        let value = note &+ voices[v].transpose &+ voices[v].offset
        guard Int16(bitPattern: value) >= 0 else { return 0xFFFF }
        return periodOne(v, note)
    }

    /// A note begun (`lbC00051E`, `lbC00175C`): its volume (the one set, or its instrument's), its envelopes from
    /// their starts, its voice turned off and told its sample, to be turned on in the next tick.
    private mutating func begin<Output: TFMXOutput>(_ v: Int, _ output: inout Output, _ at: inout Int) {
        voices[v].envelopeVolume = voices[v].volumeSet != 0 ? voices[v].volumeSet : voices[v].instrumentVolume
        voices[v].volumeCount = voices[v].volumeEvery
        voices[v].volumeAt = voices[v].volumeStart
        voices[v].pitchCount = voices[v].pitchEvery
        voices[v].pitchAt = voices[v].pitchStart
        output.timed(at: at)
        output.off(v)
        output.takeNextBuffer(v, start: voices[v].sampleStart, length: voices[v].sampleLength)
        turnOn |= 1 << UInt16(v)
        voices[v].flags &= ~2
        at += Self.sampleClocks
    }

    /// The commands of a list of patterns (`lbC000382`, `lbC001982`): read until a pattern. False for a voice
    /// that has stopped (or gone astray).
    private mutating func readList<Output: TFMXOutput>(_ v: Int, _ output: inout Output, _ commands: inout Int) -> Bool {
        var at = voices[v].list
        while true {
            commands += 1
            guard commands < Self.mostCommands else { return astrayStop(v) }
            let value = word(at)
            at &+= 2
            if value < 0xFFE8 {
                // A pattern, played once or as many times as the next word says.
                voices[v].repeats = 1
                var place = value
                if place & 0x8000 != 0 {
                    place &= 0x7FFF
                    voices[v].repeats = word(at)
                    at &+= 2
                }
                voices[v].patternStart = Int(place)
                voices[v].pattern = Int(place)
                voices[v].list = at
                return true
            }
            // (The commands' order in the two versions' tables.)
            let command = Int(value &- 0xFFE8)
            let kind: Int
            if layout == .amnios {
                switch command {
                case 0: kind = 5
                case 4: kind = 4
                case 8: kind = 0
                case 12: kind = 2
                case 16: kind = 1
                case 20: kind = 3
                default: kind = -1
                }
            } else {
                switch command {
                case 0: kind = 0
                case 4: kind = 1
                case 8: kind = 4
                case 12: kind = 5
                case 16: kind = 2
                case 20: kind = 3
                default: kind = -1
                }
            }
            switch kind {
            case 0:
                // A slide of the voice's volume to a goal, a step every so many ticks.
                voices[v].slideGoal = word(at)
                voices[v].slideEvery = word(at &+ 2)
                voices[v].slideCount = word(at &+ 2)
                at &+= 4
            case 1:
                voices[v].periodOffset = word(at)
                at &+= 2
            case 2:
                // The same slide for all four voices (the voices after this one taking theirs this tick).
                let goal = word(at), every = word(at &+ 2)
                at &+= 4
                for k in 0 ..< 4 {
                    voices[k].slideGoal = goal
                    voices[k].slideEvery = every
                    voices[k].slideCount = every
                }
            case 3:
                voices[v].transpose = word(at)
                at &+= 2
            case 4:
                // The list begun again: the song's end, said by its second voice (Amnios': its first).
                at = voices[v].listStart
                if v == (layout == .amnios ? 0 : 1) { endings += 1 }
            case 5:
                // The voice stopped.
                stopVoice(v)
                return false
            default:
                return astrayStop(v)
            }
        }
    }

    private mutating func stopVoice(_ v: Int) { voices[v].flags = 0 }

    /// A voice stopped where the player would have gone astray.
    private mutating func astrayStop(_ v: Int) -> Bool {
        voices[v].flags = 0
        astray += 1
        return false
    }

    /// A voice's tick in the first version (`lbC0002FA` to `lbC000624`).
    private mutating func voiceOne<Output: TFMXOutput>(_ v: Int, _ output: inout Output, _ at: inout Int) {
        guard voices[v].flags & 1 != 0 else {
            at += Self.idleClocks
            return
        }
        slideVolume(v)
        voices[v].count &-= 1
        if voices[v].count == 0 {
            var place = voices[v].pattern
            var commands = 0
            reading: while true {
                commands += 1
                guard commands < Self.mostCommands else {
                    _ = astrayStop(v)
                    return
                }
                let command = byte(place)
                place &+= 1
                switch command {
                case 0:
                    // A note (in the first byte; in eighths of a semitone, or as a period).
                    var note = UInt16(byte(place)) << 3
                    place &+= 1
                    if voices[v].flags & 8 != 0 { note = periodOne(v, note) }
                    voices[v].pitch = UInt32(note) << 16 | voices[v].pitch & 0xFFFF
                    readCount(v, &place)
                    voices[v].step = 0
                    begin(v, &output, &at)
                    voices[v].pattern = place
                    break reading
                case 4:
                    take(v, instrument(Int(byte(place)) * 16))
                    place &+= 1
                case 8:
                    voices[v].volumeSet = voices[v].volumeSet & 0xFF00 | UInt16(byte(place))
                    place &+= 1
                case 12, 60:
                    // The pattern again, or the list's next (60 falls on the same code, as the table ends).
                    voices[v].repeats &-= 1
                    if voices[v].repeats != 0 {
                        place = voices[v].patternStart
                    } else {
                        guard readList(v, &output, &commands) else {
                            at += Self.idleClocks
                            return
                        }
                        place = voices[v].pattern
                    }
                case 16:
                    // A rest: the note left to fade, by two a tick.
                    voices[v].flags |= 2
                    readCount(v, &place)
                    voices[v].pattern = place
                    break reading
                case 20, 28:
                    // A pitch envelope, in periods (20) or notes (28).
                    if command == 20 { voices[v].flags |= 8 } else { voices[v].flags &= ~8 }
                    let offset = word(pitchTable &+ Int(byte(place)))
                    place &+= 1
                    setPitchEnvelope(v, Self.signed(offset))
                case 24:
                    let offset = word(volumeTable &+ Int(byte(place)))
                    place &+= 1
                    setVolumeEnvelope(v, Self.signed(offset))
                case 32:
                    // A slide from one note to another over the note's count of ticks.
                    var from = UInt16(byte(place)) << 3
                    var to = UInt16(byte(place &+ 1)) << 3
                    place &+= 2
                    if voices[v].flags & 8 != 0 {
                        from = periodOne(v, from)
                        to = periodOne(v, to)
                    }
                    voices[v].pitch = UInt32(from) << 16 | voices[v].pitch & 0xFFFF
                    readCount(v, &place)
                    slideStep(v, to: to)
                    begin(v, &output, &at)
                    voices[v].pattern = place
                    break reading
                case 48:
                    // The voice stopped (the list's command, which this falls on).
                    stopVoice(v)
                    at += Self.idleClocks
                    return
                default:
                    // (Commands 36 to 56 fall on the list's commands, with the list's place where it was left;
                    // the rest on no command at all.)
                    _ = astrayStop(v)
                    at += Self.idleClocks
                    return
                }
            }
        }
        // The note fading, or the volume envelope; the volume; the slide and the pitch envelope; the period.
        if voices[v].flags & 2 != 0 {
            if Int16(bitPattern: voices[v].envelopeVolume) >= 0 { voices[v].envelopeVolume &-= 2 }
        } else {
            volumeEnvelope(v)
        }
        tellVolume(v, &output, &at)
        at += Self.betweenClocks
        voices[v].pitch &+= voices[v].step
        pitchEnvelope(v)
        var period = UInt16(truncatingIfNeeded: voices[v].pitch >> 16)
        if voices[v].flags & 8 == 0 { period = periodOne(v, period) }
        output.timed(at: at)
        writePeriod(v, period, &output)
        at += Self.nextClocks
    }

    /// A voice's tick in Amnios' version (`lbC001676` to `lbC00187A`). (Its sound effects, which its music never
    /// begins, are left out.)
    private mutating func voiceTwo<Output: TFMXOutput>(_ v: Int, _ output: inout Output, _ at: inout Int) {
        guard voices[v].flags & 1 != 0 else {
            at += Self.idleClocks
            return
        }
        slideVolume(v)
        voices[v].count &-= 1
        var envelope = true
        if voices[v].count == 0 {
            var place = voices[v].pattern
            var commands = 0
            reading: while true {
                commands += 1
                guard commands < Self.mostCommands else {
                    _ = astrayStop(v)
                    return
                }
                let command = byte(place)
                place &+= 1
                if command < 0x80 {
                    // A note.
                    voices[v].pitch = UInt32(UInt16(command) << 3) << 16 | voices[v].pitch & 0xFFFF
                    readCount(v, &place)
                    voices[v].step = 0
                    begin(v, &output, &at)
                    voices[v].pattern = place
                    break reading
                }
                switch command {
                case 0x80:
                    // A rest: the note left to fade (from the next tick), and its volume envelope not run.
                    voices[v].flags |= 2
                    readCount(v, &place)
                    voices[v].pattern = place
                    envelope = false
                    break reading
                case 0x84:
                    let from = UInt16(byte(place)) << 3
                    let to = UInt16(byte(place &+ 1)) << 3
                    place &+= 2
                    voices[v].pitch = UInt32(from) << 16 | voices[v].pitch & 0xFFFF
                    readCount(v, &place)
                    slideStep(v, to: to)
                    begin(v, &output, &at)
                    voices[v].pattern = place
                    break reading
                case 0x88:
                    // The volume, set as both the one set and the envelope's (their low bytes).
                    let value = UInt16(byte(place))
                    place &+= 1
                    voices[v].volumeSet = voices[v].volumeSet & 0xFF00 | value
                    voices[v].envelopeVolume = voices[v].envelopeVolume & 0xFF00 | value
                case 0x8C:
                    // An instrument: its sample, and its volume and pitch envelopes.
                    let entry = instrumentTable &+ Int(byte(place))
                    place &+= 1
                    take(v, instrument(Self.signed(word(entry))))
                    setVolumeEnvelope(v, Self.signed(word(entry &+ 2)))
                    setPitchEnvelope(v, Self.signed(word(entry &+ 4)))
                case 0x90:
                    voices[v].repeats &-= 1
                    if voices[v].repeats != 0 {
                        place = voices[v].patternStart
                    } else {
                        guard readList(v, &output, &commands) else {
                            at += Self.idleClocks
                            return
                        }
                        place = voices[v].pattern
                    }
                case 0x94, 0x98:
                    // The Amiga's filter on (its light on), or off.
                    lightFilter = command == 0x94
                    output.timed(at: at)
                    output.writeLightFilter(lightFilter)
                default:
                    _ = astrayStop(v)
                    at += Self.idleClocks
                    return
                }
            }
        } else if voices[v].flags & 2 != 0 {
            if Int16(bitPattern: voices[v].envelopeVolume) >= 0 { voices[v].envelopeVolume &-= 2 }
            envelope = false
        }
        if envelope { volumeEnvelope(v) }
        voices[v].pitch &+= voices[v].step
        pitchEnvelope(v)
        output.timed(at: at)
        writePeriod(v, periodTwo(v, UInt16(truncatingIfNeeded: voices[v].pitch >> 16)), &output)
        at += Self.betweenClocks
        tellVolume(v, &output, &at)
        at += Self.nextClocks
    }

    /// Paula's period for the voice as the tick just run began (its writes in the tick are told at their
    /// moments).
    func period(_ voice: Int) -> UInt16 { periodsBefore[voice] }
    /// Paula's volume for the voice as the tick just run began.
    func volume(_ voice: Int) -> UInt16 { volumesBefore[voice] }
    /// What the player last gave Paula's period register for the voice.
    func periodWritten(_ voice: Int) -> UInt16 { periods[voice] }
    /// What the player last gave Paula's volume register for the voice.
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Paul Shields' music, played on Paula by `PaulaTickRenderer`.
extension PaulShieldsPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Paul Shields")
        info.author = "Paul Shields"
        info.detail = "Paul Hunter's player, \(layout.name); \(sampleCount) sample\(sampleCount == 1 ? "" : "s")"
        return info
    }

    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
