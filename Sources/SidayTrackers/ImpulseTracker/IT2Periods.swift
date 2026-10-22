// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// how it keeps a note's pitch as a period (`soundlib/Snd_fx.cpp`, `soundlib/Sndmix.cpp`), with the
// tables of `soundlib/Tables.cpp`.

/// Pitches kept as periods. Impulse Tracker keeps a note's pitch as the rate its sample is played
/// at. OpenMPT keeps a module of Digitrakker's (see `IT2Digitrakker`), and an MPTM file that does not
/// ask for its pitches in Hertz (see `OpenMPTSong.Periods`), as a period: a whole number, which the
/// rate is worked out from each tick, and which slides, vibratos and the rest move, multiply and
/// divide as a whole number. A high note's period is a small number, and so its pitch is coarser
/// than its rate would be, and moves in larger steps.
extension IT2Player {
    // This replayer keeps the rate, in whole samples a second, and a low note's period is finer
    // than that. So a voice remembers the periods of its last few rates: of those that last (a
    // note's, and where a slide has got to) and of the one of this tick alone (a vibrato's or an
    // envelope's), and the period of a rate is the one remembered, if there is one, and only else
    // worked out from the rate.

    /// How many of its lasting rates a voice remembers; and one more for the tick's own.
    static let periodsKept = 4

    /// The rate of a period, which the voice is to remember: the rate that a period of 1 is (the
    /// base) divided by the period.
    /// - Parameter lasting: false for a rate of this tick alone, as a vibrato's.
    func rememberedFrequency(_ sc: IT2SlavePointer, period: Int64, base: Int64, lasting: Bool) -> Int32 {
        let frequency = Int32(truncatingIfNeeded: min(Int64(Int32.max), (base + period / 2) / period))
        let voice = sc - sChn
        if voice >= 0, voice < MAX_SLAVE_CHANNELS {
            var slot = (voice + 1) * (Self.periodsKept + 1) - 1
            if lasting {
                slot = voice * (Self.periodsKept + 1) + Int(nextKnownPeriod[voice] % UInt8(Self.periodsKept))
                nextKnownPeriod[voice] &+= 1
            }
            knownPeriods[slot] = (frequency, period)
        }
        return frequency
    }

    /// The period of a voice's rate as it is, for a period of 1 that is the base.
    func rememberedPeriod(_ sc: IT2SlavePointer, base: Int64) -> Int64? {
        let frequency = Int64(sc.pointee.Frequency)
        guard frequency > 0 else { return nil }
        let voice = sc - sChn
        if voice >= 0, voice < MAX_SLAVE_CHANNELS {
            for slot in voice * (Self.periodsKept + 1) ..< (voice + 1) * (Self.periodsKept + 1) {
                let known = knownPeriods[slot]
                if Int64(known.frequency) == frequency, known.period > 0, (base + known.period / 2) / known.period == frequency { return known.period }
            }
        }
        return max(1, (base + frequency / 2) / frequency)
    }

    // MARK: OpenMPT's periods

    /// Scream Tracker's periods of the twelve notes of an octave, for the C five octaves below
    /// middle C (each octave up halves them).
    private static let s3mPeriods: [UInt64] = [1712, 1616, 1524, 1440, 1356, 1280, 1208, 1140, 1076, 1016, 960, 907]
    /// The least period a note keeps: OpenMPT's for a module of Impulse Tracker's.
    private static let leastPeriod: Int64 = 16

    /// A voice's sample's rate at middle C, which a sample that says nought has as 8,363.
    private func openMPTRate(_ sc: IT2SlavePointer) -> UInt64 {
        let rate = UInt64(sc.pointee.SmpPtr?.C5Speed ?? 0)
        return rate == 0 ? 8363 : rate
    }

    /// The rate that a period of 1 is. With linear slides it is the sample's rate at middle C times
    /// 1,712, which is middle C's period, and so the period of a note is the same whatever the
    /// sample; without, it is 8,363 times that, and the sample's rate is in the period. (And for
    /// the FM chip, a rate sixteen times finer: see `OpenMPTAdLib.fineShift`.)
    func openMPTBase(_ sc: IT2SlavePointer) -> Int64 {
        let base = Int64(module.Flags & ITF_LINEAR_FRQ != 0 ? openMPTRate(sc) * 1712 : 8363 * 1712)
        return fineFMPitch && sc.pointee.SmpPtr?.AdLib != nil ? base << OpenMPTAdLib.fineShift : base
    }

