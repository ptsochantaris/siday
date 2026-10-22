// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// how it plays a module of Digitrakker's (`soundlib/Snd_fx.cpp`, `soundlib/Sndmix.cpp`, with the
// tables of `soundlib/Tables.cpp`).

/// What Digitrakker does otherwise than Impulse Tracker, for a module of Digitrakker's (see `MDLFile`
/// and `IT2Module.playsAsDigitrakker`). Digitrakker's replayer has never been published; this is how
/// OpenMPT plays these files, which is as Impulse Tracker plays its own but for these:
///  - A note's pitch is a period, which a slide moves by so much whatever the sample's rate: a
///    sample's rate sets how high its notes are, and not how far a slide takes them. The periods of
///    the notes are Scream Tracker's, taken to whole numbers, and are moved, multiplied and divided
///    as whole numbers.
///  - Vibrato and tremolo go as ProTracker's do: by a wave of 64 steps, not moving on along it on a
///    row's first tick, and as deep as Impulse Tracker's "old effects" have them.
///  - A note that is cut (SCx) is turned down to nothing and goes on, so that a volume brings it
///    back; SC0 cuts it at once, and SD0 does not hold it up at all.
///  - A note whose key is let go fades, if its instrument has a fade, whatever its volume envelope
///    does; and the end of that envelope neither fades it nor ends it. Fades are finer.
///  - An envelope of pitch goes up or down by six semitones at the most, not sixteen.
///  - The vibrato a sample has of its own is OpenMPT's, which comes in over so many ticks and goes
///    the other way to Impulse Tracker's.
///  - Oxx counts in bytes, which are half as many samples in a sample of sixteen bits, and moves a
///    note that is playing as well as one just begun.
///  - An instrument named with no note keeps the volume of the sample that was playing; one named
///    beside a key let go gives the volume of its sample for the last note; and a sample may have
///    no volume of its own.
///  - A slide to a note with no note of its own goes on with the last only until it gets there.
/// And for these files alone, and not as OpenMPT plays them, the replayer does what the volume column
/// has no room for: see `IT2DigitrakkerPan`, `IT2DigitrakkerSlide` and `IT2Module.digitrakkerHighOffsets`.
extension IT2Player {
    /// The periods of the twelve notes of an octave, Scream Tracker's for the C two octaves below
    /// middle C: Digitrakker's middle C is a period of 856.
    private static let digitrakkerPeriods: [UInt32] = [1712, 1616, 1524, 1440, 1356, 1280, 1208, 1140, 1076, 1016, 960, 907]

    /// A sample's rate at middle C, which a sample that says nought has as 8,363.
    private func digitrakkerRate(_ s: IT2Sample?) -> UInt64 {
        let rate = UInt64(s?.C5Speed ?? 0)
        return rate == 0 ? 8363 : min(rate, 5_000_000)
    }

    /// The rate a voice's sample is played at for a note (which is below 120): its rate at middle C,
    /// by middle C's period over the note's.
    func digitrakkerFrequency(_ sc: IT2SlavePointer, _ note: UInt8) -> Int32 {
        let period = Int64((Self.digitrakkerPeriods[Int(note) % 12] << 4) >> (UInt32(note) / 12))
        return digitrakkerFrequency(sc, period: period, lasting: true)
    }

    /// What a period of 1 is the rate of: the sample's rate at middle C times 856.
    private func digitrakkerBase(_ sc: IT2SlavePointer) -> Int64 {
        Int64(digitrakkerRate(sc.pointee.SmpPtr) * 856)
    }

    /// The rate of a period, which the voice is to remember (see `rememberedFrequency`).
    private func digitrakkerFrequency(_ sc: IT2SlavePointer, period: Int64, lasting: Bool) -> Int32 {
        rememberedFrequency(sc, period: period, base: digitrakkerBase(sc), lasting: lasting)
    }

    /// The period of a voice's rate as it is.
    private func digitrakkerPeriod(_ sc: IT2SlavePointer) -> Int64? {
        rememberedPeriod(sc, base: digitrakkerBase(sc))
    }

