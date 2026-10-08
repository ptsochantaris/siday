// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from AdPlug's composer.cpp, Copyright (C) 1999 - 2006 Simon Peter and others, by OPLx,
// Stas'M and Jepael after the ADLIB.C of AdLib's own programming kit; used under the GNU Lesser
// General Public License, version 2.1 or later (see THIRD-PARTY.md).

/// AdLib's sound driver: what stood between a program and the card's chip, turning "this voice,
/// this note, this loud, this instrument" into the chip's registers.
///
/// It has nine voices, or six and the chip's five drums. A voice's pitch can be bent, in
/// twenty-fifths of a semitone, and its loudness is the instrument's own level scaled by a volume.
/// The names are the reference's.
final class AdLibDriver {
    private static let skNrStepPitch = 25
    private static let skMaxNotes = 96
    static let kSilenceNote = -12
    static let kBassDrumChannel = 6
    static let kSnareDrumChannel = 7
    static let kTomtomChannel = 8
    private static let kTomTomNote = 24
    private static let kTomTomToSnare = 7
    static let kMidPitch = 0x2000
    static let kMaxVolume: UInt8 = 0x7F

    /// Where each of the nine voices' first operator is among the chip's registers.
    private static let op_table: [UInt8] = [0x00, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x10, 0x11, 0x12]
    /// And the one operator of each drum that has only one: snare, tom-tom, cymbal, hi-hat.
    private static let drum_op_table: [UInt8] = [0x14, 0x12, 0x15, 0x11]

    /// The chip's number for each note of an octave, at each twenty-fifth of a semitone above it.
    private static let skFNumNotes: [UInt16] = [
        343, 364, 385, 408, 433, 459, 486, 515, 546, 579, 614, 650,
        344, 365, 387, 410, 434, 460, 488, 517, 548, 581, 615, 652,
        345, 365, 387, 410, 435, 461, 489, 518, 549, 582, 617, 653,
        346, 366, 388, 411, 436, 462, 490, 519, 550, 583, 618, 655,
        346, 367, 389, 412, 437, 463, 491, 520, 551, 584, 619, 657,
        347, 368, 390, 413, 438, 464, 492, 522, 553, 586, 621, 658,
        348, 369, 391, 415, 439, 466, 493, 523, 554, 587, 622, 660,
        349, 370, 392, 415, 440, 467, 495, 524, 556, 589, 624, 661,
        350, 371, 393, 416, 441, 468, 496, 525, 557, 590, 625, 663,
        351, 372, 394, 417, 442, 469, 497, 527, 558, 592, 627, 665,
        351, 372, 395, 418, 443, 470, 498, 528, 559, 593, 628, 666,
        352, 373, 396, 419, 444, 471, 499, 529, 561, 594, 630, 668,
        353, 374, 397, 420, 445, 472, 500, 530, 562, 596, 631, 669,
        354, 375, 398, 421, 447, 473, 502, 532, 564, 597, 633, 671,
        355, 376, 398, 422, 448, 474, 503, 533, 565, 599, 634, 672,
        356, 377, 399, 423, 449, 475, 504, 534, 566, 600, 636, 674,
        356, 378, 400, 424, 450, 477, 505, 535, 567, 601, 637, 675,
        357, 379, 401, 425, 451, 478, 506, 537, 569, 603, 639, 677,
        358, 379, 402, 426, 452, 479, 507, 538, 570, 604, 640, 679,
        359, 380, 403, 427, 453, 480, 509, 539, 571, 606, 642, 680,
        360, 381, 404, 428, 454, 481, 510, 540, 572, 607, 643, 682,
        360, 382, 405, 429, 455, 482, 511, 541, 574, 608, 645, 683,
        361, 383, 406, 430, 456, 483, 512, 543, 575, 610, 646, 685,
        362, 384, 407, 431, 457, 484, 513, 544, 577, 611, 648, 687,
        363, 385, 408, 432, 458, 485, 514, 545, 578, 612, 649, 688,
    ]

    private let card: OPLCard?