    /// The rate a voice's sample is played at for a note (which is below 120), from the note's
    /// period: Scream Tracker's for it, cut to a whole number, and without linear slides the
    /// sample's rate at middle C over 8,363 divided into it.
    func openMPTPeriodFrequency(_ sc: IT2SlavePointer, _ note: UInt8) -> Int32 {
        let octave = UInt64(note) / 12, period = Self.s3mPeriods[Int(note) % 12] << 5
        let notePeriod: UInt64
        if module.Flags & ITF_LINEAR_FRQ != 0 {
            notePeriod = period >> octave
        } else {
            notePeriod = 8363 * period / (min(openMPTRate(sc), UInt64(UInt32.max) >> octave) << octave)
        }
        guard notePeriod > 0 else { return 0 }
        return rememberedFrequency(sc, period: Int64(notePeriod), base: openMPTBase(sc), lasting: true)
    }

    /// A period times so much over 65,536, rounded.
    private static func times(_ period: Int64, _ factor: UInt32) -> Int64 {
        (period * Int64(factor) + 32768) >> 16
    }

    /// A slide of pitch up by so many units (down for fewer than none), as OpenMPT slides a period.
    /// With linear slides it is multiplied by a sixty-fourth of a semitone for each unit up to
    /// fifteen, and beyond that by a sixteenth for every four, and moved by one at least; without,
    /// so many units are taken off it. A lasting slide goes no higher than the least period.
    /// - Parameter lasting: false for a slide of this tick alone, as a vibrato's.
    func openMPTPeriodSlide(_ sc: IT2SlavePointer, _ units: Int, lasting: Bool) {
        let base = openMPTBase(sc)
        guard units != 0, let period = rememberedPeriod(sc, base: base) else { return }
        var moved = period
        if module.Flags & ITF_LINEAR_FRQ != 0 {
            // (A rate that goes up is a period that goes down: the tables the other way round.)
            let up = units > 0, amount = abs(units)
            if amount < 16 {
                moved = Self.times(moved, up ? openMPTFineLinearSlideDownTable[amount] : openMPTFineLinearSlideUpTable[amount])
            } else {
                var left = amount / 4
                while left > 0 {
                    let step = min(left, 255)
                    moved = Self.times(moved, up ? openMPTLinearSlideDownTable[step] : openMPTLinearSlideUpTable[step])
                    left -= step
                }
            }
            if moved == period { moved += up ? (moved > 1 ? -1 : 0) : 1 }
        } else {
            moved -= Int64(units)
        }
        moved = max(lasting ? Self.leastPeriod : 1, moved)
        sc.pointee.Frequency = rememberedFrequency(sc, period: moved, base: base, lasting: lasting)
        sc.pointee.Flags |= SF_FREQ_CHANGE
    }

    /// The same for a rate in hertz, as OpenMPT slides one in an MPTM file that asks for its pitches
    /// so, with linear slides: by OpenMPT's own tables, which are not quite Impulse Tracker's, each
    /// step rounded where Impulse Tracker's replayer cuts it short, and moved by one at least.
    func openMPTFrequencySlide(_ sc: IT2SlavePointer, _ units: Int) {
        let frequency = Int64(sc.pointee.Frequency)
        guard units != 0, frequency > 0 else { return }
        let up = units > 0, amount = abs(units)
        var moved = frequency
        if amount < 16 {
            moved = Self.times(moved, up ? openMPTFineLinearSlideUpTable[amount] : openMPTFineLinearSlideDownTable[amount])
        } else {
            var left = amount / 4
            while left > 0 {
                let step = min(left, 255)
                moved = Self.times(moved, up ? openMPTLinearSlideUpTable[step] : openMPTLinearSlideDownTable[step])
                left -= step
            }
        }
        if moved == frequency { moved += up ? 1 : (moved > 1 ? -1 : 0) }
        sc.pointee.Frequency = Int32(truncatingIfNeeded: min(Int64(Int32.max), moved))
        sc.pointee.Flags |= SF_FREQ_CHANGE
    }

    /// A tick of Impulse Tracker's arpeggio: the period divided by so many semitones' worth, rounded.
    func openMPTPeriodArpeggio(_ sc: IT2SlavePointer, semitones: Int) {
        let base = openMPTBase(sc)
        guard semitones > 0, let period = rememberedPeriod(sc, base: base) else { return }
        let ratio = Int64(openMPTLinearSlideUpTable[min(255, semitones * 16)])
        sc.pointee.Frequency = rememberedFrequency(sc, period: max(1, (period * 65536 + ratio / 2) / ratio), base: base, lasting: false)
        sc.pointee.Flags |= SF_FREQ_CHANGE
    }

    /// The same for a rate in hertz: multiplied, rounded.
    func openMPTFrequencyArpeggio(_ sc: IT2SlavePointer, semitones: Int) {
        guard semitones > 0 else { return }
        let ratio = openMPTLinearSlideUpTable[min(255, semitones * 16)]
        sc.pointee.Frequency = Int32(truncatingIfNeeded: min(Int64(Int32.max), Self.times(Int64(sc.pointee.Frequency), ratio)))
        sc.pointee.Flags |= SF_FREQ_CHANGE
    }

