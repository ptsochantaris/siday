// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Deli-Wizard 2.20 (1995) by Nicolas "Gryzor" Franck, the check-and-convert routines of
// his Pro-Wizard for the Amiga, whose source he released in 2000 and which UADE keeps in
// amigasrc/players/uade/tracker/converter/Deli-Wizard.s (CheckChan, ConvertChan and the routines they
// call). See THIRD-PARTY.md.

import SidayFoundation

/// Channel Player's music, of Fury of the Furries (Kalisto, 1993) and its CD32 version: ProTracker
/// modules packed for the game, of which the only reading known is Deli-Wizard's, Nicolas Franck's
/// converter of packed modules into ProTracker's for DeliTracker, which UADE's player of ProTracker's
/// modules runs on them. It knows three versions of the packing, and tells them apart by the notes.
///
/// The file begins with three words: where the order is, how long it is, and how long the notes are;
/// then how long the samples are together, and each sample's header: where it begins, its length, its
/// volume, where its loop begins, the loop's length and its finetune (times 72). The order has, for
/// each place in the song, the four tracks its voices play, each of a voice's 64 lines; the notes are
/// those tracks; and then come the samples, one after another. In the first version a track is given by
/// its number, and each line of it is three bytes; in the second and third, by where it begins in the
/// notes, and a line may be fewer bytes. A note is given as twice its number in ProTracker's table,
/// counted from one, and one more for a sample above the fifteenth; and a slide of the volume is given
/// as a number with a sign. (In the files known, where each sample begins and where its loop begins
/// are both counted from the sample.)
///
/// It is unpacked into the ProTracker module Deli-Wizard makes of it, with a pattern for each different
/// four tracks the order has, numbered as they are first played, and played as one. (Deli-Wizard also
/// writes its name into the names of three of the samples, which have no names: that is left out.)
enum ChannelPlayer {
    /// The versions of the packing Deli-Wizard knows.
    enum Version {
        /// Three bytes for each line of a track, and a track given by its number.
        case one
        /// A line of two bytes for a command alone, or a note and its sample alone.
        case two
        /// And a line of one byte for no note, or a note alone.
        case three
    }

    // The file, read as the Amiga's memory holds it: nought where it has nothing, before or after it.

    private static func byte(_ data: [UInt8], _ at: Int) -> Int {
        at >= 0 && at < data.count ? Int(data[at]) : 0
    }

    private static func word(_ data: [UInt8], _ at: Int) -> Int {
        byte(data, at) << 8 | byte(data, at + 1)
    }

