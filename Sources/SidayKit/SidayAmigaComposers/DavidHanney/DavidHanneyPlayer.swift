// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after David Hanney's replayer of Tearaway Thomas ("(c) 1992 by David Hanney", its player says), as
// Mr.Larmer of Wanted Team and DEFECT adapted it for EaglePlayer ("David Hanney player module V1.1 (28 Feb 97)", carried by
// UADE as players/DavidHanney). No source of it is known: this is written from a disassembly of that
// binary, and the addresses given are of its first hunk, its code. The replayer's variables are named by
// their offsets from its base, the 680 bytes from code $450 (`A5` while it runs); the voices' and the
// instruments' by theirs from the starts of their own. The samples and instruments it plays are copied
// from the binary's second hunk (`DavidHanneyData`).

/// David Hanney's music for Tearaway Thomas, the only game of UnExoticA's with it: four voices of the
/// game's sixteen instruments, which the files do not carry; thirteen of them short waves that the
/// replayer changes as it plays them, and three of them samples.
///
/// The file: 'DSNG', and then chunks, each an id and a length (a long each) before what it holds:
/// 'SEQU' (256 bytes, the blocks in the order they are played), 'INFO' (the sequence's length, a word
/// that is not used, and the song's speed: the ticks of a row, less one) and the blocks, 'BLK' and the
/// block's number, each a word (its rows) and its rows; a long of nought after the last. A row is three
/// bytes for each voice: a note (nought for none, 1 to stop the voice, 2 to let it die away, and from 3
/// the notes of the replayer's table of periods), an instrument and an effect: $1n a slide to the note
/// at speed n + 1 (and no new note), $2n the speed of the envelope, $3n an arpeggio from the replayer's
/// tables, and $4n the note struck again halfway through the row.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that
/// player tells her, tick by tick. It runs fifty times a second. A note of a wave is started by turning
/// the voice off and telling it its instrument's wave, and the voice is turned on at the next tick,
/// where each tick tells it its period (slid, or from its arpeggio, and bent by the instrument's
/// vibrato) and its volume (from the instrument's envelope of four steps, each a level and how fast it
/// is gone to), and moves the instrument's changing wave on by a byte. A sample is told its period and a
/// volume of 63 at once, turned on at the next tick and then told to go on round its first word.
///
/// The song goes round at the end of its sequence, as the player tells EaglePlayer (`ENPP_SongEnd`).
struct DavidHanneyPlayer: ~Copyable {
    /// The game's samples and instruments as Paula reads them (`DavidHanneyData`), and what follows them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: the noughts after the instruments. (No voice is.)
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    /// The file, which only the replayer reads.
    private let module: [UInt8]
    /// Its chunks after 'DSNG', in order, each id with where what it holds begins; and where the walk
    /// through them comes to a stop (after the nought that ends them), where the replayer is left
    /// looking for one that is not there.
    private let chunks: [(id: UInt32, at: Int)]
    private let chunksEnd: Int
    /// Where each block's word of rows is, by the low byte of its number (-1 for one not there).
    private let blockPlaces: [Int]
    /// Where the sequence ('SEQU') is (`$182`).
    private let sequenceAt: Int
    let blockCount: Int

    var songCount: Int { 1 }
    var song: Int { 0 }
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?