    /// A slide of pitch up by so many of a period's units (down for fewer than none), as OpenMPT
    /// slides one: a period of 1 is the sample's rate at middle C times 856, and it goes no lower.
    /// - Parameter lasting: false for a slide of this tick alone, as a vibrato's.
    func digitrakkerSlide(_ sc: IT2SlavePointer, _ units: Int16, lasting: Bool = true) {
        guard let period = digitrakkerPeriod(sc) else { return }
        sc.pointee.Frequency = digitrakkerFrequency(sc, period: max(1, period - Int64(units)), lasting: lasting)
        sc.pointee.Flags |= SF_FREQ_CHANGE
    }

    /// OpenMPT's steps of a sixteenth of a semitone (by which a rate goes up, and a period down,
    /// and the other way round), of 65,536.
    private static let stepsUp: [Int64] = (0 ..< 256).map { Int64((65536 * pow(2.0, Double($0) / 192)).rounded()) }
    private static let stepsDown: [Int64] = (0 ..< 256).map { Int64((65536 * pow(2.0, -Double($0) / 192)).rounded()) }

    /// A tick of an arpeggio: the period divided by so many semitones' worth, rounded.
    func digitrakkerArpeggio(_ sc: IT2SlavePointer, semitones: Int) {
        guard semitones > 0, let period = digitrakkerPeriod(sc) else { return }
        let ratio = Self.stepsUp[min(255, semitones * 16)]
        sc.pointee.Frequency = digitrakkerFrequency(sc, period: max(1, (period * 65536 + ratio / 2) / ratio), lasting: false)
        sc.pointee.Flags |= SF_FREQ_CHANGE
    }

    // MARK: Vibrato and tremolo

    /// ProTracker's waves of 64 steps: sine, a ramp down, square, and one at random that is always
    /// the same.
    private static let sine: [Int8] = [
        0, 12, 25, 37, 49, 60, 71, 81, 90, 98, 106, 112, 117, 122, 125, 126, 127, 126, 125, 122, 117, 112, 106, 98, 90, 81, 71, 60, 49, 37, 25, 12,
        0, -12, -25, -37, -49, -60, -71, -81, -90, -98, -106, -112, -117, -122, -125, -126, -127, -126, -125, -122, -117, -112, -106, -98, -90, -81, -71, -60, -49, -37, -25, -12,
    ]
    private static let random: [Int8] = [
        98, -127, -43, 88, 102, 41, -65, -94, 125, 20, -71, -86, -70, -32, -16, -96, 17, 72, 107, -5, 116, -69, -62, -40, 10, -61, 65, 109, -18, -38, -13, -76,
        -23, 88, 21, -94, 8, 106, 21, -112, 6, 109, 20, -88, -30, 9, -127, 118, 42, -34, 89, -4, -51, -72, 21, -29, 112, 123, 84, -101, -92, 98, -54, -95,
    ]

    private func digitrakkerWave(_ waveform: UInt8, _ position: UInt8) -> Int {
        // (The replayer keeps a position of 256 steps to the wave, as Impulse Tracker's waves have.)
        let step = Int(position >> 2) & 63
        switch waveform & 3 {
        case 1: return (step < 32 ? 0 : 255) - step * 4
        case 2: return step < 32 ? 127 : -127
        case 3: return Int(Self.random[step])
        default: return Int(Self.sine[step])
        }
    }

