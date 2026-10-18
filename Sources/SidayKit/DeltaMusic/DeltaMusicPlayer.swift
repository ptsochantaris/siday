// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the 68000 code of Bent Nielsen's Delta Music 2.0 replayer (1990), which every module
// carries at its beginning, as Eagleeye's EaglePlayer module of it ("Deltamusic V2.0 player module
// V1.2 (10 May 93)", carried by UADE as `DeltaMusic2.0`) runs it. The addresses given are offsets into
// the module, where that code is.

/// Delta Music 2.0, Bent Nielsen's tracker of 1990 (in UnExoticA's collection, the music of Nebulus 2).
/// A module is its own player: the replayer's code, and after it the song. Each of the four voices has
/// a track of its own, a list of blocks of sixteen rows (with a transpose for each), which goes round
/// from a place of its own when it comes to its end; a row has a note, an instrument and a command.
/// An instrument is a sample, or a synth: a list of the module's waveforms of 256 bytes, which Paula is
/// told to play one after another at the instrument's own pace; each has an envelope of its volume, a
/// vibrato in steps, a pitch bend, and the arpeggio and portamento its rows give it.
///
/// This is that code, as it tells Paula what to do, tick by tick: what it tells her is what UADE's
/// running of it tells her for the modules of UnExoticA's collection. It owns the memory Paula plays
/// from, which is the module, as the replayer has it, and room after it. The replayer writes into it as
/// it plays: on every tick sixty-four bytes of noise over the first waveform, and a word of nought at
/// the beginning of a sample whose loop it starts; both are done here, in this memory, for Paula to
/// play what she would.
///
/// For a note, the replayer turns the voice's DMA off, and on again at the end of the tick, with no
/// wait between: Paula stops a voice only at the end of a word, so a low note may go on from where the
/// last left off rather than start afresh (in UADE's playing of the collection, about one note in
/// thirty, mostly low ones; in Hardy Hitech, a third of the second voice's). Here, as
/// `PaulaTickRenderer` plays any player, every note starts afresh.
///
/// The replayer reads what follows its tables and the module where a module takes it there (an
/// instrument of nought, a note beyond its table); that is read here from the module and the room
/// after it, as the module is laid out in its file, which is where it is in the Amiga's memory.
struct DeltaMusicPlayer: ~Copyable {
    /// The module and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    /// How many bytes of `memory` are the module's.
    let size: Int
    /// Where Paula starts a voice that has not been told where to: the room after the module.
    var silenceAt: Int { size }
    /// Room after the module, as for any player of `PaulaTickRenderer`'s, for no mixing: far enough
    /// after the module that a sample told a length, however long, reads only silence.
    var mixingAt: Int { size + 0x20000 }
    static let mixingSpace = 2048
    /// How many bytes Paula may read of `memory`.
    let memoryCapacity: Int
    /// The module as it is in its file, for the replayer's writes to be undone when the song starts again.
    private let original: [UInt8]

    /// Where the replayer's code ends and its variables begin ($B8C), and where the song begins ($BCA:
    /// its 64 arpeggios, then the rest, from $FCA).
    static let variablesAt = 0xB8C
    static let arpeggiosAt = 0xBCA
    static let songAt = 0xFCA
    /// The replayer's table of periods ($AE2), of 85 notes, the first of them none.
    static let periodsAt = 0xAE2
    /// Where each voice's variables are in the module ($878, $8B4, $904, $954).
    private static let voicesAt = [0x878, 0x8B4, 0x904, 0x954]

    /// The parts of the song, as the replayer's setting up ($1FC) finds them: the instruments' data
    /// (its variable 2) and their table of offsets into it (6), the blocks (26), the waveforms (30),
    /// the samples (34) and their table of offsets into them (38).
    private let instrumentData: Int
    private let instrumentTable: Int
    private let blocks: Int
    private let waveforms: Int
    private let samples: Int
    private let sampleTable: Int
    /// Each voice's track (10), where it goes round from and where it ends, in bytes (the header's
    /// words, copied to $3AC).
    private let tracks: InlineArray<4, Int>
    private let trackLoops: InlineArray<4, UInt16>
    private let trackEnds: InlineArray<4, UInt16>