    /// A voice (52 bytes, from the base's $190), its fields at their offsets: where Paula was last told
    /// to play from (from the voice's location register, its first field), the instrument (8), the
    /// ticks before its note is struck again (12), the row's note, instrument and effect (13 to 15), its
    /// state (16: 0 nothing to do, 4 a sample to turn on, 8 a wave to play), the envelope's speed (20) and
    /// count (21), the vibrato's place (22) and ticks before it begins (23), the envelope's step (24) and
    /// level (26, four times the volume), the arpeggio (28, twelve notes up from the note) and its place
    /// (40), the note (42), the period (44), the period slid to (46) and the slide's speed (48). (Its
    /// flag at 50, without which the voice is told nothing, is cleared and set only by the replayer's
    /// entries at code $708 and $722, which EaglePlayer's module never calls, and is left out.)
    struct Voice {
        var location = 0
        var instrument = -1
        var again: UInt8 = 0
        var note: UInt8 = 0
        var instrumentNumber: UInt8 = 0
        var effect: UInt8 = 0
        var state: UInt16 = 0
        var envelopeSpeed: UInt8 = 2
        var envelopeCount: UInt8 = 0
        var vibratoPlace: UInt8 = 0
        var vibratoDelay: UInt8 = 0
        var envelopeStep: UInt16 = 0
        var level: UInt16 = 0
        var arpeggio = InlineArray<12, UInt8>(repeating: 0)
        var arpeggioPlace: UInt16 = 0
        var baseNote: UInt16 = 0
        var period: UInt16 = 0
        var target: UInt16 = 0
        var slide: UInt16 = 0
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// The ticks counted (`$175`), whether it plays (`$176`), the row (`$17C`), the block's last row
    /// (`$188`), the place in the sequence (`$18A`), the ticks to the next row
    /// (`$18E`), the speed (`$264`) and the sequence's length (`$266`).
    private var ticks: UInt8 = 0
    private var playing = false
    private var row: UInt16 = 0
    private var lastRow: UInt16 = 0
    private var place: UInt16 = 0
    private var countdown: UInt16 = 0
    private var speed: UInt16 = 0
    private var sequenceLength: UInt16 = 0
    /// Where the block's rows are (the block, or where the replayer was left looking for one it has not).
    /// (The replayer finds it again from the block's number, `$18C`, at every row: at the same place.)
    private var blockAt = 0
    /// The song has come to the end of its sequence, and goes round from its next row.
    private var goesRound = false
    /// What each of Paula's period and volume registers was last given, and what they held as the tick
    /// just run began (what `PaulaTickRenderer` sets Paula to then, before the tick's writes are told).
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)

    /// How long each tick is: the player is run by EaglePlayer's timer (it has an interrupt and does not
    /// start one of its own), which UADE's runs on a CIA's timer from $376B (score.s,
    /// `cia_timer_base_value`), 70,940 of Paula's clocks.
    static let tickClocks = (0x376B + 1) * 5
    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (the medians of its dumps of
    /// the game's music; UADE's `ENPP_DMAMask` waits for the audio DMA after it turns a voice on (score.s,
    /// `enpp_amplifier_dma`), some 2,100 clocks, and the rest of the time is the replayer's own): the first voice's period (a guess: only the
    /// distances between the writes are heard); a wave's volume after its period, and its DMA turned on
    /// after that; the next voice's first write after a wave's volume; a voice with nothing to do; a sample
    /// told to go round after it is turned on, and the next voice after that; the first note of a row
    /// after the last voice's tick; a voice's note after the one before, for a wave and for a sample (and
    /// a sample's volume and period after its first write); and a voice that strikes no note.
    static let firstWrite = 300
    static let waveVolumeClocks = 80
    static let waveOnClocks = 280
    static let waveClocks = 2700
    static let quietClocks = 50
    static let roundClocks = 2093
    static let afterRoundClocks = 241
    static let rowClocks = 360
    static let waveNoteClocks = 458
    static let sampleNoteClocks = 665
    static let sampleVolumeClocks = 181
    static let samplePeriodClocks = 242
    static let noNoteClocks = 25
    /// A song that has not gone round in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60
    /// How many chunks are walked through before the walk is taken never to end; far more than any file
    /// has.
    private static let mostChunks = 1024

    /// The data's parts (`DavidHanneyData`): the three samples, each with its length in words (code
    /// $B84 to $BA6), and the instruments, of 94 bytes each.
    static let samples: [(at: Int, length: UInt16)] = [(0x000, 0x2B3), (0x566, 0x0D5), (0x710, 0x456)]
    static let instrumentsAt = 0xFC4
    static let instrumentSize = 94

    /// The replayer's table of periods (code $490, its base's $40): seventy notes, from note 3 of a row.
    static let periodTable: [UInt16] = [
        0x1AC0, 0x1940, 0x17D0, 0x1680, 0x1530, 0x1400, 0x12E0, 0x11D0, 0x10D0, 0x0FE0, 0x0F00, 0x0E20,
        0x0D60, 0x0CA0, 0x0BE8, 0x0B40, 0x0A98, 0x0A00, 0x0970, 0x08E8, 0x0868, 0x07F0, 0x0780, 0x0710,
        0x06B0, 0x0650, 0x05F4, 0x05A0, 0x054C, 0x0500, 0x04B8, 0x0474, 0x0434, 0x03F8, 0x03C0, 0x0388,
        0x0358, 0x0328, 0x02FA, 0x02D0, 0x02A6, 0x0280, 0x025C, 0x0234, 0x021A, 0x01FC, 0x01E0, 0x01C4,
        0x01AC, 0x0194, 0x017D, 0x0168, 0x0153, 0x0140, 0x012E, 0x011D, 0x010D, 0x00FE, 0x00F0, 0x00E2,
        0x00D6, 0x00CA, 0x00BE, 0x00B4, 0x00AA, 0x00A0, 0x0097, 0x008F, 0x0087, 0x007F,
    ]
    /// Its fourteen arpeggios (code $51C, its base's $CC), of twelve steps each, in notes up.
    static let arpeggios: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        6, 5, 4, 3, 2, 1, 1, 2, 3, 4, 5, 6,
        0, 4, 7, 0, 4, 7, 0, 4, 7, 0, 4, 7,
        0, 5, 9, 0, 5, 9, 0, 5, 9, 0, 5, 9,
        0, 3, 8, 0, 3, 8, 0, 3, 8, 0, 3, 8,
        12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1,
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
        0, 0, 12, 12, 0, 0, 12, 12, 0, 0, 12, 12,
        6, 5, 4, 3, 2, 1, 6, 5, 4, 3, 2, 1,
        1, 2, 3, 4, 5, 6, 1, 2, 3, 4, 5, 6,
        0, 5, 7, 0, 5, 7, 0, 5, 7, 0, 5, 7,
        0, 5, 8, 0, 5, 8, 0, 5, 8, 0, 5, 8,
        0, 4, 7, 0, 4, 7, 0, 4, 7, 0, 4, 7,
        0, 3, 7, 0, 3, 7, 0, 3, 7, 0, 3, 7,
    ]

