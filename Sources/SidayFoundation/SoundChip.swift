// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A chip that made a tune's sound on the machine it was written for, or on the card it was played
/// through: what a front end may show of a tune, beside its name, to say what it is heard as.
public enum SoundChip: String, CaseIterable, Sendable {
    /// The Commodore 64's, in its first model and its last.
    case sid6581, sid8580
    /// General Instrument's AY-3-8912, the ZX Spectrum 128's and the Amstrad CPC's; and the AY-3-8910,
    /// of which it is the smaller package, as a VGM file names it.
    case ay8912, ay8910
    /// Yamaha's YM2149, the Atari ST's.
    case ym2149
    /// The ZX Spectrum's ULA, which drove its beeper.
    case ula
    /// The 8-bit Ataris'.
    case pokey
    /// The Amiga's.
    case paula
    /// Yamaha's FM chips: the YM3812, the AdLib's and the first Sound Blasters'; and the YMF262, the
    /// Sound Blaster Pro 2's and 16's.
    case opl2, opl3
    /// Philips' SAA1099: the SAM Coupé's, and the Creative Music System's.
    case saa1099
    /// Texas Instruments' SN76489: the PCjr's and the Tandy 1000's, the BBC Micro's and Sega's.
    case sn76489
    /// The Gravis Ultrasound's, which mixed a tracker's samples itself.
    case gf1
    /// The Sound Blaster Pro's DSP, which played what a tracker had mixed.
    case sbPro
    /// Roland's LA32, the synthesiser of the MT-32 and of its later kind, the CM-32L and the LAPC-I card.
    case la32
    /// No chip of its own: a recording, played through a digital-to-analogue converter.
    case dac
}

public extension TuneFormat {
    /// The chip a file of this kind is most likely played on, from its kind alone: what a list may
    /// show of a tune it has not loaded. A loaded tune says which it is (`TuneInfo.chips`).
    var likelyChip: SoundChip {
        switch self {
        case .pt3, .pt2, .pt1, .stc, .stp, .asc, .sqt, .psc, .ftc, .fxm, .psm, .gtr, .vtx, .ay: .ay8912
        case .ym, .sndh: .ym2149
        case .sid: .sid6581
        case .sap: .pokey
        case .cmf, .rol, .fmt, .c67, .vgm: .opl2
        case .mid: .opl3
        case .stm, .stx, .composer669: .sbPro
        case .xm, .s3m, .it, .mptm, .mt2, .mtm, .dtm, .amf, .gdm, .ptm, .ult, .far, .mdl, .j2b, .dmf, .imf, .ams, .plm, .dsm, .masi, .mo3: .gf1
        case .ogg, .mp3, .wav: .dac
        default: .paula
        }
    }
}
