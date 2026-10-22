// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// A module of a tracker whose own replayer this player does not have, read by a loader of its own
/// (`MTMFile`, `DTMFile`, `AMFFile`) into what FastTracker 2's replayer can play.
///
/// The trackers these come from are of ProTracker's family: the same notes, the same commands with
/// the same numbers, on more channels, each channel with a place between the speakers. FastTracker
/// plays that already, for a MOD file of more than four channels. What it does not have is said
/// here and nowhere else: a place for each channel, where FastTracker has one for each sample; a
/// rate for each sample, where FastTracker has a note and a fine tuning; and MultiTracker's rule
/// for speed and tempo. The replayer does each of these only for a module that asks.
struct ForeignModule {
    struct Sample {
        /// The sample, signed, eight bits or sixteen with the low byte first.
        var data: [UInt8] = []
        /// For a sample in stereo: its right side, as `data` is then its left.
        var right: [UInt8]?
        var sixteenBit = false
        /// The part that repeats, in bytes. None, if it has no length.
        var repeatStart = 0
        var repeatLength = 0
        /// True for a repeat that goes back and forth.
        var backAndForth = false
        var volume: UInt8 = 64
        /// In 128ths of a semitone.
        var fineTune: Int8 = 0
        /// In semitones.
        var relativeNote: Int8 = 0
        /// The rate the sample plays at for the note in the middle of the keyboard, the one a MOD
        /// file plays with a period of 428. That is 8363 Hz for a sample with no rate of its own.
        var rate = 8363
    }

    struct Pattern {
        var rows = 64
        /// A row after a row, each of them a note for every channel.
        var notes: [FT2Note] = []
    }

    /// What kind of file it was, as three letters, and the tracker that made it.
    var format: String
    var tracker = ""
    var title = ""
    var channels = 4
    /// Ticks to a row, and beats a minute.
    var speed = 6
    var tempo = 125
    var orders: [UInt8] = []
    /// Where in the order the song goes on from when it has run off the end.
    var restart = 0
    var patterns: [Pattern] = []
    /// The samples, the first of them the one the patterns call 1.
    var samples: [Sample?] = []
    /// Where each channel is, from 0 on the left to 255 on the right.
    var panning: [UInt8] = []
    var speedAndTempoUndoEachOther = false
    /// True for a module whose vibrato is a quarter as deep as the same number makes ProTracker's:
    /// Digital Tracker's, as OpenMPT plays it. See `DTMFile`.
    var vibratoIsAQuarterAsDeep = false
    /// True for a module of DIGI Booster's, which is played as OpenMPT plays one where it and
    /// FastTracker differ: see `FT2DigiBooster.swift`.
    var playsAsDigiBooster = false
    /// How loud the kind of file is played, beside an XM file at 1. It is set by measure: so that
    /// of the files of the kind to hand, the middle one is as loud as the middle one of XM files.
    var loudness: Float = 1
    /// What the file asks for that FastTracker cannot do, or that its loader leaves out: see
    /// `TuneInfo.shortfalls`.
    var shortfalls: [String] = []

    /// A rate past this is not one a sample was recorded at.
    static let highestRate = 384_000
    /// Where a channel is put when the file has it to one side and does not say how far: a quarter
    /// of the way and three quarters, which is how OpenMPT places the channels of a file like that.
    static let leftward: UInt8 = 0x40, rightward: UInt8 = 0xC0

    var aFile: String { (format == "DTM" ? "a " : "an ") + format + " file" }

    /// A row number as the pattern-break command wants it: the tens in the upper half of the
    /// byte, the ones in the lower. A row FastTracker cannot break to is the top of the pattern.
    static func breakTo(row: Int) -> UInt8 {
        row >= 0 && row <= 63 ? UInt8((row / 10) << 4 | row % 10) : 0
    }

    /// A command as it is in a MOD file, made what FastTracker makes of one as it reads a MOD file:
    /// a slide by nothing is no slide, since these trackers do not remember the last one as
    /// FastTracker does, and a volume is no more than 64.
    static func tidied(_ command: UInt8, _ value: UInt8) -> (UInt8, UInt8) {
        switch command {
        case 0x1, 0x2, 0xA: value == 0 ? (0, 0) : (command, value)
        case 0x5: value == 0 ? (0x3, 0) : (command, value)
        case 0x6: value == 0 ? (0x4, 0) : (command, value)
        case 0xC: (command, min(64, value))
        default: (command, value)
        }
    }
}

extension ByteReader {
    /// Four bytes as a length or a place in the file, the last byte the most. One too large to be
    /// either is brought down to where it is still neither and can still be added to: a damaged
    /// file has numbers of all sizes, and a whole number in a browser has only 32 bits.
    func size32le(_ i: Int) -> Int {
        let high = u16le(i + 2)
        return high >= 0x4000 ? 0x3FFF_FFFF : high << 16 | u16le(i)
    }

    /// And with the first byte the most.
    func size32be(_ i: Int) -> Int {
        let high = u16be(i)
        return high >= 0x4000 ? 0x3FFF_FFFF : high << 16 | u16be(i + 2)
    }

    /// A sample's bytes: as many as the file says, from where it says. A file cut a little short
    /// keeps the sample's length, and the end of it is silence; one that speaks of far more than
    /// it holds is not believed, and the sample is what there is of it.
    func sample(at start: Int, length: Int) -> [UInt8] {
        guard length > 0, start >= 0 else { return [] }
        let there = max(0, data.count - min(start, data.count))
        let believed = length - there > 1 << 20 ? there : length
        var bytes = [UInt8](repeating: 0, count: believed)
        for i in 0 ..< min(believed, there) { bytes[i] = data[start + i] }
        return bytes
    }
}