    // MARK: - Reading

    @inline(__always) private static func byte(_ data: [UInt8], _ at: Int) -> UInt8 { at >= 0 && at < data.count ? data[at] : 0 }
    @inline(__always) private static func word(_ data: [UInt8], _ at: Int) -> UInt16 { UInt16(byte(data, at)) << 8 | UInt16(byte(data, at + 1)) }
    @inline(__always) private static func long(_ data: [UInt8], _ at: Int) -> UInt32 { UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2)) }

    /// The ids of the chunks, as longs: 'DSNG', 'SEQU', 'INFO' and 'BLK' with a block's number of nought.
    static let dsng: UInt32 = 0x4453_4E47
    static let sequ: UInt32 = 0x5345_5155
    static let infoID: UInt32 = 0x494E_464F
    static let blk: UInt32 = 0x424C_4B00

    /// Where the chunk after the one at `at` (at its id) begins: past its id, its length (a long, which
    /// may take it back) and what it holds. Nil once that is outside the file.
    private static func after(_ data: [UInt8], _ at: Int) -> Int? {
        let next = Int64(at) + 8 + Int64(Int32(bitPattern: long(data, at + 4)))
        return next >= 0 && next < Int64(data.count) ? Int(next) : nil
    }

    // MARK: - Loading

    /// True for a file the player's check takes (code $39C): 'DSNG', then 'SEQU', 'INFO', 'BLK' 0 and
    /// 'BLK' 1, each found past the one before as its length says.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 8, long(data, 0) == dsng, long(data, 4) == sequ else { return false }
        var at = 4
        for kind in [infoID, blk, blk + 1] {
            guard let next = after(data, at), long(data, next) == kind else { return false }
            at = next
        }
        return true
    }

    /// Reads the file and starts its song. A file whose sequence is empty, or names a block it does not
    /// have, is refused: the replayer would read on through what follows the file.
    init(_ data: [UInt8], song _: Int = 0) throws(TuneError) {
        module = data
        silenceAt = (DavidHanneyData.hunk.count + 15) & ~15
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        // The chunks, as `$776` walks them, from after 'DSNG' to a nought.
        var chunks: [(id: UInt32, at: Int)] = []
        var at = 4
        var end = 4
        while true {
            guard chunks.count < Self.mostChunks else {
                end = at
                break
            }
            let kind = Self.long(data, at)
            if kind == 0 {
                end = at + 4
                break
            }
            chunks.append((kind, at + 8))
            guard let next = Self.after(data, at) else {
                end = data.count
                break
            }
            at = next
        }
        self.chunks = chunks
        chunksEnd = end
        var places = [Int](repeating: -1, count: 256)
        for n in 0 ..< 256 {
            let wanted = Self.blk &+ UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: n)))
            places[n] = chunks.first { $0.id == wanted }?.at ?? -1
        }
        blockPlaces = places
        sequenceAt = chunks.first { $0.id == Self.sequ }?.at ?? end
        blockCount = chunks.count { $0.id & 0xFFFF_FF00 == Self.blk }
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a David Hanney module") }
        let info = chunks.first { $0.id == Self.infoID }?.at ?? end
        let length = Self.word(data, info)
        guard length != 0 else { throw .malformed("the module's sequence is empty") }
        for p in 0 ..< Int(length) where blockPlace(sequenceBlock(UInt16(p))) == nil {
            throw .malformed("the module's sequence names a block it does not have")
        }
        start()
        // The song's length, from a playing of it in silence to where it goes round.
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (The tick it went round in is the first of it again.)
        lengthClocks = endings > 0 ? UInt64(ticks - 1) * UInt64(Self.tickClocks) : nil
        start()
    }

    deinit { memory.deallocate() }
}