    /// A tick of an envelope of pitch: its level as up to 256 sixteenths of a semitone either way,
    /// by which the period is multiplied and cut to a whole.
    func openMPTPeriodPitchEnvelope(_ sc: IT2SlavePointer) {
        let steps = max(-256, min(256, (Int(sc.pointee.PitchEnvState.Value) + 4096) >> 13))
        let base = openMPTBase(sc)
        guard steps != 0, let period = rememberedPeriod(sc, base: base) else { return }
        let factor = steps > 0 ? openMPTLinearSlideDownTable[min(255, steps)] : openMPTLinearSlideUpTable[min(255, -steps)]
        sc.pointee.Frequency = rememberedFrequency(sc, period: max(1, (period * Int64(factor)) >> 16), base: base, lasting: false)
        sc.pointee.Flags |= SF_FREQ_CHANGE
    }

    /// The rate of a period of 256ths, which is what a sample's own vibrato leaves: the last thing
    /// done to the pitch of the tick, and so not remembered.
    private func openMPTFinePeriod(_ sc: IT2SlavePointer, _ fine: Int64, base: Int64) {
        guard fine > 0 else { return }
        sc.pointee.Frequency = Int32(truncatingIfNeeded: min(Int64(Int32.max), (base * 256 + fine / 2) / fine))
        sc.pointee.Flags |= SF_FREQ_CHANGE
    }

    /// A tick of a sample's own vibrato in Impulse Tracker's way (see `openMPTAutoVibrato`), by so
    /// many sixty-fourths of a semitone up (down for fewer than none): the period in 256ths moved by
    /// the coarse step and the fine step together.
    func openMPTPeriodAutoVibrato(_ sc: IT2SlavePointer, steps: Int) {
        let base = openMPTBase(sc)
        guard let period = rememberedPeriod(sc, base: base) else { return }
        let fine = period * 256, amount = abs(steps)
        func step(_ factor: UInt32) -> Int64 { fine * Int64(factor) / 65536 - fine }
        var moved: Int64
        if steps < 0 {
            moved = step(openMPTLinearSlideUpTable[min(255, amount / 4)])
            if amount & 3 != 0 { moved += step(openMPTFineLinearSlideUpTable[amount & 3]) }
        } else {
            moved = step(openMPTLinearSlideDownTable[min(255, amount / 4)])
            if amount & 3 != 0 { moved += step(openMPTFineLinearSlideDownTable[amount & 3]) }
        }
        openMPTFinePeriod(sc, fine + moved, base: base)
    }

    /// A tick of a sample's own vibrato in OpenMPT's own way (see `openMPTOwnAutoVibrato`), by so
    /// many 256ths of a sixteenth of a semitone up (down for fewer than none): the period times a
    /// share between two of the tables' steps.
    func openMPTPeriodOwnAutoVibrato(_ sc: IT2SlavePointer, by n: Int) {
        let base = openMPTBase(sc)
        guard let period = rememberedPeriod(sc, base: base) else { return }
        let amount = abs(n), table = n < 0 ? openMPTLinearSlideUpTable : openMPTLinearSlideDownTable
        let first = Int64(table[min(254, amount / 256)]), second = Int64(table[min(255, amount / 256 + 1)])
        openMPTFinePeriod(sc, period * (first + (second - first) * Int64((amount / 4) & 0x3F) / 64) / 256, base: base)
    }
}