    /// (Four bytes are kept as four bytes, which a whole number in a browser has no room for.)
    private static func long(_ data: [UInt8], _ at: Int) -> UInt32 {
        UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2))
    }

    /// A word that is added to an address as a word, which the 68000 takes to have a sign.
    private static func signed(_ value: Int) -> Int {
        Int(Int16(truncatingIfNeeded: value))
    }

    /// What Deli-Wizard's check finds in a file it takes.
    private struct Layout {
        var version: Version
        var sampleCount: Int
        /// The samples' length together.
        var sampleBytes: Int
        /// How many places the song has.
        var places: Int
        /// The pattern each place plays, numbered as they are first played.
        var order: [Int]
        var patterns: Int
    }

    /// Whether a file is Channel Player's, as Deli-Wizard tells. (`CheckChan`)
    ///
    /// Deli-Wizard's check is given the whole of a file, and so is this, whatever the rest of
    /// ProWizard's tests are given (`size`).
    static func test(_ data: [UInt8], _ size: Int) -> Int {
        layout(data) == nil ? -1 : 0
    }

    /// The version of the packing a file is in, if it is Channel Player's.
    static func version(_ data: [UInt8]) -> Version? {
        layout(data)?.version
    }

    private static func layout(_ data: [UInt8]) -> Layout? {
        // The first word is where the order begins: after ten bytes and sixteen for each sample, of
        // which there are from one to 31.
        let orderAt = word(data, 0)
        guard orderAt & 0xF00F == 0x000A else { return nil }
        guard orderAt & 0x0FF0 != 0, orderAt & 0x0FF0 <= 0x01F0 else { return nil }
        let sampleCount = orderAt >> 4

        // Each sample: a length no longer than 32 K words, and if it is none, a loop where it begins;
        // a beginning and a loop in the first megabyte; a volume no higher than 64; and a finetune that
        // is so many times 72.
        var words = 0
        for sample in 0 ..< sampleCount {
            let at = 14 + sample * 16
            let length = word(data, at)
            guard length & 0x8000 == 0 else { return nil }
            words += length
            if length == 0, long(data, at - 4) != long(data, at + 4) { return nil }
            guard long(data, at - 4) <= 0xFE000, long(data, at + 4) <= 0xFE000 else { return nil }
            guard word(data, at + 2) <= 0x40 else { return nil }
            guard word(data, at + 10) % 0x48 == 0 else { return nil }
        }
        // And their lengths together as the file says.
        let sampleBytes = words * 2
        guard sampleBytes != 0, UInt32(sampleBytes) == long(data, 6) else { return nil }

        // An order and notes, and no more than 256 bytes of the samples missing from the end.
        let orderLength = word(data, 2)
        let notesLength = word(data, 4)
        guard orderLength != 0, notesLength != 0 else { return nil }
        let notesAt = orderAt + orderLength
        let samplesAt = notesAt + notesLength
        guard data.count - (samplesAt + sampleBytes) >= -256 else { return nil }

        // The first version is the one in whose notes no $80 is followed by a command alone, as the
        // second's are when there is no note; the third has lines of one byte, $80, for no note, and
        // the second never four of them together where a word begins. (Each looks no further than
        // four bytes before the end of the notes.)
        let end = samplesAt - 4
        var version = Version.one
        var at = notesAt
        while at < end {
            at += 1
            if byte(data, at - 1) == 0x80 {
                at += 1
                if byte(data, at - 1) <= 0x0F {
                    version = .two
                    break
                }
            }
        }
        if version == .two {
            at = notesAt
            while at < end {
                if long(data, at) == 0x8080_8080 {
                    version = .three
                    break
                }
                at += 4
            }
        }

        // The places of the song: each four bytes of the order in the first version, eight in the
        // others. (Deli-Wizard keeps the pattern of each in a table of 128, and goes on past its end
        // for more, or round 65,536 times for none: such a file is not taken here.)
        let placeBytes = version == .one ? 4 : 8
        let places = orderLength / placeBytes
        guard places > 0, places <= 128 else { return nil }

        // A pattern for each place whose tracks are not those of an earlier place. (`Chan1_Speco`,
        // `Chan2_Speco`, `Channel1_Make_PTK_Table`, `Channel2_Make_PTK_Table`)
        var order = [Int](repeating: 0, count: places)
        var patterns = 0
        for place in 1 ..< places {
            let tracks = orderAt + place * placeBytes
            var pattern: Int?
            for earlier in 0 ..< place {
                let others = orderAt + earlier * placeBytes
                if long(data, tracks) == long(data, others), placeBytes == 4 || long(data, tracks + 4) == long(data, others + 4) {
                    pattern = order[earlier]
                    break
                }
            }
            if let pattern {
                order[place] = pattern
            } else {
                patterns += 1
                order[place] = patterns
            }
        }
        patterns += 1
        return Layout(version: version, sampleCount: sampleCount, sampleBytes: sampleBytes, places: places, order: order, patterns: patterns)
    }

    /// ProTracker's periods as Deli-Wizard has them: its three octaves, and the highest note again nine
    /// times. (`mt_periodtable`, which has noughts before it.)
    private static let periods: [UInt16] = [
        0x0358, 0x0328, 0x02FA, 0x02D0, 0x02A6, 0x0280, 0x025C, 0x023A, 0x021A,
        0x01FC, 0x01E0, 0x01C5, 0x01AC, 0x0194, 0x017D, 0x0168, 0x0153, 0x0140,
        0x012E, 0x011D, 0x010D, 0x00FE, 0x00F0, 0x00E2, 0x00D6, 0x00CA, 0x00BE,
        0x00B4, 0x00AA, 0x00A0, 0x0097, 0x008F, 0x0087, 0x007F, 0x0078, 0x0071,
        0x0071, 0x0071, 0x0071, 0x0071, 0x0071, 0x0071, 0x0071, 0x0071, 0x0071,
    ]

    /// The first word of a ProTracker note, from a packed note: its period, and the sample's sixteen
    /// if it is above fifteen. Nought is no note.
    ///
    /// (Before the table are noughts, so that one is a sample above the fifteenth and no note, as
    /// Teckno's tune has; after it is more of Deli-Wizard's own data, noughts for as far as it is
    /// known, and a note past the table is taken to be none here too. No file has one.)
    private static func period(_ note: Int) -> Int {
        guard note != 0 else { return 0 }
        let high = note & 1 == 1 ? 0x1000 : 0
        let place = (note & ~1) / 2 - 1
        return (place >= 0 && place < periods.count ? Int(periods[place]) : 0) + high
    }

    /// A command, as ProTracker's last two bytes of a note: the sample's lower four bits, the command and
    /// its parameter. A pattern break's line is given as a number, and ProTracker's as two decimal
    /// digits; a slide of the volume is given with a sign, as ProTracker's is not.
    ///
    /// (A line of 100 or more for a pattern break would be read from Deli-Wizard's own code after its
    /// table of the digits; it is taken to be the first line here. No file has one.)
    private static func command(_ high: Int, _ parameter: Int) -> Int {
        var parameter = parameter
        switch high & 0x0F {
        case 0x0D:
            parameter = parameter < 100 ? (parameter / 10) << 4 | parameter % 10 : 0
        case 0x0A, 0x05, 0x06:
            parameter = parameter >= 0xF1 ? (0x100 - parameter) & 0xFF : (parameter & 0x0F) << 4
        default:
            break
        }
        return high << 8 | parameter
    }

    /// The ProTracker module a file is, as Deli-Wizard makes it. (`ConvertChan`)
    static func module(_ data: [UInt8]) throws(TuneError) -> [UInt8] {
        guard let layout = layout(data) else { throw .malformed("not Channel Player's music") }
        let orderAt = word(data, 0)
        let sampleCount = layout.sampleCount
        var module = [UInt8](repeating: 0, count: 0x43C + layout.patterns * 0x400 + layout.sampleBytes)
        func put16(_ at: Int, _ value: Int) {
            module[at] = UInt8(truncatingIfNeeded: value >> 8)
            module[at + 1] = UInt8(truncatingIfNeeded: value)
        }

        // The samples' headers: no names, and the loop's start from where it is and where the sample
        // begins. The ones the file does not have, of no length, and a loop of a word. (`Channel_Entete`)
        for sample in 0 ..< 31 {
            let header = 20 + sample * 30 + 22
            guard sample < sampleCount else {
                put16(header + 6, 1)
                continue
            }
            let at = 10 + sample * 16
            put16(header, word(data, at + 4))
            put16(header + 2, word(data, at + 6))
            module[header + 2] = UInt8(truncatingIfNeeded: word(data, at + 14) / 0x48)
            put16(header + 4, Int((long(data, at + 8) &- long(data, at)) >> 1 & 0xFFFF))
            put16(header + 6, word(data, at + 12))
        }

        // The order; and ProTracker's 127, which Deli-Wizard writes for every module it makes, and its
        // letters. (`Put_PTK_Constante`)
        module[0x3B6] = UInt8(layout.places)
        module[0x3B7] = 0x7F
        for (place, pattern) in layout.order.enumerated() {
            module[0x3B8 + place] = UInt8(pattern)
        }
        module[0x438] = 0x4D
        module[0x439] = 0x2E
        module[0x43A] = 0x4B
        module[0x43B] = 0x2E

        // The patterns, each from the first place that plays it: a voice's lines from its track.
        let placeBytes = layout.version == .one ? 4 : 8
        var made = -1
        places: for place in 0 ..< layout.places where layout.order[place] > made {
            made += 1
            let tracks = orderAt + place * placeBytes
            // (In the first version Deli-Wizard stops at a place of four tracks of nought, and makes no
            // more patterns. The track numbers are added to an address as words, with a sign.)
            if layout.version == .one, long(data, tracks) == 0 { break places }
            for voice in 0 ..< 4 {
                var at: Int
                if layout.version == .one {
                    at = orderAt + signed(word(data, 2)) + byte(data, tracks + voice) * 0xC0
                } else {
                    at = orderAt + word(data, 2) + word(data, tracks + voice * 2)
                }
                for line in 0 ..< 64 {
                    let note = 0x43C + made * 0x400 + line * 16 + voice * 4
                    var first = 0
                    var second = 0
                    let lead = byte(data, at)
                    switch layout.version {
                    case .one:
                        first = period(lead)
                        second = command(byte(data, at + 1), byte(data, at + 2))
                        at += 3
                    case .two:
                        if lead == 0x80 {
                            // A command alone, of no parameter.
                            second = (byte(data, at + 1) & 0x0F) << 8
                            at += 2
                        } else if lead > 0x80 {
                            // A note and its sample alone.
                            first = period(lead - 0x80)
                            second = byte(data, at + 1) << 8
                            at += 2
                        } else {
                            first = period(lead)
                            second = command(byte(data, at + 1), byte(data, at + 2))
                            at += 3
                        }
                    case .three:
                        if lead == 0x80 {
                            // Nothing.
                            at += 1
                        } else if lead > 0x80 {
                            // A note alone.
                            first = period(lead - 0x80)
                            at += 1
                        } else {
                            first = period(lead)
                            second = command(byte(data, at + 1), byte(data, at + 2))
                            at += 3
                        }
                    }
                    put16(note, first)
                    put16(note + 2, second)
                }
            }
        }

        // The samples, one after another. (Where they begin is found by adding the three words to the
        // file's address as words, with a sign.)
        let samplesAt = signed(orderAt) + signed(word(data, 2)) + signed(word(data, 4))
        let to = 0x43C + layout.patterns * 0x400
        for i in 0 ..< layout.sampleBytes {
            module[to + i] = UInt8(byte(data, samplesAt + i))
        }
        return module
    }

    /// Unpacks a file this test took, for ProWizard. (The file is read as a whole, as Deli-Wizard
    /// reads it.)
    static func depack(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        try output.write(module(input.data))
    }
}
