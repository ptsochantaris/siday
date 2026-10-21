// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the 68000 code of ASREPLAY, The Synchron Assembly's replay routine for Audio Sculpture's
// modules and Startrekker's, as UADE carries it in its AudioSculpture player ("AudioSculpture/
// Startrekker4AM player V0.1.1 (Jul. 2004)", adapted for UADE by mld and shd, whose source UADE also
// carries as amigasrc/players/uade/adsc/AudioSculpture.asm). The labels given are that source's.

/// Startrekker's synthesised instruments, which it kept in a file of their own beside the module
/// (its ".nt"; Audio Sculpture, which came after it and reads its modules, called its own ".as"),
/// leaving their samples empty in the module. The file begins "ST1.2 ModuleINFO", "ST1.3 ModuleINFO"
/// or "AudioSculpture10", and from its 144th byte has a record of 120 bytes for each of the 31
/// samples, of which those marked "AM" are synthesised: a waveform of 32 bytes, one of four, played
/// over and over, with a level that rises and falls through five stages, a pitch that slides, and a
/// vibrato of its own. (After the records Audio Sculpture kept 68000 code for its command E to run,
/// which no tune in the collection uses, and which is not run here: the command is left out of
/// Startrekker's modules as they are read.)
///
/// They are played as ASREPLAY plays them, which is how UADE plays a module of Startrekker's that
/// has them. (OpenMPT reads them too, into an envelope, an automatic vibrato and a pitch envelope of
/// its own: near, but not the same.)
struct StartrekkerSynth {
    /// One record. The levels go from nothing to 255 or so; each speed is how much the level moves on
    /// each tick until it comes to the stage's level.
    struct Instrument {
        var startLevel: Int16 = 0
        var attackLevel: Int16 = 0, attackSpeed: Int16 = 0
        var secondAttackLevel: Int16 = 0, secondAttackSpeed: Int16 = 0
        var sustainLevel: Int16 = 0, decaySpeed: Int16 = 0
        /// In ticks, the time it is held at the sustain level, less one.
        var sustainTime: Int16 = 0
        var releaseSpeed: Int16 = 0
        /// Sine, sawtooth, square or noise.
        var waveform: Int = 0
        /// Added to the period on every tick.
        var pitchFall: Int16 = 0
        var vibratoDepth: Int16 = 0, vibratoSpeed: Int16 = 0
        /// How many octaves below the note it sounds.
        var octave: UInt16 = 0
    }

    /// The records, one for each of the module's samples; nil for a sample that is not synthesised.
    let instruments: [Instrument?]

    /// The first bytes of a file of them, which say which program saved it.
    private static let marks: [StaticString] = ["ST1.2 ModuleINFO", "ST1.3 ModuleINFO", "AudioSculpture10"]

