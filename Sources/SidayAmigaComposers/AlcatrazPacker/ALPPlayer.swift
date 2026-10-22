// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Andy Sterbenz's replay routine of the Alcatraz Packer (1995), as Wanted Team adapted it for
// EaglePlayer ("Alcatraz Packer player module V1.1 (2 Feb 2008)", carried by UADE as
// players/Alcatraz_Packer, whose source UADE also carries as amigasrc/players/wanted_team/
// Alcatraz_Packer/Alcatraz_Packer_v2.asm). The labels given are that source's.

import SidayChips
import SidayFoundation

/// The Alcatraz Packer, in which the music of the games Cedric (Rainer Nilsen's and Andreas Oberdorfer's)
/// and Oldtimer (Stefan Poiss') was kept: a ProTracker module packed into tracks whose rows are as long
/// as they need be. "PAn" and $10; the size of it all with its samples (more than the file's, for a
/// module whose samples are in a file of their own beside it, in the collection the module's name with
/// .smp: `intro.alp`, `intro.smp`); the sizes of its four parts; the samples, sixteen bytes each (a
/// length, a finetune and a volume, a loop's length and its start); where the positions end and where
/// the song goes round to; the positions; the patterns, each four tracks; and the tracks. A row is a
/// byte of the note (and the sample's high bit), a byte of the sample and command, and the command's
/// parameter if it has one; or a byte of $80 or more, for that many rows of nothing, or of the next row
/// again.
///
/// This is the packer's player, as Wanted Team's module runs it in UADE: what it tells Paula is what that
/// player tells her, tick by tick. It is ProTracker's, more or less, with its commands numbered afresh:
/// between rows 1 arpeggio, 2 a slide either way, 3 a slide to the note, 4 vibrato, 5 and 6 those two
/// with a slide of the volume, 7 tremolo (whose wave moves, and nothing else), 8 a slide of the volume
/// either way; at the row 9 nothing (but see `volumeSlideOnNine`), A the sample from further in, B a jump, C
/// the volume, D on to the next pattern, E the filter and fine slides, F the speed. It sets no timer of
/// its own (it has only `DTP_Interrupt`), and so is run by EaglePlayer's, which UADE runs from a CIA's
/// timer of $376B: 70,940 of Paula's clocks, fifty times a second and a little less.
///
/// It owns the memory Paula plays from: the module, the sample file after it (for one that has one),
/// and the room `PaulaTickRenderer` wants, whose noughts are where a voice with nothing to play is
/// pointed. Where the player would read outside them it reads nought.
struct ALPPlayer: ~Copyable {
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    /// The module's samples, and how many bytes of sound they want against how many there are.
    let sampleCount: Int
    let soundsNeeded: Int
    let soundsGiven: Int
    /// Whether command 9, which Wanted Team's player passes over, slides the volume as 8 does. The
    /// modules of two files (all but Cedric's demo_1) use 9 where demo_1 uses 8, with the parameters
    /// of a slide, and never use 8; their own players are not known. On unless asked otherwise: played
    /// so, Cedric's music swells and fades where with it passed over its notes are held flat, and the
    /// user, listening, heard the slides as the music (2026). Off, it is as UADE plays it.
    let volumeSlideOnNine: Bool

    /// Where the positions, patterns and tracks are (`lbL0033AA`), and the samples' table.
    private var positions = 0
    private var patterns = 0
    private var tracks = 0
    /// The module's addresses as the player makes them, in `memory`: the image `Init` leaves, for each
    /// start of the song to begin from.
    private var image: [UInt8] = []