// MARK: - Playing

extension DavidHanneyPlayer {
    mutating func select(song _: Int) throws(TuneError) { start() }

    @inline(__always) private func byte(_ at: Int) -> UInt8 { Self.byte(module, at) }
    @inline(__always) private func word(_ at: Int) -> UInt16 { Self.word(module, at) }

    /// The block numbered by the sequence at `place` (`$E04`): its byte, with its sign, as the replayer
    /// takes the place's word with its sign too.
    private func sequenceBlock(_ place: UInt16) -> UInt16 {
        UInt16(bitPattern: Int16(Int8(bitPattern: byte(sequenceAt + Int(Int16(bitPattern: place))))))
    }

    /// Where block `number`'s word of rows is (`$76C`): the chunk 'BLK' and the number's low byte with its
    /// sign added to it, as a long. Nil for one the file does not have.
    private func blockPlace(_ number: UInt16) -> Int? {
        let at = blockPlaces[Int(number & 0xFF)]
        return at >= 0 ? at : nil
    }

    /// A byte of the replayer's base, as it reads it for a period or an arpeggio past their places: the
    /// table of volumes (its first 64, from nought to 63 at EaglePlayer's full volume), the periods and
    /// the arpeggios. (Past them, from $174, are its variables, which a note can be read from only far
    /// above any in the table: they are taken here as noughts.)
    private static func baseByte(_ at: Int) -> UInt8 {
        if at < 0x40 { return UInt8(at) }
        if at < 0xCC {
            let w = periodTable[(at - 0x40) >> 1]
            return UInt8(truncatingIfNeeded: at & 1 == 0 ? w >> 8 : w)
        }
        if at < 0x174 { return arpeggios[at - 0xCC] }
        return 0
    }

    /// The period of note `index` (from note 3 of a row): a word of the base from its $40.
    private static func periodOf(_ index: Int) -> UInt16 {
        let at = 0x40 + 2 * index
        return UInt16(baseByte(at)) << 8 | UInt16(baseByte(at + 1))
    }

    /// The replayer's volume for a level of 0 to 63 (`$972`, which makes the table from EaglePlayer's
    /// volume, at its fullest the level itself).
    @inline(__always) private static func volumeOf(_ level: Int) -> UInt16 { UInt16(level & 0x3F) }

    /// `InitSound` (code $3DA): the replayer's variables cleared (`$798`), the voices made ready and their
    /// volumes nought (`$846`), and the song read from its start (`$7C8`): its sequence, its first block,
    /// its speed, and the instruments put right (`$8CA`). The instruments are as the player was loaded,
    /// as UADE loads it afresh for every song.
    private mutating func start() {
        for (i, b) in DavidHanneyData.hunk.enumerated() { memory[i] = b }
        voices = .init(repeating: Voice())
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = .init(repeating: 0)
        volumesBefore = .init(repeating: 0)
        ticks = 0
        goesRound = false
        endings = 0
        stops = 0
        let info = chunks.first { $0.id == Self.infoID }?.at ?? chunksEnd
        sequenceLength = word(info)
        speed = word(info + 4)
        place = 0
        countdown = 0
        startBlock(sequenceBlock(0))
        for i in 0 ..< 16 { putRight(Self.instrumentsAt + Self.instrumentSize * i) }
        playing = true
    }