    /// A tick of vibrato: the pitch bent by the wave where it is, which moves on afterwards on
    /// every tick but a row's first.
    func digitrakkerVibrato(_ hc: IT2HostPointer, movesOn: Bool) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        sc.pointee.Flags |= SF_FREQ_CHANGE
        let slide = (-digitrakkerWave(hc.pointee.VibratoWaveform, hc.pointee.VibratoPos) * Int(hc.pointee.VibratoDepth)) / 64
        if slide != 0 { digitrakkerSlide(sc, Int16(slide), lasting: false) }
        if movesOn { hc.pointee.VibratoPos &+= hc.pointee.VibratoSpeed }
    }

    /// A tick of tremolo: the same for the volume, which a note turned down to nothing does not have.
    func digitrakkerTremolo(_ hc: IT2HostPointer, movesOn: Bool) {
        guard let sc = hc.pointee.SlaveChnPtr else { return }
        sc.pointee.Flags |= SF_RECALC_VOL
        if sc.pointee.VolSet > 0 {
            // (Of 256, as OpenMPT reckons it; Impulse Tracker's depth is half OpenMPT's.)
            let moved = Int(sc.pointee.Vol) * 4 + digitrakkerWave(hc.pointee.TremoloWaveform, hc.pointee.TremoloPos) * Int(hc.pointee.TremoloDepth) * 2 / 64
            sc.pointee.Vol = UInt8((max(0, min(256, moved)) + 2) / 4)
        }
        if movesOn { hc.pointee.TremoloPos &+= hc.pointee.TremoloSpeed }
    }

    // MARK: Instruments

    /// A row that names an instrument and no note. As in Impulse Tracker, the note is started again
    /// if the instrument is not the one playing, or the note has ended; but its volume is the sample's
    /// that was playing, not the new one's, and on a channel that has played nothing it starts
    /// nothing. (OpenMPT reads these files as of no tracker of its own kinds, whose instruments never
    /// stay to be used again alone, and so it does.)
    func digitrakkerInstrumentAlone(_ hc: IT2HostPointer) {
        digitrakkerAlone = true
        defer { digitrakkerAlone = false }
        let channel = Int(hc.pointee.HostChnNum) & 63
        guard let previous = digitrakkerSamples[channel] else {
            let mask = hc.pointee.NotePackMask
            hc.pointee.NotePackMask &= ~0x22
            InitNoCommand(hc)
            hc.pointee.NotePackMask = mask
            return
        }
        let held = previous.hasVolume ? previous.Vol : hc.pointee.VolSet
        InitNoCommand(hc)
        // (A volume given on the row is the row's.)
        if hc.pointee.NotePackMask & 0x44 != 0, hc.pointee.RawVolColumn <= 64 { return }
        hc.pointee.VolSet = held
        guard hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr else { return }
        sc.pointee.VolSet = held
        sc.pointee.Vol = held
        sc.pointee.Flags |= SF_RECALC_VOL
    }

    /// The sample whose volume a row that names an instrument gives the channel. Beside a note it
    /// is the note's; beside a key let go, it is the instrument's sample for the last note the
    /// channel played, where Impulse Tracker takes the sample of the instrument's number.
    func digitrakkerRowSample(_ hc: IT2HostPointer) -> IT2Sample? {
        guard hc.pointee.TranslatedNote >= 120, module.Flags & ITF_INSTR_MODE != 0 else { return module.sample(Int(hc.pointee.Smp) - 1) }
        let note = Int(digitrakkerNotes[Int(hc.pointee.HostChnNum) & 63])
        let entry = module.instrument(Int(hc.pointee.Ins) - 1).SmpNoteTable[min(note, 119)]
        return entry >> 8 == 0 ? nil : module.sample(Int(entry >> 8) - 1)
    }

    // MARK: Slides of volume

    /// A slide of volume begun by Dxy, Kxy or Lxy: true if it is one of Digitrakker's own, which
    /// Dxy's value names (`IT2DigitrakkerSlide.marker`). The row's own, or the channel's last.
    func digitrakkerInitSlide(_ hc: IT2HostPointer, _ sc: IT2SlavePointer) -> Bool {
        let channel = Int(hc.pointee.HostChnNum) & 63
        guard hc.pointee.EfxMem_DKL == IT2DigitrakkerSlide.marker else {
            digitrakkerSlides[channel].active = false
            return false
        }
        if let slide = module.digitrakkerSlides[OpenMPTSong.place(pattern: Int(CurrentPattern), row: Int(CurrentRow), channel: channel)] {
            digitrakkerSlides[channel].slide = slide
        }
        if digitrakkerSlides[channel].slide.once {
            digitrakkerSlides[channel].active = false
            digitrakkerVolumeSlide(hc, sc)
        } else {
            digitrakkerSlides[channel].active = true
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
        }
        return true
    }

    /// A step of such a slide: the volume moved by so many 256ths, which the channel keeps the
    /// part of below a 64th of until something else sets its volume.
    func digitrakkerVolumeSlide(_ hc: IT2HostPointer, _ sc: IT2SlavePointer) {
        let channel = Int(hc.pointee.HostChnNum) & 63
        var sliding = digitrakkerSlides[channel]
        let below = sliding.belowOf == sc.pointee.VolSet ? Int(sliding.below) : 0
        let level = max(0, min(256, Int(sc.pointee.VolSet) * 4 + below + Int(sliding.slide.steps)))
        if level == 0 || level == 256 { hc.pointee.Flags &= ~HF_UPDATE_EFX_IF_CHAN_ON } // it has got there
        let vol = UInt8(level >> 2)
        sliding.below = UInt8(level & 3)
        sliding.belowOf = vol
        digitrakkerSlides[channel] = sliding
        hc.pointee.VolSet = vol
        sc.pointee.VolSet = vol
        sc.pointee.Vol = vol
        sc.pointee.Flags |= SF_RECALC_VOL
    }

    // MARK: Envelopes, fades and the sample's own vibrato

    /// A tick of a voice's fade, for an instrument whose fade is a part of 65,536 a tick, as OpenMPT
    /// keeps a Digitrakker instrument's, where Impulse Tracker's is of 1,024.
    func digitrakkerFade(_ sc: IT2SlavePointer, _ ins: IT2Instrument) {
        let left = (Int(sc.pointee.FadeOut) << 6 | Int(sc.pointee.FadeOutFraction & 63)) - Int(ins.FadeOut)
        sc.pointee.FadeOut = UInt16(max(0, left) >> 6)
        sc.pointee.FadeOutFraction = UInt8(max(0, left) & 63)
    }

    /// A tick of an envelope of pitch: its level, from -32 to 32, as up to 96 of OpenMPT's steps of
    /// a sixteenth of a semitone either way, by which the period is multiplied and cut to a whole.
    func digitrakkerPitchEnvelope(_ sc: IT2SlavePointer) {
        let steps = (Int(sc.pointee.PitchEnvState.Value) * 3 + 0x8000) >> 16
        guard steps != 0, let period = digitrakkerPeriod(sc) else { return }
        let factor = steps < 0 ? Self.stepsUp[min(255, -steps)] : Self.stepsDown[min(255, steps)]
        sc.pointee.Frequency = digitrakkerFrequency(sc, period: max(1, period * factor / 65536), lasting: false)
        sc.pointee.Flags |= SF_FREQ_CHANGE
    }

    /// OpenMPT's steps of a sixteenth of a semitone, up and down: as many as a sample's own vibrato
    /// can go, which is a semitone and a little more.
    private static let slideUp: [Int] = [65536, 65773, 66011, 66250, 66489, 66730, 66971, 67213, 67456, 67700, 67945, 68191, 68438, 68685, 68933, 69183, 69433, 69684]
    private static let slideDown: [Int] = [65536, 65300, 65065, 64830, 64596, 64364, 64132, 63901, 63670, 63441, 63212, 62984, 62757, 62531, 62306, 62081, 61858, 61635]

    /// A tick of the vibrato a voice's sample has of its own. It comes in by so much a tick, until
    /// the key is let go (`AutoVibratoRate` is how many ticks it takes, as OpenMPT reckons it).
    func digitrakkerAutoVibrato(_ sc: IT2SlavePointer) {
        guard let smp = sc.pointee.SmpPtr, smp.AutoVibratoDepth != 0 else { return }
        let full = Int(smp.AutoVibratoDepth) * 256
        var depth = Int(sc.pointee.AutoVibratoDepth)
        if smp.AutoVibratoRate == 0 {
            depth = full
        } else {
            if sc.pointee.Flags & SF_NOTE_OFF == 0, depth <= full {
                depth += full / Int(smp.AutoVibratoRate)
                sc.pointee.AutoVibratoDepth = UInt16(min(depth, 0xFFFF))
            }
            depth = min(depth, full)
        }
        sc.pointee.AutoVibratoPos &+= smp.AutoVibratoSpeed
        let position = Int(sc.pointee.AutoVibratoPos)
        let wave: Int
        switch smp.AutoVibratoWaveform {
        case 1: wave = ((0x40 - position / 2) & 0x7F) - 0x40
        case 2: wave = position & 128 != 0 ? 64 : -64
        case 3: wave = Int(Self.random[position & 63])
        default: wave = -Int(it2FineSineData[position])
        }
        var n = wave * depth / 256
        // The period is multiplied by a step and some sixty-fourths of the next, which for a rate is
        // to divide by them: a period that goes down is a rate that goes up.
        let table = n < 0 ? Self.slideUp : Self.slideDown
        n = abs(n)
        let step = min(n / 256, table.count - 2), fraction = (n / 4) & 0x3F
        let factor = table[step] + (table[step + 1] - table[step]) * fraction / 64
        guard factor > 0 else { return }
        sc.pointee.Frequency = Int32(truncatingIfNeeded: min(Int64(Int32.max), Int64(sc.pointee.Frequency) * 65536 / Int64(factor)))
        sc.pointee.Flags |= SF_FREQ_CHANGE
    }

    // MARK: Offsets

    /// Oxx, once its row's note (if it has one) has been started: where in the sample the voice is
    /// to be, in bytes, with the part beyond what Oxx reaches kept beside the cell (see
    /// `IT2Module.digitrakkerHighOffsets`). Beyond the sample's end, or its loop's, it is at its start.
    func digitrakkerOffset(_ hc: IT2HostPointer) {
        var offset = UInt32(hc.pointee.CmdVal) << 8
        let high = module.digitrakkerHighOffsets[OpenMPTSong.place(pattern: Int(CurrentPattern), row: Int(CurrentRow), channel: Int(hc.pointee.HostChnNum))]
        if offset != 0 {
            hc.pointee.OffsetMemory = offset
        } else if high == nil {
            offset = hc.pointee.OffsetMemory
        }
        if let high {
            offset |= UInt32(high) << 16
            hc.pointee.OffsetMemory = offset
        }
        guard hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr else { return }
        if sc.pointee.SmpIs16Bit { offset /= 2 }
        // (A note that its instrument has no sample for moves nothing.)
        if module.Flags & ITF_INSTR_MODE != 0, hc.pointee.NotePackMask & 0x11 != 0, hc.pointee.TranslatedNote < 120, hc.pointee.Smp == 0 { return }
        if offset >= UInt32(bitPattern: max(0, sc.pointee.LoopEnd)) { offset = 0 }
        sc.pointee.SamplingPosition = Int32(bitPattern: offset)
        sc.pointee.Frac32 = 0
        sc.pointee.Frac64 = 0
    }

    /// A place between the speakers that a row gives a channel, or a move of it, that had no room
    /// in its cell (see `IT2Module.digitrakkerPans`): as Xxx would put it there, or a fine Pxy move it.
    func digitrakkerRowPan(_ hc: IT2HostPointer) {
        guard !module.digitrakkerPans.isEmpty,
              let beside = module.digitrakkerPans[OpenMPTSong.place(pattern: Int(CurrentPattern), row: Int(CurrentRow), channel: Int(hc.pointee.HostChnNum))]
        else { return }
        let playing = hc.pointee.Flags & HF_CHAN_ON != 0 ? hc.pointee.SlaveChnPtr : nil
        var pan = beside.to ?? playing?.pointee.PanSet ?? hc.pointee.ChnPan
        if beside.to == nil {
            if pan == PAN_SURROUND { return }
            pan = UInt8(max(0, min(64, Int(pan) + Int(beside.by))))
        }
        if let sc = playing {
            sc.pointee.PanSet = pan
            sc.pointee.Pan = pan
            sc.pointee.Flags |= SF_RECALC_PAN | SF_UPDATE_MIXERVOL
        }
        hc.pointee.ChnPan = pan
    }
}

/// A place between the speakers that a row of a module of Digitrakker's gives a channel beside its
/// cell, where its cell had no room for it: one to put it at, of 64, or one to move it by.
struct IT2DigitrakkerPan {
    var to: UInt8?
    var by: Int8 = 0
}

/// A slide of volume of Digitrakker's that Impulse Tracker's Dxy cannot do: by so many 256ths of
/// the whole a tick, or for one that is done once, at the row's start, by so many once. Where it is
/// in a pattern, the cell has Dxy with `marker` as its value, which Impulse Tracker does nothing
/// for and remembers, so that a slide that goes on with the last finds it.
struct IT2DigitrakkerSlide {
    var steps: Int16 = 0
    var once = false
    static let marker: UInt8 = 0x11
}

/// A channel's slide of Digitrakker's: the last it was given, whether it is going on, and the part
/// of its volume below Impulse Tracker's 64ths, which is good for as long as the volume is `belowOf`.
struct IT2DigitrakkerSliding {
    var slide = IT2DigitrakkerSlide()
    var active = false
    var below: UInt8 = 0, belowOf: UInt8 = 0
}