    /// One voice, as the player keeps it: six bytes for each in five rows of 24 (`lbL0033BE`, and
    /// `lbL00341E` for the last), named by what its fields are, at their offsets.
    private struct Voice {
        /// The note, an offset into a finetune's periods (0), the sample (1), the command (2) and its
        /// parameter (3), and the volume (5).
        var note: UInt8 = 0
        var sample: UInt8 = 0
        var command: UInt8 = 0
        var parameter: UInt8 = 0
        var volume: UInt8 = 0
        /// The vibrato's command and where it is in its wave ($18, $19); the period a slide goes to ($1A,
        /// nought once there) and the period ($1C).
        var vibrato: UInt8 = 0
        var vibratoAt: UInt8 = 0
        var target: UInt16 = 0
        var period: UInt16 = 0
        /// The tremolo's command and where it is ($30, $31), the slide's speed ($33), down in period
        /// ($34), and the last offset into the sample ($35).
        var tremolo: UInt8 = 0
        var tremoloAt: UInt8 = 0
        var slideSpeed: UInt8 = 0
        var slidesDown = false
        var offset: UInt8 = 0
        /// Where the track is read next ($48), the rows left to pass ($4C) and whether they are of
        /// nothing ($4D).
        var track = 0
        var rowsLeft: UInt8 = 0
        var empty = false
        /// The sample's loop, told Paula at every tick ($60, $64).
        var loop = 0
        var loopLength: UInt16 = 0
    }

    /// The voices, the first being Paula's last (the player goes from the fourth down to the first).
    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// Each of Paula's voices' finetune, as offsets into the periods, which the arpeggio adds its notes
    /// to (the three words before the table, and its first, which the fourth voice's overwrites).
    private var finetunes = InlineArray<4, UInt16>(repeating: 0)
    /// The ticks left of the row and the ticks a row lasts (`lbL0033B6`, 0 and 1), the rows left of the
    /// pattern (2, its top bit set to go on at once), whether a row has just been read (3), the voices
    /// the last row began notes on (5), and the position, in bytes (6).
    private var count: UInt8 = 0
    private var speed: UInt8 = 6
    private var rows: UInt8 = 0
    private var rowRead = false
    private var startedVoices: UInt8 = 0
    private var position: UInt16 = 0
    /// What each of Paula's period and volume registers was last given, and the Amiga's filter.
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private(set) var lightFilter = false

    /// The positions begun since the song last came to its end, a bit for each place.
    private var begun = [UInt64](repeating: 0, count: 1024)
    private var endPending = false
    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?

    static let tickClocks = TFMXTiming.fiftyTimes
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60