    /// `$8B0`: block `number` from its first row.
    private mutating func startBlock(_ number: UInt16) {
        blockAt = blockPlace(number) ?? chunksEnd
        lastRow = word(blockAt) &- 1
        row = 0
    }

    /// `$8CA`: an instrument of a wave with its bounds kept within it: the wave's length (72) and the
    /// vibrato's (73) no more than 16, the changing wave's lowest and highest places (70, 71) no more than
    /// 31 and in order, its place (90) between them, the envelope's levels (58 to 64) no more than 63, its
    /// count (92) no more than its speed (69), and its way (91) one way or the other.
    private mutating func putRight(_ i: Int) {
        guard memory[i] == 0, memory[i + 1] == 0 else { return }
        if memory[i + 72] >= 0x11 { memory[i + 72] = 0x10 }
        if memory[i + 73] >= 0x11 { memory[i + 73] = 0x10 }
        if memory[i + 70] >= 0x20 { memory[i + 70] = 0x1F }
        if memory[i + 71] >= 0x20 { memory[i + 71] = 0x1F }
        for k in 0 ..< 4 where memory[i + 58 + 2 * k] >= 0x40 { memory[i + 58 + 2 * k] = 0x3F }
        if memory[i + 70] > memory[i + 71] {
            let low = memory[i + 71]
            memory[i + 71] = memory[i + 70]
            memory[i + 70] = low
        }
        if memory[i + 90] < memory[i + 70] || memory[i + 90] > memory[i + 71] { memory[i + 90] = memory[i + 70] }
        if memory[i + 92] > memory[i + 69] { memory[i + 92] = 0 }
        if memory[i + 91] != 0xFF, memory[i + 91] != 1 { memory[i + 91] = 1 }
    }