    /// True for a file of Startrekker's or Audio Sculpture's instruments.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 16 else { return false }
        return marks.contains { mark in mark.withUTF8Buffer { Array($0) == Array(data[0 ..< 16]) } }
    }

    /// Reads a file of instruments; nil if it is not one. A file cut short has nothing where it ends,
    /// and a record cut off before its mark is not synthesised.
    init?(_ data: [UInt8]) {
        guard Self.isOne(data) else { return nil }
        let file = ByteReader(data)
        var instruments = [Instrument?](repeating: nil, count: 31)
        for sample in 0 ..< 31 {
            // ASREPLAY finds a sample's record at 24 + 120 times its number (`mt_playvoice`).
            let at = 144 + sample * 120
            guard file[at] == 0x41, file[at + 1] == 0x4D else { continue } // "AM"
            func word(_ offset: Int) -> Int16 { Int16(truncatingIfNeeded: file.u16be(at + offset)) }
            var instrument = Instrument()
            instrument.startLevel = word(6)
            instrument.attackLevel = word(8)
            instrument.attackSpeed = word(10)
            instrument.secondAttackLevel = word(12)
            instrument.secondAttackSpeed = word(14)
            instrument.sustainLevel = word(16)
            instrument.decaySpeed = word(18)
            instrument.sustainTime = word(20)
            instrument.releaseSpeed = word(24)
            instrument.waveform = file.u16be(at + 26)
            instrument.pitchFall = word(28)
            instrument.vibratoDepth = word(30)
            instrument.vibratoSpeed = word(32)
            instrument.octave = UInt16(file.u16be(at + 34))
            instruments[sample] = instrument
        }
        self.instruments = instruments
    }

    /// True if any sample is synthesised.
    var hasAny: Bool { instruments.contains { $0 != nil } }

    func instrument(_ number: UInt8) -> Instrument? {
        number >= 1 && number <= 31 ? instruments[Int(number) - 1] : nil
    }

    // MARK: The waveforms

    /// Where in memory the waveforms are put: four of 32 bytes, and one more, silent, for a waveform
    /// past the four (whose number ASREPLAY reads on into whatever follows its tables).
    static let waveformBytes = 5 * 32

    /// Sine, sawtooth and square, as ASREPLAY has them (`mt_amwaveforms`). The fourth, noise, is made
    /// afresh on every tick.
    private static let waveforms: [Int8] = [
        0, 25, 49, 71, 90, 106, 117, 125, 127, 125, 117, 106, 90, 71, 49, 25,
        0, -25, -49, -71, -90, -106, -117, -125, -127, -125, -117, -106, -90, -71, -49, -25,
        -128, -120, -112, -104, -96, -88, -80, -72, -64, -56, -48, -40, -32, -24, -16, -8,
        0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120,
        -128, -128, -128, -128, -128, -128, -128, -128, -128, -128, -128, -128, -128, -128, -128, -128,
        127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127,
    ]

    /// Writes the waveforms into memory at `at`.
    static func writeWaveforms(_ memory: UnsafeMutablePointer<Int8>, at: Int) {
        for i in 0 ..< waveforms.count { memory[at + i] = waveforms[i] }
        for i in waveforms.count ..< waveformBytes { memory[at + i] = 0 }
    }

    /// Where a waveform is, from where they all are.
    static func waveform(_ number: Int, at: Int) -> Int {
        at + 32 * (number >= 0 && number < 4 ? number : 4)
    }

    /// Makes the noise afresh, as ASREPLAY does at the end of every tick (the end of `mt_amhandler`):
    /// each byte from the one before, the word $7327 to begin with, with the low byte of where the
    /// screen's beam is across its line added in, which the Amiga reads from $DFF007, and the
    /// word then turned about. The beam moves on as the loop goes round; where it is when the loop
    /// begins depends on when the timer fired, which is as good as chance, and so is `beam` here.
    /// `beam` is where it begins, and moves on with every tick.
    static func makeNoise(_ memory: UnsafeMutablePointer<Int8>, at: Int, beam: inout UInt32) {
        beam = beam &* 1_664_525 &+ 1_013_904_223
        // A line is 227 of the beam's steps, and the loop takes about 27 of them to go round once:
        // 54 or so of the 68000's cycles.
        var position = (beam >> 16) % 227
        var word: UInt16 = 0x7327
        for i in 0 ..< 32 {
            memory[at + 3 * 32 + i] = Int8(truncatingIfNeeded: word)
            word = (word & 0xFF00) | UInt16(UInt8(truncatingIfNeeded: word) &+ UInt8(position))
            word ^= 124
            word = word << 3 | word >> 13
            position = (position + 27) % 227
        }
    }

    // MARK: The vibrato

    /// Half a sine wave in 180 steps, as ASREPLAY has it (`mt_amsinus`).
    private static let sine: [Int16] = [
        0, 2, 4, 6, 8, 11, 13, 15, 17, 20, 22, 24, 26, 28, 30, 33, 35, 37, 39, 41, 43, 45, 47, 50, 52, 54, 56, 58, 60, 62,
        63, 65, 67, 69, 71, 73, 75, 77, 78, 80, 82, 83, 85, 87, 88, 90, 92, 93, 95, 96, 98, 99, 100, 102, 103, 104, 106,
        107, 108, 109, 110, 111, 113, 114, 115, 116, 116, 117, 118, 119, 120, 121, 121, 122, 123, 123, 124, 124, 125, 125,
        126, 126, 126, 127, 127, 127, 127, 127, 127, 127, 128, 127, 127, 127, 127, 127, 127, 127, 126, 126, 126, 125, 125,
        124, 124, 123, 123, 122, 121, 121, 120, 119, 118, 117, 116, 115, 114, 113, 111, 110, 109, 108, 107, 106, 104, 103,
        102, 100, 99, 98, 96, 95, 93, 92, 90, 88, 87, 85, 83, 82, 80, 78, 77, 75, 73, 71, 69, 67, 65, 64, 62, 60, 58, 56,
        54, 52, 50, 47, 45, 43, 41, 39, 37, 35, 33, 30, 28, 26, 24, 22, 20, 17, 15, 13, 11, 8, 6, 4, 2, 0,
    ]

    /// How far the vibrato moves the period at an angle, which is kept in two's of a degree (the
    /// place in bytes of a word of the table, as ASREPLAY keeps it): a whole turn is 720.
    static func vibrato(depth: Int16, angle: Int16) -> Int16 {
        var at = angle
        var below = false
        if at >= 360 {
            at &-= 360
            below = true
        }
        // (An angle the table does not reach, which only a speed of many thousands could bring
        // about, has ASREPLAY read whatever lies beside it; here it is nothing.)
        let step = at >= 0 && at < 360 ? sine[Int(at) >> 1] : 0
        // The 68000's multiply of two words, and a shift of the low word of what it makes.
        let product = Int16(truncatingIfNeeded: Int32(step) * Int32(depth))
        let move = product >> 7
        return below ? 0 &- move : move
    }
}