    /// ProTracker's periods (`lbL002BC6`), a word of nought and then 36 for each of the sixteen
    /// finetunes, read by the note, which is an offset in bytes from the finetune's.
    private static let periodTable: [UInt16] = [
        0,
        0x358, 0x328, 0x2FA, 0x2D0, 0x2A6, 0x280, 0x25C, 0x23A, 0x21A, 0x1FC, 0x1E0, 0x1C5, 0x1AC, 0x194, 0x17D, 0x168, 0x153, 0x140,
        0x12E, 0x11D, 0x10D, 0x0FE, 0x0F0, 0x0E2, 0x0D6, 0x0CA, 0x0BE, 0x0B4, 0x0AA, 0x0A0, 0x097, 0x08F, 0x087, 0x07F, 0x078, 0x071,
        0x352, 0x322, 0x2F5, 0x2CB, 0x2A2, 0x27D, 0x259, 0x237, 0x217, 0x1F9, 0x1DD, 0x1C2, 0x1A9, 0x191, 0x17B, 0x165, 0x151, 0x13E,
        0x12C, 0x11C, 0x10C, 0x0FD, 0x0EF, 0x0E1, 0x0D5, 0x0C9, 0x0BD, 0x0B3, 0x0A9, 0x09F, 0x096, 0x08E, 0x086, 0x07E, 0x077, 0x071,
        0x34C, 0x31C, 0x2F0, 0x2C5, 0x29E, 0x278, 0x255, 0x233, 0x214, 0x1F6, 0x1DA, 0x1BF, 0x1A6, 0x18E, 0x178, 0x163, 0x14F, 0x13C,
        0x12A, 0x11A, 0x10A, 0x0FB, 0x0ED, 0x0E0, 0x0D3, 0x0C7, 0x0BC, 0x0B1, 0x0A7, 0x09E, 0x095, 0x08D, 0x085, 0x07D, 0x076, 0x070,
        0x346, 0x317, 0x2EA, 0x2C0, 0x299, 0x274, 0x250, 0x22F, 0x210, 0x1F2, 0x1D6, 0x1BC, 0x1A3, 0x18B, 0x175, 0x160, 0x14C, 0x13A,
        0x128, 0x118, 0x108, 0x0F9, 0x0EB, 0x0DE, 0x0D1, 0x0C6, 0x0BB, 0x0B0, 0x0A6, 0x09D, 0x094, 0x08C, 0x084, 0x07D, 0x076, 0x06F,
        0x340, 0x311, 0x2E5, 0x2BB, 0x294, 0x26F, 0x24C, 0x22B, 0x20C, 0x1EF, 0x1D3, 0x1B9, 0x1A0, 0x188, 0x172, 0x15E, 0x14A, 0x138,
        0x126, 0x116, 0x106, 0x0F7, 0x0E9, 0x0DC, 0x0D0, 0x0C4, 0x0B9, 0x0AF, 0x0A5, 0x09C, 0x093, 0x08B, 0x083, 0x07C, 0x075, 0x06E,
        0x33A, 0x30B, 0x2E0, 0x2B6, 0x28F, 0x26B, 0x248, 0x227, 0x208, 0x1EB, 0x1CF, 0x1B5, 0x19D, 0x186, 0x170, 0x15B, 0x148, 0x135,
        0x124, 0x114, 0x104, 0x0F5, 0x0E8, 0x0DB, 0x0CE, 0x0C3, 0x0B8, 0x0AE, 0x0A4, 0x09B, 0x092, 0x08A, 0x082, 0x07B, 0x074, 0x06D,
        0x334, 0x306, 0x2DA, 0x2B1, 0x28B, 0x266, 0x244, 0x223, 0x204, 0x1E7, 0x1CC, 0x1B2, 0x19A, 0x183, 0x16D, 0x159, 0x145, 0x133,
        0x122, 0x112, 0x102, 0x0F4, 0x0E6, 0x0D9, 0x0CD, 0x0C1, 0x0B7, 0x0AC, 0x0A3, 0x09A, 0x091, 0x089, 0x081, 0x07A, 0x073, 0x06D,
        0x32E, 0x300, 0x2D5, 0x2AC, 0x286, 0x262, 0x23F, 0x21F, 0x201, 0x1E4, 0x1C9, 0x1AF, 0x197, 0x180, 0x16B, 0x156, 0x143, 0x131,
        0x120, 0x110, 0x100, 0x0F2, 0x0E4, 0x0D8, 0x0CC, 0x0C0, 0x0B5, 0x0AB, 0x0A1, 0x098, 0x090, 0x088, 0x080, 0x079, 0x072, 0x06C,
        0x38B, 0x358, 0x328, 0x2FA, 0x2D0, 0x2A6, 0x280, 0x25C, 0x23A, 0x21A, 0x1FC, 0x1E0, 0x1C5, 0x1AC, 0x194, 0x17D, 0x168, 0x153,
        0x140, 0x12E, 0x11D, 0x10D, 0x0FE, 0x0F0, 0x0E2, 0x0D6, 0x0CA, 0x0BE, 0x0B4, 0x0AA, 0x0A0, 0x097, 0x08F, 0x087, 0x07F, 0x078,
        0x384, 0x352, 0x322, 0x2F5, 0x2CB, 0x2A3, 0x27C, 0x259, 0x237, 0x217, 0x1F9, 0x1DD, 0x1C2, 0x1A9, 0x191, 0x17B, 0x165, 0x151,
        0x13E, 0x12C, 0x11C, 0x10C, 0x0FD, 0x0EE, 0x0E1, 0x0D4, 0x0C8, 0x0BD, 0x0B3, 0x0A9, 0x09F, 0x096, 0x08E, 0x086, 0x07E, 0x077,
        0x37E, 0x34C, 0x31C, 0x2F0, 0x2C5, 0x29E, 0x278, 0x255, 0x233, 0x214, 0x1F6, 0x1DA, 0x1BF, 0x1A6, 0x18E, 0x178, 0x163, 0x14F,
        0x13C, 0x12A, 0x11A, 0x10A, 0x0FB, 0x0ED, 0x0DF, 0x0D3, 0x0C7, 0x0BC, 0x0B1, 0x0A7, 0x09E, 0x095, 0x08D, 0x085, 0x07D, 0x076,
        0x377, 0x346, 0x317, 0x2EA, 0x2C0, 0x299, 0x274, 0x250, 0x22F, 0x210, 0x1F2, 0x1D6, 0x1BC, 0x1A3, 0x18B, 0x175, 0x160, 0x14C,
        0x13A, 0x128, 0x118, 0x108, 0x0F9, 0x0EB, 0x0DE, 0x0D1, 0x0C6, 0x0BB, 0x0B0, 0x0A6, 0x09D, 0x094, 0x08C, 0x084, 0x07D, 0x076,
        0x371, 0x340, 0x311, 0x2E5, 0x2BB, 0x294, 0x26F, 0x24C, 0x22B, 0x20C, 0x1EE, 0x1D3, 0x1B9, 0x1A0, 0x188, 0x172, 0x15E, 0x14A,
        0x138, 0x126, 0x116, 0x106, 0x0F7, 0x0E9, 0x0DC, 0x0D0, 0x0C4, 0x0B9, 0x0AF, 0x0A5, 0x09C, 0x093, 0x08B, 0x083, 0x07B, 0x075,
        0x36B, 0x33A, 0x30B, 0x2E0, 0x2B6, 0x28F, 0x26B, 0x248, 0x227, 0x208, 0x1EB, 0x1CF, 0x1B5, 0x19D, 0x186, 0x170, 0x15B, 0x148,
        0x135, 0x124, 0x114, 0x104, 0x0F5, 0x0E8, 0x0DB, 0x0CE, 0x0C3, 0x0B8, 0x0AE, 0x0A4, 0x09B, 0x092, 0x08A, 0x082, 0x07B, 0x074,
        0x364, 0x334, 0x306, 0x2DA, 0x2B1, 0x28B, 0x266, 0x244, 0x223, 0x204, 0x1E7, 0x1CC, 0x1B2, 0x19A, 0x183, 0x16D, 0x159, 0x145,
        0x133, 0x122, 0x112, 0x102, 0x0F4, 0x0E6, 0x0D9, 0x0CD, 0x0C1, 0x0B7, 0x0AC, 0x0A3, 0x09A, 0x091, 0x089, 0x081, 0x07A, 0x073,
        0x35E, 0x32E, 0x300, 0x2D5, 0x2AC, 0x286, 0x262, 0x23F, 0x21F, 0x201, 0x1E4, 0x1C9, 0x1AF, 0x197, 0x180, 0x16B, 0x156, 0x143,
        0x131, 0x120, 0x110, 0x100, 0x0F2, 0x0E4, 0x0D8, 0x0CB, 0x0C0, 0x0B5, 0x0AB, 0x0A1, 0x098, 0x090, 0x088, 0x080, 0x079, 0x072,
    ]
    /// The vibrato's wave (`lbW0032FC`): half of a sine, from nought up to 255 and down.
    private static let sine: [UInt8] = [
        0x00, 0x18, 0x31, 0x4A, 0x61, 0x78, 0x8D, 0xA1, 0xB4, 0xC5, 0xD4, 0xE0, 0xEB, 0xF4, 0xFA, 0xFD,
        0xFF, 0xFD, 0xFA, 0xF4, 0xEB, 0xE0, 0xD4, 0xC5, 0xB4, 0xA1, 0x8D, 0x78, 0x61, 0x4A, 0x31, 0x18,
    ]