    /// The player's interrupt (code $41E, the replayer's `$990`), for a tick: each voice's note moved on
    /// (`$C12`), and every speed + 1 ticks the row read and its notes struck, and at the block's end the
    /// next block of the sequence begun, at the sequence's end its first again. Returns the tick's
    /// length in milliseconds (unused).
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        volumesBefore = volumes
        guard playing else { return 20 }
        ticks &+= 1
        var at = Self.firstWrite
        for v in 0 ..< 4 { moveOn(v, &at, &output) }
        let was = countdown
        countdown &-= 1
        guard was == 0 else { return 20 }
        countdown = speed
        if goesRound {
            goesRound = false
            endings += 1
        }
        let notes = blockAt + 2 + 12 * Int(row)
        for v in 0 ..< 4 {
            voices[v].note = byte(notes + 3 * v)
            voices[v].instrumentNumber = byte(notes + 3 * v + 1)
            voices[v].effect = byte(notes + 3 * v + 2)
        }
        at += Self.rowClocks
        for v in 0 ..< 4 { strike(v, &at, &output) }
        if row < lastRow {
            row &+= 1
        } else {
            var next = place &+ 1
            if next == sequenceLength {
                // (`ENPP_SongEnd`, at code $A5C: the song goes round, from the row after this one.)
                goesRound = true
                next = 0
            }
            place = next
            startBlock(sequenceBlock(place))
        }
        return 20
    }

    /// `$C12`: what the voice's state asks of the tick (a sample turned on, or a wave played), and once
    /// its ticks before it are over, its note struck again.
    private mutating func moveOn<Output: TFMXOutput>(_ v: Int, _ at: inout Int, _ output: inout Output) {
        switch voices[v].state {
        case 4:
            // `$C44`: the sample turned on, and told to go on round its first word.
            output.timed(at: at)
            output.on(v)
            at += Self.roundClocks
            output.timed(at: at)
            output.takeNextBuffer(v, start: voices[v].location, length: 1)
            at += Self.afterRoundClocks
            voices[v].state = 0
        case 8:
            playWave(v, &at, &output)
        default:
            at += Self.quietClocks
        }
        if voices[v].again != 0 {
            voices[v].again &-= 1
            if voices[v].again == 0 {
                voices[v].effect = 0
                strike(v, &at, &output)
            }
        }
    }

    /// `$A78`: the row's note for the voice, with its effect: for a slide, only where it slides to; for
    /// any other, a note struck (a wave or a sample), the voice stopped (1), or its note let die away (2).
    private mutating func strike<Output: TFMXOutput>(_ v: Int, _ at: inout Int, _ output: inout Output) {
        var voice = voices[v]
        guard voice.note | voice.instrumentNumber | voice.effect != 0 else {
            at += Self.noNoteClocks
            return
        }
        output.timed(at: at)
        voice.slide = 0
        let low = voice.effect & 15
        switch voice.effect >> 4 {
        case 1:
            // (The period slid to is the note's own from the table, not from note 3 as a struck note's.)
            voice.slide = UInt16(low) + 1
            voice.target = Self.periodOf(Int(voice.note))
            voices[v] = voice
            at += Self.noNoteClocks
            return
        case 2:
            voice.envelopeSpeed = low
        case 3:
            for i in 0 ..< 12 { voice.arpeggio[i] = Self.baseByte(0xCC + 12 * Int(low) + i) }
        case 4:
            voice.again = UInt8(truncatingIfNeeded: (speed &+ 1) >> 1)
        default:
            break
        }
        switch voice.note {
        case 0:
            at += Self.noNoteClocks
        case 1:
            // `$BEE`: the voice turned off.
            output.off(v)
            voice.state = 0
            at += Self.noNoteClocks
        case 2:
            // `$C06`: the envelope's last step, at once. (The replayer writes these two to where its A0
            // points, not its voice's A2: that is, to whatever it last pointed A0 at, a wave or a sample
            // or its own code. None of the game's music has the note, and the voice is meant here.)
            voice.envelopeCount = 0
            voice.envelopeStep = 6
            at += Self.noNoteClocks
        default:
            let index = UInt16(voice.note) - 2
            voice.baseNote = index
            voice.period = Self.periodOf(Int(index))
            // (An instrument past the sixteen reads the replayer's code as where it is: taken here as none,
            // which stops the voice, as an instrument of nought does.)
            guard voice.instrumentNumber < 16 else {
                output.off(v)
                voice.state = 0
                at += Self.noNoteClocks
                break
            }
            let i = Self.instrumentsAt + Self.instrumentSize * Int(voice.instrumentNumber)
            voice.instrument = i
            let type = UInt16(memory[i]) << 8 | UInt16(memory[i + 1])
            output.off(v)
            if type == 0 {
                voice.vibratoDelay = memory[i + 67]
                voice.vibratoPlace = 0
                voice.level = 0
                voice.envelopeStep = 0
                voice.envelopeCount = 0
                voice.location = i + 10
                output.takeNextBuffer(v, start: voice.location, length: UInt16(memory[i + 72]))
                voice.state = 8
                at += Self.waveNoteClocks
            } else {
                let sample = Self.samples[Int(min(type, 3)) - 1]
                voice.location = sample.at
                output.takeNextBuffer(v, start: sample.at, length: sample.length)
                volumes[v] = Self.volumeOf(63)
                output.timed(at: at + Self.sampleVolumeClocks)
                output.writeVolume(v, volumes[v])
                periods[v] = voice.period
                output.timed(at: at + Self.samplePeriodClocks)
                output.writePeriod(v, periods[v])
                voice.state = 4
                at += Self.sampleNoteClocks
            }
        }
        voices[v] = voice
    }

    /// `$C70`: a tick of a wave's note: its period, slid towards the note slid to, or else from its
    /// arpeggio, and bent by the instrument's vibrato once it has begun; its volume, from its envelope;
    /// the instrument's wave changed by a byte (once a tick, whichever voices play it); and the voice
    /// turned on.
    private mutating func playWave<Output: TFMXOutput>(_ v: Int, _ at: inout Int, _ output: inout Output) {
        var voice = voices[v]
        let i = voice.instrument
        var period: UInt16
        if voice.slide != 0 {
            period = voice.period
            if period != voice.target {
                // (A slide sets the envelope back to its first step, at every tick of it.)
                voice.envelopeStep = 0
                if period < voice.target {
                    period = voice.slide >= voice.target - period ? voice.target : period + voice.slide
                } else {
                    period = voice.slide >= period - voice.target ? voice.target : period - voice.slide
                }
                voice.period = period
            }
        } else {
            // (The arpeggio's notes are added to the note's low byte.)
            let note = voice.baseNote & 0xFF00 | (voice.baseNote &+ UInt16(voice.arpeggio[Int(voice.arpeggioPlace)])) & 0xFF
            period = Self.periodOf(Int(note & 0x7FFF))
            voice.arpeggioPlace += 1
            if voice.arpeggioPlace >= 12 { voice.arpeggioPlace = 0 }
        }
        let vibratoSpeed = memory[i + 66]
        if vibratoSpeed != 0 {
            if voice.vibratoDelay != 0 {
                voice.vibratoDelay &-= 1
            } else {
                let bend = Int(Int8(bitPattern: memory[i + 42 + Int(voice.vibratoPlace)])) * Int(memory[i + 68])
                period = period &+ UInt16(truncatingIfNeeded: bend)
                let was = voice.vibratoPlace
                voice.vibratoPlace &-= vibratoSpeed
                if was < vibratoSpeed { voice.vibratoPlace &+= memory[i + 73] &* 2 }
            }
        }
        periods[v] = period
        output.timed(at: at)
        output.writePeriod(v, period)
        // `$D0E`: every envelope speed + 1 ticks, the level moved by its step's speed towards its step's
        // level, and once there, on to the next step (after the last, held).
        let count = voice.envelopeCount
        voice.envelopeCount &-= 1
        if count == 0 {
            voice.envelopeCount = voice.envelopeSpeed
            let step = Int(voice.envelopeStep)
            let goal = memory[i + 58 + step] &* 4
            let by = memory[i + 59 + step]
            let level = UInt8(truncatingIfNeeded: voice.level)
            let moved: UInt8
            if level < goal {
                moved = by >= goal - level ? goal : level + by
            } else {
                moved = by > level - goal ? goal : level - by
            }
            if moved == goal, step != 6 { voice.envelopeStep += 2 }
            voice.level = voice.level & 0xFF00 | UInt16(moved)
        }
        volumes[v] = Self.volumeOf(Int(voice.level >> 2))
        output.timed(at: at + Self.waveVolumeClocks)
        output.writeVolume(v, volumes[v])
        // `$D70`: the wave's byte at its place made its highest or lowest, every speed of its ticks, and
        // its place moved on, turning at its bounds.
        let waveSpeed = memory[i + 69]
        if waveSpeed != 0, ticks != memory[i + 93] {
            memory[i + 93] = ticks
            let count = memory[i + 92]
            memory[i + 92] = count &- 1
            if count == 0 {
                memory[i + 92] = waveSpeed &- 1
                let at = memory[i + 90]
                if memory[i + 91] & 0x80 != 0 {
                    memory[i + 10 + Int(at)] = 0x3F
                    if at == memory[i + 70] {
                        memory[i + 91] = 0 &- memory[i + 91]
                    } else {
                        memory[i + 90] = at &- 1
                    }
                } else {
                    memory[i + 10 + Int(at)] = 0xC0
                    if at == memory[i + 71] {
                        memory[i + 91] = 0 &- memory[i + 91]
                    } else {
                        memory[i + 90] = at &+ 1
                    }
                }
            }
        }
        output.timed(at: at + Self.waveVolumeClocks + Self.waveOnClocks)
        output.on(v)
        at += Self.waveVolumeClocks + Self.waveClocks
        voices[v] = voice
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

/// David Hanney's music, played on Paula by `PaulaTickRenderer`.
extension DavidHanneyPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "David Hanney")
        let plural = blockCount == 1 ? "" : "s"
        info.detail = "David Hanney's music for Tearaway Thomas, the game's own replayer and instruments; \(blockCount) block\(plural)"
        return info
    }

    /// (Its music turned to the loudness of the rest: at 0.46 the middle of its files is -16.8 dB.)
    var gain: Float { 0.20 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