    /// One voice, as the replayer keeps it (60 bytes and more each, at $878 and on), named by what
    /// each of its variables is; the numbers are their offsets.
    struct Voice {
        /// Its instrument (6), a place in memory.
        var instrument = 0
        /// The block being played (14) and where in it, in bytes (20); where in the track (18).
        var block = 0
        var row: UInt16 = 0
        var trackAt: UInt16 = 0
        /// The pace of a synth's waveforms: ticks left until the next (22), and which is next (23).
        var waveDelay: UInt8 = 0
        var waveAt: UInt8 = 0
        /// The period a portamento has come to (24), and the note's, which it goes to (26).
        var portamento: UInt16 = 0
        var target: UInt16 = 0
        /// The note (28), and the most volume its rows let it have (29).
        var note: UInt8 = 0
        var maximum: UInt8 = 0x3F
        /// The pitch bend its rows give it, taken from the instrument's own (30).
        var bend: UInt16 = 0
        /// The volume's envelope: the volume, in quarters (32), where in the envelope (34), and ticks
        /// held (36).
        var volume: UInt16 = 0
        var envelopeAt: UInt16 = 0
        var sustain: UInt8 = 0
        /// The portamento's speed (37); nought for none.
        var portamentoSpeed: UInt8 = 0
        /// Two bytes the replayer clears and does not use (38) and the vibrato's way, up or down (39).
        var unused: UInt8 = 0
        var vibratoDown: UInt8 = 0
        /// What the vibrato and the bend have added to the period (40), and ticks left before the
        /// vibrato turns (42).
        var vibrato: UInt16 = 0
        var vibratoCount: UInt8 = 0
        /// The block's transpose of its notes (43).
        var transpose: UInt8 = 0
        /// The arpeggio, a place in memory (44), and where in it (48).
        var arpeggio = DeltaMusicPlayer.arpeggiosAt
        var arpeggioAt: UInt16 = 0
        /// True while the next tick is to start a sample's loop (51, the instrument's mark of a sample).
        var sampleMark: UInt8 = 0
        /// Which of the vibrato's five steps (52), and the ticks before the next (53).
        var vibratoAt: UInt8 = 0
        var vibratoDelay: UInt8 = 0
    }

    private(set) var voices = InlineArray<4, Voice>(repeating: Voice())
    /// What each of Paula's voices was last told: where to play from, how many words, the period and
    /// the volume.
    private var paulaStarts = InlineArray<4, Int>(repeating: 0)
    private var paulaLengths = InlineArray<4, UInt16>(repeating: 1)
    private var paulaPeriods = InlineArray<4, UInt16>(repeating: 0)
    private var paulaVolumes = InlineArray<4, UInt16>(repeating: 0)

    /// The replayer's own variables (at $B8C): the word it turns on Paula's voices with (0), the noise's
    /// seed (42), the volume over all (46), the speed (47), the ticks left until the next row (48).
    private let dmaWord: UInt16
    private var seed: UInt32 = 0
    private var masterVolume: UInt8 = 0x3F
    private var speed: UInt8 = 5
    private var counter: UInt8 = 1
    /// The filter the power light shows, as the module's commands last set it (`PaulaTickRenderer`
    /// does not play it).
    private(set) var lightFilter = false
    /// True once the song has turned the filter on, in its playing through for its length.
    private(set) var turnsFilterOn = false

    /// True from when the first voice's track has gone round, as it begins its last block, until it
    /// begins again where it goes round to, when the end is counted.
    private var ending = false
    private(set) var endings = 0
    /// The song's length, in ticks, as it is played through before it begins; nil for one that does
    /// not come round in 59 minutes.
    private(set) var lengthTicks: Int?