    @inline(__always) private func byte(_ a: Int) -> UInt8 { a >= 0 && a < memoryCapacity ? memory[a] : 0 }
    @inline(__always) private func word(_ a: Int) -> UInt16 { UInt16(byte(a)) << 8 | UInt16(byte(a + 1)) }
    @inline(__always) private func long(_ a: Int) -> UInt32 { UInt32(word(a)) << 16 | UInt32(word(a + 2)) }
    @inline(__always) private func setLong(_ a: Int, _ v: UInt32) {
        for i in 0 ..< 4 where a + i >= 0 && a + i < silenceAt { memory[a + i] = UInt8(truncatingIfNeeded: v >> UInt32(24 - 8 * i)) }
    }

    /// A word as the 68000 adds it to an address: with its sign.
    @inline(__always) private static func signed(_ w: UInt16) -> Int { Int(Int16(bitPattern: w)) }

    /// True for a file the player's check takes (`Check2`): "PAn" and $10, and a size after it of more
    /// than nought (and less than 2 GB).
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 8, data[0] == 0x50, data[1] == 0x41, data[2] == 0x6E, data[3] == 0x10 else { return false }
        return data[4] & 0x80 == 0 && (data[4] | data[5] | data[6] | data[7]) != 0
    }

    /// Whether the module keeps its samples in a file of their own: the size it gives is more than its
    /// own (`Check2`).
    static func wantsSampleFile(_ data: [UInt8]) -> Bool {
        guard isOne(data) else { return false }
        let size = Int(data[4]) << 24 | Int(data[5]) << 16 | Int(data[6]) << 8 | Int(data[7])
        return size > data.count
    }

    /// Reads the module and its samples (`samples`, the file beside it, for a module that wants one; for
    /// one that does not, its own) and starts its song (it has one: `song` is taken for that one).
    init(_ data: [UInt8], samples: [UInt8] = [], song _: Int = 0, volumeSlideOnNine: Bool = true) throws(TuneError) {
        func word(_ a: Int) -> UInt16 { a >= 0 && a + 1 < data.count ? UInt16(data[a]) << 8 | UInt16(data[a + 1]) : 0 }
        self.volumeSlideOnNine = volumeSlideOnNine
        var refusal: TuneError?
        if !Self.isOne(data) { refusal = .unsupported("not an Alcatraz Packer module") }
        let twoFiles = Self.wantsSampleFile(data)
        // `InitPlayer`: the song's size, the four parts' and the eight bytes before them, within the file.
        let parts = (0 ..< 4).map { Int(word(8 + 2 * $0)) }
        let songSize = 8 + parts.reduce(0, +)
        if refusal == nil, songSize > data.count { refusal = .malformed("it is cut short") }
        let count = parts[0] >> 4
        sampleCount = count
        if refusal == nil, count == 0 { refusal = .malformed("it has no samples") }
        if refusal == nil, twoFiles, samples.isEmpty {
            refusal = .missingCompanion("An Alcatraz Packer module of two files keeps its samples in a file of their own, which was not given with it.")
        }
        var needed = 0
        for s in 0 ..< count { needed += 2 * Int(word(16 + 16 * s + 4)) }
        soundsNeeded = needed
        let samplesAt = twoFiles ? (data.count + 15) & ~15 : songSize
        soundsGiven = twoFiles ? samples.count : max(0, data.count - songSize)
        silenceAt = twoFiles ? (samplesAt + samples.count + 15) & ~15 : data.count
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        if twoFiles { for (i, b) in samples.enumerated() { memory[samplesAt + i] = b } }
        if let refusal { throw refusal }

        // `Init`: where the parts are, and each sample's sound and loop made addresses in its record.
        positions = 8 + parts[0]
        patterns = positions + parts[1]
        tracks = patterns + parts[2]
        var sound = samplesAt
        for s in 0 ..< count {
            let entry = 16 + 16 * s
            setLong(entry, UInt32(truncatingIfNeeded: sound))
            setLong(entry + 8, UInt32(truncatingIfNeeded: sound + 2 * Int(self.word(entry + 14))))
            sound += 2 * Int(self.word(entry + 4))
        }
        image = Array(UnsafeBufferPointer(start: memory, count: silenceAt))
        start()
        // The song's length, from a playing of it in silence to its end.
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it came to its end in is the first of it again.)
        lengthClocks = endings > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil
        start()
    }

    deinit { memory.deallocate() }

    /// The song from its beginning: the module as `Init` left it, the speed six, all quiet, and the
    /// first position begun (`lbC002A88`).
    private mutating func start() {
        image.withUnsafeBufferPointer { memory.update(from: $0.baseAddress!, count: $0.count) }
        voices = .init(repeating: Voice())
        for v in 0 ..< 4 { voices[v].loop = silenceAt }
        finetunes = .init(repeating: 0)
        count = 0
        speed = 6
        rows = 0
        rowRead = false
        startedVoices = 0
        position = 0
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        lightFilter = false
        for i in begun.indices { begun[i] = 0 }
        newPosition()
        endPending = false
        endings = 0
    }

    var songCount: Int { 1 }
    var song: Int { 0 }

    mutating func select(song _: Int) throws(TuneError) { start() }

    /// `lbC002A88`: the position begun, its four tracks from their starts; at the end of the positions,
    /// the one the song goes round to (where it has come to its end; and, in siday's reckoning, where a
    /// jump brings it back to a position begun since its start).
    private mutating func newPosition() {
        rows = 0x40
        var ended = false
        if position == word(positions - 4) {
            position = word(positions - 2)
            ended = true
        }
        let index = Int(position >> 6), bit = UInt64(1) << UInt64(position & 63)
        if ended || begun[index] & bit != 0 {
            // (Counted at the position's first row, which is read a few ticks on.)
            endPending = true
            for i in begun.indices { begun[i] = 0 }
        }
        begun[index] |= bit
        let pattern = patterns + Self.signed(word(positions + Self.signed(position)))
        for i in 0 ..< 4 {
            voices[i].track = tracks + Self.signed(word(pattern + 2 * i))
            voices[i].rowsLeft = 0
        }
    }

    /// The player's interrupt for a tick: `Play_1` (`lbC002ACE`), then `Play_2`: the voices the last row
    /// began notes on turned on (again), and every voice told its sample's loop.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        // lbC002A74: after a row, the pattern's rows counted down; at its end, the next position.
        if rowRead {
            rowRead = false
            if Int(Int8(bitPattern: rows)) - 1 > 0 {
                rows &-= 1
            } else {
                rows &-= 1
                position &+= 2
                newPosition()
            }
        }
        if Int(Int8(bitPattern: count)) - 1 > 0 {
            count &-= 1
            for i in 0 ..< 4 { between(i) }
        } else {
            count &-= 1
            readRow(&output)
        }
        for i in (0 ..< 4).reversed() where startedVoices & 1 << UInt8(i) != 0 { output.on(i) }
        for i in 0 ..< 4 { output.takeNextBuffer(3 - i, start: voices[i].loop, length: voices[i].loopLength) }
        return 20
    }

    /// The row (from `lbC002AEA`): each voice's, the fourth first; then the voices beginning notes
    /// turned off, to be turned on again.
    private mutating func readRow<Output: TFMXOutput>(_ output: inout Output) {
        rowRead = true
        if endPending {
            endPending = false
            endings += 1
        }
        var began: UInt8 = 0
        var parameter: UInt8 = 0
        for i in 0 ..< 4 {
            let hardware = 3 - i
            var at = voices[i].track
            var readNext = true
            if voices[i].rowsLeft != 0 {
                voices[i].rowsLeft &-= 1
                readNext = !voices[i].empty
            }
            // (A byte of $80 or more is followed by the row it counts, or by another of them.)
            var reads = 0
            while readNext, byte(at) & 0x80 != 0, reads < 0x10000 {
                let counted = ~byte(at)
                at += 1
                voices[i].empty = counted & 0x40 != 0
                voices[i].rowsLeft = counted & ~0x40
                voices[i].track = at
                voices[i].command = 0
                readNext = !voices[i].empty
                reads += 1
            }
            if readNext {
                // lbC002B2E: a row.
                let first = byte(at)
                let second = byte(at + 1)
                at += 2
                let number = (second >> 4) &+ (first & 1 != 0 ? 16 : 0)
                if number != 0 { voices[i].sample = number }
                var entry = 16 * Int(voices[i].sample)
                if number != 0 { voices[i].volume = byte(entry + 7) }
                let command = second & 15
                voices[i].command = command
                if command != 0 {
                    parameter = byte(at)
                    at += 1
                    voices[i].parameter = parameter
                }
                let note = first & 0xFE
                var commandAtRow = Int(command) - 9
                if note != 0 {
                    let finetune = UInt16(byte(entry + 6)) &* 0x48
                    setFinetune(hardware, finetune)
                    let period = periodWord(Int(finetune &+ UInt16(note)) >> 1)
                    if command == 3 || command == 5 {
                        // lbC003048: a slide to the note, none if it is the note already.
                        // (`smi`: the sign of the difference, or none for the same.)
                        voices[i].slidesDown = Int16(bitPattern: period &- voices[i].period) < 0
                        voices[i].target = period == voices[i].period ? 0 : period
                        commandAtRow = -1
                    } else {
                        voices[i].note = note
                        voices[i].period = period
                        voices[i].vibratoAt = 0
                        voices[i].tremoloAt = 0
                        began |= 1 << UInt8(hardware)
                        output.takeNextBuffer(hardware, start: Int(long(entry)), length: word(entry + 4))
                        voices[i].loop = Int(long(entry + 8))
                        voices[i].loopLength = word(entry + 12)
                        // (The record's address as the player has left it, past what it has read of it.)
                        entry += 14
                    }
                }
                if commandAtRow >= 0 { rowCommand(i, commandAtRow, parameter, entry: entry, &output) }
                if voices[i].rowsLeft == 0 { voices[i].track = at }
            }
            // lbC003070: the period and volume told Paula.
            periods[hardware] = voices[i].period
            volumes[hardware] = UInt16(voices[i].volume & 0x7F)
        }
        count = speed
        startedVoices = began
        for v in 0 ..< 4 where began & 1 << UInt8(v) != 0 { output.off(v) }
    }

    /// Paula's voice's finetune, which the fourth's writes over the table's first word.
    private mutating func setFinetune(_ hardware: Int, _ value: UInt16) { finetunes[hardware] = value }

    /// The table's word, the first being where the fourth voice's finetune is kept; past its end, nought.
    private func periodWord(_ i: Int) -> UInt16 {
        if i == 0 { return finetunes[3] }
        return i > 0 && i < Self.periodTable.count ? Self.periodTable[i] : 0
    }

    /// `lbC0030D4`: a command of the row (9 to F, as 0 to 6). `entry` is where the player's pointer into
    /// the samples' table is: the sample's record, or 14 bytes into it after a note.
    private mutating func rowCommand<Output: TFMXOutput>(_ i: Int, _ command: Int, _ parameter: UInt8, entry: Int, _ output: inout Output) {
        let hardware = 3 - i
        switch command {
        case 1:
            // lbC003114: the sample from 256 bytes a step further in (the last, for nought).
            if parameter != 0 { voices[i].offset = parameter }
            let record = entry - 14
            let words = UInt16(voices[i].offset) << 7
            var length = word(record + 4)
            if Int16(bitPattern: length) > Int16(bitPattern: words) { length &-= words } else { length = 1 }
            let start = Int(long(record)) + Self.signed(words &* 2)
            output.takeNextBuffer(hardware, start: start, length: length)
        case 2:
            // lbC003100: to the position the parameter gives, in bytes with a sign, at the next tick
            // (and on one from it).
            position = UInt16(bitPattern: Int16(Int8(bitPattern: parameter)))
            rows |= 0x80
        case 3: voices[i].volume = parameter
        case 4: rows |= 0x80
        case 5:
            // lbC00314E: E, by its high four bits: the filter (off for bit 1 of the low four), the period
            // down or up, the volume down or up, by the low four. (For more than four, the player jumps
            // into its own code, which no module of the collection does: here, nothing.)
            let by = parameter & 15
            switch parameter >> 4 {
            case 0: lightFilter = by & 2 == 0
            case 1: slide(i, by: -Int16(by))
            case 2: slide(i, by: Int16(by))
            case 3: slideVolume(i, by: 0 &- by)
            case 4: slideVolume(i, by: by)
            default: break
            }
        case 6: speed = parameter
        default: break
        }
    }

    /// `lbC0031CC`: the period down by `by`, between 113 and 856 (told Paula).
    private mutating func slide(_ i: Int, by: Int16) {
        // (`bpl` and `bmi`: the sign of the difference, as the 68000's compare leaves it.)
        var period = voices[i].period &- UInt16(bitPattern: by)
        if Int16(bitPattern: period &- 0x71) < 0 { period = 0x71 }
        if Int16(bitPattern: period &- 0x358) >= 0 { period = 0x358 }
        voices[i].period = period
        periods[3 - i] = period
    }

    /// `lbC0031F6`: the volume up by `by` (with a sign, in a byte): over 127 is nought, over 64 is 64.
    private mutating func slideVolume(_ i: Int, by: UInt8) {
        let volume = voices[i].volume &+ by
        voices[i].volume = volume & 0x80 != 0 ? 0 : min(volume, 0x40)
    }

    /// `lbC003172`: a voice's command between rows, then its volume told Paula.
    private mutating func between(_ i: Int) {
        let hardware = 3 - i
        var command = voices[i].command
        if command == 9, volumeSlideOnNine { command = 8 }
        let parameter = voices[i].parameter
        switch command {
        case 1:
            // lbC003218: the arpeggio, as the ticks of the row go: the note, then up by the high four
            // bits, then the low (no further than the table's 36th note of the voice's finetune).
            var tick = Int8(bitPattern: count &- speed)
            repeat { tick &+= 3 } while tick < 0
            if tick == 0 {
                periods[hardware] = voices[i].period
            } else {
                let nibble = tick == 1 ? parameter & 15 : parameter >> 4 & 15
                let offset = min(UInt16((nibble &* 2) &+ voices[i].note), 0x48)
                periods[hardware] = periodWord(Int(finetunes[hardware] &+ offset) >> 1)
            }
        case 2: slide(i, by: Int16(Int8(bitPattern: parameter)))
        case 3:
            if parameter != 0 { voices[i].slideSpeed = parameter }
            slideToNote(i)
        case 4:
            if parameter != 0 { voices[i].vibrato = parameter }
            periods[hardware] = vibrato(i)
        case 5:
            slideToNote(i)
            slideVolume(i, by: parameter)
        case 6:
            periods[hardware] = vibrato(i)
            slideVolume(i, by: parameter)
        case 7:
            // lbC003290: the tremolo, of which only its place in its wave moves.
            if parameter != 0 { voices[i].tremolo = parameter }
            voices[i].tremoloAt &+= (voices[i].tremolo >> 2) & 0x3C
        case 8: slideVolume(i, by: parameter)
        default: break
        }
        volumes[hardware] = UInt16(voices[i].volume & 0x7F)
    }

    /// `lbC00325E`: the slide to the note, until it is there.
    private mutating func slideToNote(_ i: Int) {
        let target = voices[i].target
        guard target != 0 else { return }
        let by = UInt16(voices[i].slideSpeed)
        var period = voices[i].period
        if !voices[i].slidesDown {
            period &+= by
            if Int16(bitPattern: target) <= Int16(bitPattern: period) {
                period = target
                voices[i].target = 0
            }
        } else {
            period &-= by
            if Int16(bitPattern: target) >= Int16(bitPattern: period) {
                period = target
                voices[i].target = 0
            }
        }
        periods[3 - i] = period
        voices[i].period = period
    }

    /// `lbC0032C2`: the vibrato's period, ProTracker's; its wave moved on.
    private mutating func vibrato(_ i: Int) -> UInt16 {
        let at = voices[i].vibratoAt
        var depth = Int16((UInt16(Self.sine[Int((at >> 2) & 0x1F)]) * UInt16(voices[i].vibrato & 15)) >> 7)
        if at & 0x80 != 0 { depth = -depth }
        voices[i].vibratoAt &+= (voices[i].vibrato >> 2) & 0x3C
        return voices[i].period &+ UInt16(bitPattern: depth)
    }

    /// Paula's period for the voice, as the player last set it.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// Paula's volume for the voice, as the player last set it.
    func volume(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// The Alcatraz Packer, played on Paula by `PaulaTickRenderer`.
extension ALPPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "ALP")
        let plural = sampleCount == 1 ? "" : "s"
        info.detail = "Alcatraz Packer; \(sampleCount) sample\(plural)"
        if soundsGiven < soundsNeeded {
            info.shortfalls.append("Its samples are cut short, and what is missing of them is silent.")
        }
        return info
    }

    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -22.5 dB, its
    /// command 9 played as a slide.)
    var gain: Float { 0.38 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