    /// Which row of `skFNumNotes` each voice is bent to.
    private var mFNumFreqPtrList = [Int](repeating: 0, count: 11)
    private var mpOldFNumFreqPtr = 0
    private var mHalfToneOffset = [Int16](repeating: 0, count: 11)
    private var mVolumeCache = [UInt8](repeating: AdLibDriver.kMaxVolume, count: 11)
    private var mKSLTLCache = [UInt8](repeating: 0, count: 11)
    private var mNoteCache = [UInt8](repeating: 0, count: 11)
    private var mKOnOctFNumCache = [UInt8](repeating: 0, count: 9)
    private var mKeyOnCache = [Bool](repeating: false, count: 11)
    private(set) var mRhythmMode = false
    private var mOldPitchBendLength: Int32 = -1
    private let mPitchRangeStep = Int32(AdLibDriver.skNrStepPitch)
    private var mOldHalfToneOffset: Int16 = 0
    private var mAMVibRhythmCache: UInt8 = 0

    /// - Parameter card: the card to play on, or none to run a tune through in silence.
    init(card: OPLCard?) {
        self.card = card
        // rewind
        write(0x01, 0x20) // the chip is to heed the waveforms it is given
    }

    @inline(__always) private func write(_ reg: Int, _ value: UInt8) {
        card?.write(reg, value)
    }

    func SetRhythmMode(_ mode: Bool) {
        if mode {
            mAMVibRhythmCache |= 0x20
            write(0xBD, mAMVibRhythmCache)

            SetFreq(Self.kTomtomChannel, Self.kTomTomNote)
            SetFreq(Self.kSnareDrumChannel, Self.kTomTomNote + Self.kTomTomToSnare)
        } else {
            mAMVibRhythmCache &= ~0x20
            write(0xBD, mAMVibRhythmCache)
        }
        mRhythmMode = mode
    }

    private func SetNote(_ voice: Int, _ note: Int) {
        if voice < Self.kBassDrumChannel || !mRhythmMode {
            SetNoteMelodic(voice, note)
        } else {
            SetNotePercussive(voice, note)
        }
    }

    func NoteOn(_ voice: Int, _ note: Int) {
        SetNote(voice, note + Self.kSilenceNote)
    }

    func NoteOff(_ voice: Int) {
        SetNote(voice, Self.kSilenceNote)
    }

    private func SetNotePercussive(_ voice: Int, _ note: Int) {
        let channel_bit_mask = UInt8(1 << (4 - voice + Self.kBassDrumChannel))

        mAMVibRhythmCache &= ~channel_bit_mask
        write(0xBD, mAMVibRhythmCache)
        mKeyOnCache[voice] = false

        if note != Self.kSilenceNote {
            switch voice {
            case Self.kTomtomChannel:
                SetFreq(Self.kTomtomChannel, note)
                SetFreq(Self.kSnareDrumChannel, note + Self.kTomTomToSnare)
            case Self.kBassDrumChannel:
                SetFreq(voice, note)
            default:
                break
            }

            mKeyOnCache[voice] = true
            mAMVibRhythmCache |= channel_bit_mask
            write(0xBD, mAMVibRhythmCache)
        }
    }

    private func SetNoteMelodic(_ voice: Int, _ note: Int) {
        if voice >= 9 { return }
        write(0xB0 + voice, mKOnOctFNumCache[voice] & ~0x20)
        mKeyOnCache[voice] = false

        if note != Self.kSilenceNote {
            SetFreq(voice, note, true)
        }
    }

    /// - Parameter pitchBend: from 0 to 0x3FFF, with 0x2000 for no bend: a semitone either way.
    func ChangePitch(_ voice: Int, _ pitchBend: UInt16) {
        let pitchBendLength = (Int32(pitchBend) - Int32(Self.kMidPitch)) * mPitchRangeStep

        if voice >= Self.kBassDrumChannel, mRhythmMode { return }
        if voice >= 9 { return } // (there is no such voice without the drums)

        if mOldPitchBendLength == pitchBendLength {
            // optimisation ...
            mFNumFreqPtrList[voice] = mpOldFNumFreqPtr
            mHalfToneOffset[voice] = mOldHalfToneOffset
        } else {
            // (The division is of numbers without a sign, which for a bend downwards comes to
            // rounding down and not towards nought.)
            let pitchStepDir = Int16(truncatingIfNeeded: UInt32(bitPattern: pitchBendLength) / UInt32(Self.kMidPitch))
            var delta: Int16
            if pitchStepDir < 0 {
                let pitchStepDown = Int16(truncatingIfNeeded: Self.skNrStepPitch - 1 - Int(pitchStepDir))
                mOldHalfToneOffset = -(pitchStepDown / 25)
                mHalfToneOffset[voice] = mOldHalfToneOffset
                delta = (pitchStepDown - 25 + 1) % 25
                if delta != 0 { delta = 25 - delta }
            } else {
                mOldHalfToneOffset = pitchStepDir / 25
                mHalfToneOffset[voice] = mOldHalfToneOffset
                delta = pitchStepDir % 25
            }
            mpOldFNumFreqPtr = Int(delta)
            mFNumFreqPtrList[voice] = mpOldFNumFreqPtr
            mOldPitchBendLength = pitchBendLength
        }

        SetFreq(voice, Int(mNoteCache[voice]), mKeyOnCache[voice])
    }