// OpenMPT's tables of steps up and down, of 65,536: a sixteenth of a semitone a step, and a
// sixty-fourth for the fine ones. (They are not quite Impulse Tracker's, a few of whose are further
// out.)
let openMPTLinearSlideUpTable: [UInt32] = [
    65536, 65773, 66011, 66250, 66489, 66730, 66971, 67213, 67456, 67700, 67945, 68191,
    68438, 68685, 68933, 69183, 69433, 69684, 69936, 70189, 70443, 70698, 70953, 71210,
    71468, 71726, 71985, 72246, 72507, 72769, 73032, 73297, 73562, 73828, 74095, 74363,
    74632, 74902, 75172, 75444, 75717, 75991, 76266, 76542, 76819, 77096, 77375, 77655,
    77936, 78218, 78501, 78785, 79069, 79355, 79642, 79930, 80220, 80510, 80801, 81093,
    81386, 81681, 81976, 82273, 82570, 82869, 83169, 83469, 83771, 84074, 84378, 84683,
    84990, 85297, 85606, 85915, 86226, 86538, 86851, 87165, 87480, 87796, 88114, 88433,
    88752, 89073, 89396, 89719, 90043, 90369, 90696, 91024, 91353, 91684, 92015, 92348,
    92682, 93017, 93354, 93691, 94030, 94370, 94711, 95054, 95398, 95743, 96089, 96436,
    96785, 97135, 97487, 97839, 98193, 98548, 98905, 99262, 99621, 99982, 100343, 100706,
    101070, 101436, 101803, 102171, 102540, 102911, 103283, 103657, 104032, 104408, 104786, 105165,
    105545, 105927, 106310, 106694, 107080, 107468, 107856, 108246, 108638, 109031, 109425, 109821,
    110218, 110617, 111017, 111418, 111821, 112226, 112631, 113039, 113448, 113858, 114270, 114683,
    115098, 115514, 115932, 116351, 116772, 117194, 117618, 118043, 118470, 118899, 119329, 119760,
    120194, 120628, 121065, 121502, 121942, 122383, 122825, 123270, 123715, 124163, 124612, 125063,
    125515, 125969, 126425, 126882, 127341, 127801, 128263, 128727, 129193, 129660, 130129, 130600,
    131072, 131546, 132022, 132499, 132978, 133459, 133942, 134427, 134913, 135401, 135890, 136382,
    136875, 137370, 137867, 138366, 138866, 139368, 139872, 140378, 140886, 141395, 141907, 142420,
    142935, 143452, 143971, 144491, 145014, 145539, 146065, 146593, 147123, 147655, 148189, 148725,
    149263, 149803, 150345, 150889, 151434, 151982, 152532, 153083, 153637, 154193, 154750, 155310,
    155872, 156435, 157001, 157569, 158139, 158711, 159285, 159861, 160439, 161019, 161602, 162186,
    162773, 163361, 163952, 164545,
]
let openMPTLinearSlideDownTable: [UInt32] = [
    65536, 65300, 65065, 64830, 64596, 64364, 64132, 63901, 63670, 63441, 63212, 62984,
    62757, 62531, 62306, 62081, 61858, 61635, 61413, 61191, 60971, 60751, 60532, 60314,
    60097, 59880, 59664, 59449, 59235, 59022, 58809, 58597, 58386, 58176, 57966, 57757,
    57549, 57341, 57135, 56929, 56724, 56519, 56316, 56113, 55911, 55709, 55508, 55308,
    55109, 54910, 54713, 54515, 54319, 54123, 53928, 53734, 53540, 53347, 53155, 52963,
    52773, 52582, 52393, 52204, 52016, 51829, 51642, 51456, 51270, 51085, 50901, 50718,
    50535, 50353, 50172, 49991, 49811, 49631, 49452, 49274, 49097, 48920, 48743, 48568,
    48393, 48218, 48044, 47871, 47699, 47527, 47356, 47185, 47015, 46846, 46677, 46509,
    46341, 46174, 46008, 45842, 45677, 45512, 45348, 45185, 45022, 44859, 44698, 44537,
    44376, 44216, 44057, 43898, 43740, 43582, 43425, 43269, 43113, 42958, 42803, 42649,
    42495, 42342, 42189, 42037, 41886, 41735, 41584, 41434, 41285, 41136, 40988, 40840,
    40693, 40547, 40400, 40255, 40110, 39965, 39821, 39678, 39535, 39392, 39250, 39109,
    38968, 38828, 38688, 38548, 38409, 38271, 38133, 37996, 37859, 37722, 37586, 37451,
    37316, 37181, 37047, 36914, 36781, 36648, 36516, 36385, 36254, 36123, 35993, 35863,
    35734, 35605, 35477, 35349, 35221, 35095, 34968, 34842, 34716, 34591, 34467, 34343,
    34219, 34095, 33973, 33850, 33728, 33607, 33486, 33365, 33245, 33125, 33005, 32887,
    32768, 32650, 32532, 32415, 32298, 32182, 32066, 31950, 31835, 31720, 31606, 31492,
    31379, 31266, 31153, 31041, 30929, 30817, 30706, 30596, 30485, 30376, 30266, 30157,
    30048, 29940, 29832, 29725, 29618, 29511, 29405, 29299, 29193, 29088, 28983, 28879,
    28774, 28671, 28567, 28464, 28362, 28260, 28158, 28056, 27955, 27855, 27754, 27654,
    27554, 27455, 27356, 27258, 27159, 27062, 26964, 26867, 26770, 26674, 26577, 26482,
    26386, 26291, 26196, 26102,
]
let openMPTFineLinearSlideUpTable: [UInt32] = [
    65536, 65595, 65654, 65714, 65773, 65832, 65892, 65951, 66011, 66071, 66130, 66190,
    66250, 66309, 66369, 66429,
]
let openMPTFineLinearSlideDownTable: [UInt32] = [
    65535, 65477, 65418, 65359, 65300, 65241, 65182, 65123, 65065, 65006, 64947, 64888,
    64830, 64772, 64713, 64645,
]