    /// True for a file the EaglePlayer module takes for one of Delta Music 2.0's (its check, at $15E of
    /// that module's code): ".FNL" at $BC6.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 0xBCA && data[0xBC6] == 0x2E && data[0xBC7] == 0x46 && data[0xBC8] == 0x4E && data[0xBC9] == 0x4C
    }

    /// The replayer's code, as every module of UnExoticA's has it (but for the places it keeps
    /// addresses in), with its word for turning on Paula's voices and its table of periods: FNV-1a of
    /// $0-$3AB, $3BC-$877 and $AE2-$B8D. A module with another is not played as its own code would play
    /// it, and is refused.
    static let replayerSum: UInt32 = 0xD115_4EDA

    static func replayerSum(of data: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0x811C_9DC5
        for range in [0 ..< 0x3AC, 0x3BC ..< 0x878, 0xAE2 ..< 0xB8E] {
            for i in range {
                sum ^= UInt32(data[i])
                sum = sum &* 0x0100_0193
            }
        }
        return sum
    }

    /// Reads the module, as the replayer's setting up does ($1FC), and starts its song (it has one:
    /// `song` is not looked at). (`checksReplayer` is for tests, whose modules have no replayer.)
    init(_ data: [UInt8], song _: Int = 0, checksReplayer: Bool = true) throws(TuneError) {
        size = data.count
        original = data
        memoryCapacity = data.count + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        func word(_ at: Int) -> Int { at >= 0 && at + 2 <= data.count ? Int(data[at]) << 8 | Int(data[at + 1]) : 0 }
        func long(_ at: Int) -> Int { word(at) << 16 | word(at + 2) }
        let header = Self.songAt
        var at = header + 16
        var tracks = InlineArray<4, Int>(repeating: 0)
        var loops = InlineArray<4, UInt16>(repeating: 0)
        var ends = InlineArray<4, UInt16>(repeating: 0)
        for v in 0 ..< 4 {
            tracks[v] = at
            loops[v] = UInt16(word(header + 4 * v))
            ends[v] = UInt16(word(header + 4 * v + 2))
            at += Int(ends[v])
        }
        self.tracks = tracks
        trackLoops = loops
        trackEnds = ends
        let blockBytes = long(at)
        blocks = at + 4
        at = blocks + blockBytes
        instrumentTable = at
        at += 0xFE
        instrumentData = at + 2
        at = instrumentData + word(at)
        let waveBytes = long(at)
        waveforms = at + 4
        at = waveforms + waveBytes
        sampleTable = at + 0x40
        samples = at + 0x60
        let isOne = Self.isOne(data) && data.count >= header + 16
        dmaWord = isOne ? UInt16(word(Self.variablesAt)) : 0
        lengthTicks = nil
        guard isOne else { throw .unsupported("not a Delta Music 2.0 module") }
        guard !checksReplayer || Self.replayerSum(of: data) == Self.replayerSum else {
            throw .unsupported("a Delta Music 2.0 module whose replayer is not Bent Nielsen's of the modules known")
        }
        guard samples <= data.count else { throw .malformed("Delta Music 2.0 module cut short") }
        lengthTicks = playThrough()
        start()
    }

    deinit { memory.deallocate() }

    /// The song from its beginning, as the replayer's setting up has it ($1FC, $36C), with the module
    /// as it is in its file.
    mutating func start() {
        for (i, b) in original.enumerated() { memory[i] = b }
        for v in 0 ..< 4 {
            // What the setting up does not set is as the module has it.
            let at = Self.voicesAt[v]
            var voice = Voice()
            voice.waveDelay = byte(at + 22)
            voice.waveAt = byte(at + 23)
            voice.portamento = word(at + 24)
            voice.target = word(at + 26)
            voice.note = byte(at + 28)
            voice.unused = byte(at + 38)
            voice.vibratoDown = byte(at + 39)
            voice.vibrato = word(at + 40)
            voice.vibratoCount = byte(at + 42)
            voice.transpose = byte(at + 43)
            voice.vibratoAt = byte(at + 52)
            voice.vibratoDelay = byte(at + 53)
            voice.instrument = instrumentData
            voices[v] = voice
        }
        paulaStarts = InlineArray(repeating: silenceAt)
        paulaLengths = InlineArray(repeating: 1)
        paulaPeriods = InlineArray(repeating: 0)
        paulaVolumes = InlineArray(repeating: 0)
        seed = UInt32(long(Self.variablesAt + 42))
        // (EaglePlayer's module sets the volume over all, 46, to 63 as it starts the song, at $16E.)
        masterVolume = 63
        speed = byte(Self.variablesAt + 47)
        counter = 1
        lightFilter = false
        ending = false
        endings = 0
    }

    /// The song is played through, without a sound, for its length; and started again.
    private mutating func playThrough() -> Int? {
        start()
        var none = Unheard()
        var ticks = 0
        while ticks < Self.longest {
            run(&none)
            if lightFilter { turnsFilterOn = true }
            if endings > 0 { return ticks }
            ticks += 1
        }
        return nil
    }

    /// The most ticks a song is played through for: 59 minutes.
    static let longest = Int(UInt64(59 * 60) * 3_546_895 / UInt64(tickClocks))

    /// How long a tick is, in Paula's clocks: EaglePlayer's module has no timer of its own, and UADE
    /// runs it from a CIA's, of $376B, which comes round every 14,188 of its clocks, each five of
    /// Paula's. (Measured in UADE's dumps of Paula's registers: 70,940 between ticks.)
    static let tickClocks = 14188 * 5

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < memoryCapacity ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at + 1)) }
    @inline(__always) private func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }

    /// A write of the replayer's into the module; none outside it is done, which would be into the
    /// silence after it (and which none of UnExoticA's modules makes).
    @inline(__always) private func store(_ value: UInt8, at: Int) {
        if at >= 0, at < size { memory[at] = value }
    }

    /// The period of note `n` from the replayer's table ($AE2). A note beyond its 85 reads on into its
    /// variables, as they are in the module's file, and its arpeggios.
    private func period(_ n: UInt8) -> UInt16 { word(Self.periodsAt + Int(n) * 2) }

    /// Where a sample is: the samples, and the instrument's sample's offset into them (of eight).
    private func sample(of instrument: Int) -> Int {
        samples + Int(long(sampleTable + Int(byte(instrument + 39) & 7) * 4))
    }

    /// Paula is told where to play from or how long, and both are said, as she then has them.
    private mutating func tell<Output: TFMXOutput>(_ v: Int, start: Int? = nil, length: UInt16? = nil, _ output: inout Output) {
        if let start { paulaStarts[v] = start }
        if let length { paulaLengths[v] = length }
        output.takeNextBuffer(v, start: paulaStarts[v], length: paulaLengths[v])
    }

    /// Runs the replayer for one tick ($3BC), telling `output` what Paula is to do. Returns the tick's
    /// length in Paula's clocks.
    @discardableResult
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        // Sixty-four bytes of noise over the first waveform.
        var d1 = seed
        for i in 0 ..< 16 {
            d1 = (d1 << 7 | d1 >> 25) &+ 0x6ECA_756D
            d1 ^= 0x9E59_A92B
            for b in 0 ..< 4 { store(UInt8(truncatingIfNeeded: d1 >> (24 - 8 * UInt32(b))), at: waveforms + 4 * i + b) }
        }
        seed = d1
        counter &-= 1
        if counter & 0x80 != 0 { counter = speed }
        var dma: UInt16 = 0
        for v in 0 ..< 4 { play(v, dma: &dma, &output) }
        // (Its four voices for sounds of a game's, which a song does not play, are left out; and the
        // song's are all to be heard.) Paula's DMA is turned on as the replayer's word says, for the
        // voices that were told their volume.
        let word = dmaWord | dma
        for v in 0 ..< 4 where word & 0x8000 != 0 && word & 1 << v != 0 { output.on(v) }
        if word & 0x8000 == 0 { for v in 0 ..< 4 where word & 1 << v != 0 { output.off(v) } }
        return Self.tickClocks
    }

    /// A voice's tick ($49E).
    private mutating func play<Output: TFMXOutput>(_ v: Int, dma: inout UInt16, _ output: inout Output) {
        var instrument = voices[v].instrument
        if voices[v].sampleMark & 0x80 != 0 {
            // The tick after a sample is started, its loop: its first word is made nought, and Paula
            // is told the loop's length and where it is.
            voices[v].sampleMark = 0
            let at = sample(of: instrument)
            tell(v, length: word(instrument + 4), &output)
            store(0, at: at)
            store(0, at: at + 1)
            tell(v, start: at + Int(word(instrument + 2)), &output)
        }
        if counter == 0 { instrument = playRow(v, &output) }

        // A synth's waveforms, one after another at its pace ($612): $FF in its list goes on from where
        // the byte after it says, and a second $FF there leaves the voice where it was.
        if byte(instrument + 38) & 0x80 == 0 {
            if voices[v].waveDelay != 0 {
                voices[v].waveDelay &-= 1
            } else {
                voices[v].waveDelay = byte(instrument + 39)
                let list = instrument + 40
                var at = Int(voices[v].waveAt)
                var wave = byte(list + at)
                if wave == 0xFF {
                    at = Int(byte(list + at + 1))
                    wave = byte(list + at)
                }
                if wave != 0xFF {
                    tell(v, start: waveforms + Int(wave) << 8, length: word(instrument), &output)
                    voices[v].waveAt = UInt8(truncatingIfNeeded: at + 1) & 0x3F
                }
            }
        }

        // The vibrato ($672): five steps of three bytes from the instrument's 21st, its speed, the ticks
        // before it turns, and how long the step after it lasts. (From its last step it goes back to
        // the last, and reads that one's length from the byte after the steps.)
        let step = instrument + 21 + Int(voices[v].vibratoAt)
        let speed = UInt16(byte(step))
        if voices[v].vibratoDown == 0 { voices[v].vibrato &+= speed } else { voices[v].vibrato &-= speed }
        voices[v].vibratoCount &-= 1
        if voices[v].vibratoCount == 0 {
            voices[v].vibratoCount = byte(step + 1)
            voices[v].vibratoDown = ~voices[v].vibratoDown
        }
        if voices[v].vibratoDelay != 0 {
            voices[v].vibratoDelay &-= 1
        } else {
            voices[v].vibratoAt &+= 3
            if voices[v].vibratoAt == 15 { voices[v].vibratoAt = 12 }
            voices[v].vibratoDelay = byte(step + 5)
        }

        // The envelope ($6C6): five steps of three bytes from the instrument's sixth, the speed, the
        // volume it goes to, and the ticks it is held there. From its last it goes back to the last as
        // it goes up, and on into what follows as it comes down.
        if voices[v].sustain != 0 {
            voices[v].sustain &-= 1
        } else {
            let at = instrument + 6 + Int(voices[v].envelopeAt)
            let speed = UInt16(byte(at)), level = UInt16(byte(at + 1))
            if Int16(bitPattern: level &- voices[v].volume) >= 0 {
                voices[v].volume &+= speed
                if Int16(bitPattern: level &- voices[v].volume) < 0 {
                    voices[v].volume = level
                    voices[v].envelopeAt &+= 3
                    if voices[v].envelopeAt == 15 { voices[v].envelopeAt = 12 }
                    voices[v].sustain = byte(at + 2)
                }
            } else {
                voices[v].volume &-= speed
                if Int16(bitPattern: level &- voices[v].volume) >= 0 {
                    voices[v].volume = level
                    voices[v].envelopeAt &+= 3
                    voices[v].sustain = byte(at + 2)
                }
            }
        }

        // The portamento ($72C), to the note's period.
        let glide = UInt16(voices[v].portamentoSpeed)
        if glide != 0 {
            let target = voices[v].target
            if Int16(bitPattern: target &- voices[v].portamento) >= 0 {
                voices[v].portamento &+= glide
                if Int16(bitPattern: target &- voices[v].portamento) < 0 { voices[v].portamento = target }
            } else {
                voices[v].portamento &-= glide
                if Int16(bitPattern: target &- voices[v].portamento) >= 0 { voices[v].portamento = target }
            }
        }

        // The arpeggio ($75C), sixteen notes added to the note in turn, $80 after the first going back
        // to it; and the period, from the note or the portamento, with the vibrato and the bend.
        var added = byte(voices[v].arpeggio + Int(voices[v].arpeggioAt))
        if voices[v].arpeggioAt & 0xFF != 0, added == 0x80 {
            voices[v].arpeggioAt = 0
            added = byte(voices[v].arpeggio)
        }
        voices[v].arpeggioAt = (voices[v].arpeggioAt &+ 1) & 0xF
        var period: UInt16
        if glide != 0 {
            period = voices[v].portamento
        } else {
            period = self.period(added &+ voices[v].note &+ voices[v].transpose)
            voices[v].portamento = period
        }
        voices[v].vibrato &-= word(instrument + 36) &- voices[v].bend
        period &+= voices[v].vibrato
        paulaPeriods[v] = period

        // The volume ($7C0): the envelope's, no more than the voice's most and the song's.
        var volume = UInt8((voices[v].volume >> 2) & 0x3F)
        if Int8(bitPattern: volume &- voices[v].maximum) >= 0 { volume = voices[v].maximum }
        if Int8(bitPattern: volume &- masterVolume) >= 0 { volume = masterVolume }
        // (As EaglePlayer's module writes it, at $396: of seven bits, at its full volume.)
        paulaVolumes[v] = UInt16(volume & 0x7F)
        dma |= UInt16(1) << v
    }

    /// A voice's row ($4F8), on a tick the speed gives one: at the beginning of a block, the next of
    /// its track; then the row's note, which starts its instrument afresh, Paula's DMA being turned off
    /// for it; and its command. Returns the voice's instrument.
    private mutating func playRow<Output: TFMXOutput>(_ v: Int, _ output: inout Output) -> Int {
        if voices[v].row == 0 {
            let at = tracks[v] + Int(Int16(bitPattern: voices[v].trackAt))
            if v == 0, ending {
                ending = false
                endings += 1
            }
            voices[v].block = blocks + Int(byte(at)) << 6
            voices[v].transpose = byte(at + 1)
            voices[v].trackAt &+= 2
            if Int16(bitPattern: voices[v].trackAt &- trackEnds[v]) >= 0 {
                // The track goes round: EaglePlayer's module says that the song has ended ($380).
                voices[v].trackAt = trackLoops[v]
                if v == 0 { ending = true }
            }
        }
        let at = voices[v].block + Int(voices[v].row)
        let note = byte(at)
        var instrument = voices[v].instrument
        if note != 0 {
            output.off(v)
            voices[v].note = note
            voices[v].target = period(note &+ voices[v].transpose)
            // The instrument's offset, from the table: instrument n's is its (n - 1)th, and that of
            // nought, the word subtracted from in a long, is 65,534 bytes on.
            let index = Int(byte(at + 1)) * 2
            let entry = index == 0 ? 0xFFFE : index - 2
            instrument = instrumentData + Int(word(instrumentTable + entry))
            voices[v].instrument = instrument
            voices[v].sampleMark = byte(instrument + 38)
            if voices[v].sampleMark & 0x80 != 0 {
                tell(v, start: sample(of: instrument), length: word(instrument), &output)
            }
            voices[v].waveDelay = 0
            voices[v].waveAt = 0
            voices[v].volume = 0
            voices[v].sustain = 0
            voices[v].envelopeAt = 0
            voices[v].arpeggioAt = 0
            voices[v].unused = 0
            voices[v].vibratoDown = 0
            voices[v].vibrato = 0
            voices[v].vibratoCount = byte(instrument + 22)
            voices[v].vibratoAt = 0
            voices[v].vibratoDelay = byte(instrument + 23)
        }
        // The command ($5E6), of eight: those past them are taken as one of them, by their low bits,
        // and nought and those of $81 and above are none.
        let command = byte(at + 2) &- 1
        if command & 0x80 == 0 {
            let parameter = byte(at + 3)
            switch command & 7 {
            case 0: speed = parameter & 0xF
            case 1: lightFilter = parameter != 0
            case 2: voices[v].bend = 0 &- UInt16(parameter)
            case 3: voices[v].bend = UInt16(parameter)
            case 4: voices[v].portamentoSpeed = parameter
            case 5: voices[v].maximum = parameter & 0x3F
            case 6: masterVolume = parameter & 0x3F
            default: voices[v].arpeggio = Self.arpeggiosAt + Int(parameter & 0x3F) << 4
            }
        }
        voices[v].row = (voices[v].row &+ 4) & 0x3F
        return instrument
    }

    /// One song.
    var songCount: Int { 1 }
    var song: Int { 0 }
    var stops: Int { 0 }
    func period(_ voice: Int) -> UInt16 { paulaPeriods[voice] }
    func volume(_ voice: Int) -> UInt16 { paulaVolumes[voice] }
}

/// Paula told nothing, for playing a song through for its length.
private struct Unheard: TFMXOutput {
    mutating func on(_: Int) {}
    mutating func off(_: Int) {}
    mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
    func loopCount(_: Int) -> UInt16 { 0 }
}

/// Delta Music 2.0's modules, played on Paula by `PaulaTickRenderer`.
extension DeltaMusicPlayer: PaulaTickPlayer {
    var lengthClocks: UInt64? { lengthTicks.map { UInt64($0) * UInt64(Self.tickClocks) } }
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "DM2")
        info.detail = "Delta Music 2.0"
        if turnsFilterOn {
            info.shortfalls = ["Its commands to turn the Amiga's filter on are not played: it is heard with the filter off."]
        }
        return info
    }

    var gain: Float { 0.46 }

    mutating func select(song _: Int) throws(TuneError) { start() }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