    private func SetFreq(_ voice: Int, _ note: Int, _ keyOn: Bool = false) {
        let biased_note = max(0, min(Self.skMaxNotes - 1, note + Int(mHalfToneOffset[voice])))

        let frequency = Self.skFNumNotes[mFNumFreqPtrList[voice] * 12 + biased_note % 12]

        // (A note is kept in a byte, so the silence between notes, which is twelve below nought,
        // is kept as a very high one.)
        mNoteCache[voice] = UInt8(truncatingIfNeeded: note)
        mKeyOnCache[voice] = keyOn

        mKOnOctFNumCache[voice] = UInt8(biased_note / 12) << 2 | UInt8((frequency >> 8) & 0x03)

        write(0xA0 + voice, UInt8(truncatingIfNeeded: frequency))
        write(0xB0 + voice, mKOnOctFNumCache[voice] | (keyOn ? 0x20 : 0))
    }

    /// An instrument's level for a voice with the voice's volume worked in.
    private func GetKSLTL(_ voice: Int) -> UInt8 {
        var kslTL = 63 - UInt16(mKSLTLCache[voice] & 0x3F) // amplitude

        kslTL = UInt16(mVolumeCache[voice]) * kslTL
        kslTL += kslTL + UInt16(Self.kMaxVolume) // round off to 0.5
        kslTL = 63 &- (kslTL / (2 * UInt16(Self.kMaxVolume)))

        kslTL |= UInt16(mKSLTLCache[voice] & 0xC0)

        return UInt8(truncatingIfNeeded: kslTL)
    }

    func SetVolume(_ voice: Int, _ volume: UInt8) {
        if voice >= 9, !mRhythmMode { return }
        let op_offset = voice < Self.kSnareDrumChannel || !mRhythmMode ? Self.op_table[voice] + 3 : Self.drum_op_table[voice - Self.kSnareDrumChannel]

        mVolumeCache[voice] = volume

        write(0x40 + Int(op_offset), GetKSLTL(voice))
    }

    func SetInstrument(_ voice: Int, _ instrument: AdLibInstrument) {
        if voice >= 9, !mRhythmMode { return }
        let modulator = instrument.modulator, carrier = instrument.carrier

        if voice < Self.kSnareDrumChannel || !mRhythmMode {
            if voice >= 9 { return }
            let op_offset = Int(Self.op_table[voice])

            write(0x20 + op_offset, modulator.ammulti)
            write(0x40 + op_offset, modulator.ksltl)
            write(0x60 + op_offset, modulator.ardr)
            write(0x80 + op_offset, modulator.slrr)
            write(0xC0 + voice, instrument.fbc)
            write(0xE0 + op_offset, modulator.waveform)

            mKSLTLCache[voice] = carrier.ksltl

            write(0x20 + op_offset + 3, carrier.ammulti)
            write(0x40 + op_offset + 3, GetKSLTL(voice))
            write(0x60 + op_offset + 3, carrier.ardr)
            write(0x80 + op_offset + 3, carrier.slrr)
            write(0xE0 + op_offset + 3, carrier.waveform)
        } else {
            // A drum of one operator: the instrument's first is what it gets.
            let op_offset = Int(Self.drum_op_table[voice - Self.kSnareDrumChannel])

            mKSLTLCache[voice] = modulator.ksltl

            write(0x20 + op_offset, modulator.ammulti)
            write(0x40 + op_offset, GetKSLTL(voice))
            write(0x60 + op_offset, modulator.ardr)
            write(0x80 + op_offset, modulator.slrr)
            write(0xE0 + op_offset, modulator.waveform)
        }
    }
}
