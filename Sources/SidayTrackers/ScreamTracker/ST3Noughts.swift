// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

extension ST3Module {
    /// Some S3M files found on the net have had many of their noughts written over, each with the
    /// same byte, which is another in each file: in the title, which is then that byte throughout,
    /// and in the header after it, in the instruments' headers and in the patterns, though not every
    /// nought in them. (Gravedigger's Simotar is one, and a copy of another version of it whose
    /// header is whole has noughts in every place its header has the byte.) Such a file is told by
    /// its title and by the upper bytes of the count of patterns and of the song's settings, which
    /// are nought in every file a tracker writes, and the two bytes after the eight kept for later,
    /// and the first channel's setting; and the noughts are put back where they are certain to have
    /// been: where a number is past what the file could hold, or a byte is one that Scream Tracker
    /// leaves nought. The rest is left as the file has it, a nought or the byte: the volumes of the
    /// samples and the values the effects are given, which can be either, and the samples' sounds.
    /// Nil for any other file; the file mended, for one of these.
    static func mended(_ data: [UInt8]) -> [UInt8]? {
        let filler = data[0]
        guard filler != 0, data.count > 0x60, data[0 ..< 28].allSatisfy({ $0 == filler }),
              [0x25, 0x26, 0x27, 0x3E, 0x3F, 0x40].allSatisfy({ data[$0] == filler }) else { return nil }
        var d = data
        func clear(_ at: Int) { if at < d.count, d[at] == filler { d[at] = 0 } }
        func word(_ at: Int) -> Int { at + 1 < d.count ? Int(d[at]) | Int(d[at + 1]) << 8 : 0 }

        // The header: the title, the upper byte of the count of patterns, the settings, the bytes
        // kept for later, and the first channel's setting, which is then the first on the left, as
        // the next channels' say it is (L1, R1, L2 and on).
        for at in [Int](0 ..< 28) + [0x25, 0x26, 0x27] + [Int](0x36 ... 0x40) { clear(at) }
        let ordnum = word(0x20), insnum = word(0x22), patnum = word(0x24)
        guard ordnum <= mostOrders + 1, insnum <= mostInstruments, patnum <= mostPatternsOfLaterTrackers else { return d }

        // In the list of patterns to play, a pattern the file does not have.
        for at in 0x60 ..< min(d.count, 0x60 + ordnum) where d[at] == filler && Int(filler) >= patnum && filler < 254 { d[at] = 0 }

        // Where the instruments and patterns are, in sixteens: a place past the end of the file, or
        // one where no instrument's header is, has a byte that was nought.
        let pointers = 0x60 + ordnum
        func isInstrument(_ o: Int) -> Bool {
            guard o > 0, o + 0x50 <= d.count else { return false }
            let mark = Array(d[o + 0x4C ..< o + 0x50])
            return mark == Array("SCRS".utf8) || mark == Array("SCRI".utf8) || mark.allSatisfy { $0 == 0 || $0 == filler }
        }
        for k in 0 ..< insnum + patnum {
            let at = pointers + k * 2
            guard at + 1 < d.count else { break }
            let place = word(at) << 4
            let fits: (Int) -> Bool = k < insnum ? isInstrument : { $0 + 2 <= d.count }
            guard !fits(place) else { continue }
            let low = d[at] == filler ? [UInt8(0), filler] : [d[at]], high = d[at + 1] == filler ? [UInt8(0), filler] : [d[at + 1]]
            if let found = low.flatMap({ l in high.map { (l, $0) } }).first(where: { fits((Int($0.0) | Int($0.1) << 8) << 4) }) {
                d[at] = found.0
                d[at + 1] = found.1
            }
        }

        // The instruments' headers.
        for k in 0 ..< insnum {
            let o = word(pointers + k * 2) << 4
            guard o > 0, o + 0x50 <= d.count else { continue }
            let mark = Array(d[o + 0x4C ..< o + 0x50])
            let sample = mark == Array("SCRS".utf8), adLib = mark == Array("SCRI".utf8)
            if mark.allSatisfy({ $0 == filler }) { for at in o + 0x4C ..< o + 0x50 { d[at] = 0 } }
            // Its kind, unless its mark says it is of the kind the byte is.
            if d[o] == filler, !(sample && filler == 1), !(adLib && (2 ... 7).contains(filler)) { d[o] = 0 }
            // The names of its file and of itself.
            for at in o + 1 ... o + 0x0C { clear(at) }
            for at in o + 0x30 ..< o + 0x4C { clear(at) }
            guard !adLib else { continue }
            // The upper byte of where its sample is in the file, in sixteens, if that is past the end.
            if d[o + 0x0D] == filler, Int(filler) << 20 >= d.count { d[o + 0x0D] = 0 }
            // The upper halves of its length, its loop's start and end, and its rate, which Scream
            // Tracker's samples never need; the bytes it keeps for later, and how it is packed.
            for at in [0x12, 0x13, 0x16, 0x17, 0x1A, 0x1B, 0x1D, 0x1E, 0x22, 0x23] + [Int](0x24 ... 0x27) + [Int](0x2A ... 0x2F) { clear(o + at) }
            // Its settings, where they would say what Scream Tracker's samples never are (stereo).
            if d[o + 0x1F] == filler, filler & ~0x05 != 0 { d[o + 0x1F] = 0 }
            // The mark of a sample saved with a Sound Blaster is 1, with nought above it.
            if d[o + 0x28] == 1, d[o + 0x29] == filler { d[o + 0x29] = 0 }
        }

        // The patterns. Each is read as 64 rows ending within its length, and a byte that is the
        // filler where a channel's byte would be is the nought that ends a row where it cannot be a
        // channel's byte: where it would be of a channel that is not played or would say nothing
        // follows (which no tracker writes), or what would follow it is no note, instrument, volume or
        // effect, or reading it so would not come to 64 rows. (Where both readings come to 64 rows,
        // which few patterns have, it is taken as it is.) Of what follows, a note Scream Tracker has
        // not, an instrument, a volume or an effect past those there are, a jump to a place past the
        // list of patterns to play and a break to a row no pattern has, that is the filler, was
        // nought. (Other values an effect is given can be anything, and are left.) A length that is
        // too short for what the pattern holds, or has the filler in it, is counted again.
        let endsRows = filler & 0xE0 == 0 || d[0x40 + Int(filler & 0x1F)] >= 128
        let topOctave: UInt8 = word(0x28) >> 12 == 1 ? 7 : 9
        func isNote(_ v: UInt8) -> Bool { v >= 254 || (v & 0x0F <= 11 && v >> 4 <= topOctave) }
        func following(_ what: UInt8) -> Int { (what & 0x20 != 0 ? 2 : 0) + (what & 0x40 != 0 ? 1 : 0) + (what & 0x80 != 0 ? 2 : 0) }
        func readable(_ at: Int) -> Bool {
            let what = d[at]
            guard what != filler || !endsRows, at + following(what) < d.count else { return false }
            func fits(_ v: UInt8, _ good: Bool) -> Bool { good || v == filler }
            var q = at + 1
            if what & 0x20 != 0 {
                guard fits(d[q], isNote(d[q])), fits(d[q + 1], Int(d[q + 1]) <= insnum) else { return false }
                q += 2
            }
            if what & 0x40 != 0 {
                guard fits(d[q], d[q] <= 64) else { return false }
                q += 1
            }
            return what & 0x80 == 0 || fits(d[q], d[q] <= 26)
        }
        for k in 0 ..< patnum {
            let o = word(pointers + (insnum + k) * 2) << 4
            guard o > 0, o + 2 < d.count else { continue }
            let lengthWhole = d[o] != filler && d[o + 1] != filler
            let start = o + 2, limit = min(d.count, lengthWhole ? o + word(o) : start + 64 * 32 * 6)
            guard limit > start else { continue }
            // Whether 64 rows can be read from a place, with so many read already: [place][rows].
            let span = limit - start + 1
            var finishes = [Bool](repeating: false, count: span * 65)
            for at in stride(from: limit, through: start, by: -1) {
                let i = (at - start) * 65
                finishes[i + 64] = true
                guard at < limit else { continue }
                let x = d[at], next = at + 1 + following(x), canRead = x != 0 && next <= limit && readable(at)
                for rows in 0 ..< 64 {
                    if x == 0 || x == filler, finishes[i + 65 + rows + 1] { finishes[i + rows] = true }
                    if canRead, finishes[(next - start) * 65 + rows] { finishes[i + rows] = true }
                }
            }
            guard finishes[0] else { continue }
            var at = start, rows = 0
            while rows < 64 {
                let x = d[at], next = at + 1 + following(x)
                if x != 0, next <= limit, finishes[(next - start) * 65 + rows], readable(at) {
                    var q = at + 1
                    if x & 0x20 != 0 {
                        if !isNote(filler) { clear(q) }
                        if Int(filler) > insnum { clear(q + 1) }
                        q += 2
                    }
                    if x & 0x40 != 0 {
                        if filler > 64 { clear(q) }
                        q += 1
                    }
                    if x & 0x80 != 0 {
                        if filler > 26 { clear(q) }
                        if d[q] == 2, Int(filler) >= ordnum { clear(q + 1) }
                        if d[q] == 3, filler > 0x63 || filler & 0x0F > 9 { clear(q + 1) }
                    }
                    at = next
                } else {
                    d[at] = 0
                    rows += 1
                    at += 1
                }
            }
            if word(o) < at - o || !lengthWhole {
                d[o] = UInt8((at - o) & 0xFF)
                d[o + 1] = UInt8((at - o) >> 8 & 0xFF)
            }
        }
        return d
    }

    static let mendedSentence = "Many of the file's noughts have been written over with another byte: they are put back where they are certain to have been, and elsewhere, as in some of its samples' volumes, its effects' values and its samples' sounds, it is played as the file has it."
}
