// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// VGM files (Video Game Music, by Valley Bell and others, from 2001): not a tune and its player, but
// what was written to a machine's sound chips while the music played, and when. Every write is in
// the file, in order, between waits counted in 44,100ths of a second; playing it back is a matter
// of writing the same to the same chip at the same moments. The format covers some fifty chips; of
// those, the Yamaha FM chips of the PC's AdLib and Sound Blaster cards are played here, on the OPL3
// that plays the other music made for those cards: the OPL (YM3526), the OPL2 (YM3812) and the OPL3
// (YMF262), and two of any of them; the AY-3-8910 and the chips made like it, on the chip that
// plays the ZX Spectrum's and the Atari ST's music; the SN76489 of the PCjr and the Tandy 1000; the
// two SAA1099s of the Creative Music System; and a DAC, which a Sound Blaster's samples are
// recorded as written to. VGZ is the same file packed by gzip. The format is set out in
// vgmspecs.txt, which comes with VGMPlay; libvgm, its player, is what this was set beside.

/// A VGM file for the chips played here, read.
struct VGMFile {
    enum Chip: Int, CaseIterable {
        /// The YM3526, the OPL, the first of them, which has the sine wave only.
        case opl
        /// The YM3812, the OPL2: the AdLib's and the first Sound Blasters'.
        case opl2
        /// The YMF262, the OPL3, with eighteen channels and its two sides: the Sound Blaster Pro 2's and 16's.
        case opl3
        /// General Instrument's AY-3-8910, or one of the chips made like it: Yamaha's YM2149 among them.
        case ay
        /// The YM2612, the Sega Mega Drive's FM chip, of which only the DAC it has beside its FM voices
        /// is played: what a file for a PC holds of its Sound Blaster's samples is recorded as
        /// written to it, the format having no Sound Blaster of its own.
        case dac
        /// Texas Instruments' SN76489, or one made like it: the PCjr's and the Tandy 1000's among them.
        case sn
        /// Philips' SAA1099: the SAM Coupé's, and two of them the Creative Music System's.
        case saa

        /// Where a file gives its clock.
        var place: Int {
            switch self {
            case .opl2: 0x50
            case .opl: 0x54
            case .opl3: 0x5C
            case .ay: 0x74
            case .dac: 0x2C
            case .sn: 0x0C
            case .saa: 0xC8
            }
        }

        /// Its number among the format's chips, as the extra header names it.
        var number: Int {
            switch self {
            case .opl2: 0x09
            case .opl: 0x0A
            case .opl3: 0x0C
            case .ay: 0x12
            case .dac: 0x02
            case .sn: 0x00
            case .saa: 0x23
            }
        }

        var isOPL: Bool { self == .opl || self == .opl2 || self == .opl3 }
    }

    /// One of the chips a file is for, or two of the same: the second written to by commands of its own.
    struct Part {
        let chip: Chip
        let two: Bool
        /// Its clock, in Hz.
        let clock: Double
        /// What each one's sound is multiplied by: a half each, where there are two, so that two are
        /// as loud as one, unless the file says otherwise of either.
        var volumes: [Float]
    }

    let data: [UInt8]
    /// The chips, the FM chip first where there is one.
    let parts: [Part]
    /// Where the writes begin, where they end, and where they go round from, if they do.
    let start: Int, end: Int
    let loopStart: Int?
    /// How long the music is in 44,100ths of a second, to its end or to where it goes round the
    /// first time; and how long what goes round is.
    let ticks: Int, loopTicks: Int
    /// What the sound is multiplied by, as the file asks.
    let volume: Float
    /// True for two OPL2s that were a Sound Blaster Pro's, the first heard on the left and the
    /// second on the right; otherwise each is heard from the middle.
    let sides: Bool
    /// Which of the chips like the AY-3-8910 it is (the YM2149 and those after it from 0x10), and
    /// how it is wired: a YM2149 with its clock halved (0x10), or one heard as a ZX Spectrum's are,
    /// its first channel on the left and its last on the right (0x80).
    let ayType: UInt8, ayFlags: UInt8
    /// Which of the chips like the SN76489 it is.
    let snVariant: SN76489Variant
    var title = "", game = "", system = "", author = "", date = "", notes = ""

    /// The other chips the format has, by where a file gives each one's clock, and their names, to
    /// say which one a file is for when it is not one of those played here.
    private static let others: [(place: Int, name: String)] = [
        (0x10, "the YM2413 (OPLL)"),
        (0x30, "the YM2151 (OPM)"), (0x38, "Sega's PCM chip"),
        (0x40, "the RF5C68"), (0x44, "the YM2203 (OPN)"), (0x48, "the YM2608 (OPNA)"), (0x4C, "the YM2610 (OPNB)"),
        (0x58, "the Y8950 (MSX-AUDIO)"), (0x60, "the YMF278B (OPL4)"), (0x64, "the YMF271 (OPX)"), (0x68, "the YMZ280B"),
        (0x6C, "the RF5C164"), (0x70, "the 32X's PWM"), (0x80, "the Game Boy's"),
        (0x84, "the NES's"), (0x88, "the MultiPCM"), (0x8C, "the uPD7759"), (0x90, "the OKIM6258"),
        (0x98, "the OKIM6295"), (0x9C, "Konami's SCC"), (0xA0, "the K054539"), (0xA4, "the PC Engine's HuC6280"),
        (0xA8, "the C140"), (0xAC, "the K053260"), (0xB0, "the Atari's POKEY"), (0xB4, "Capcom's QSound"),
        (0xB8, "the Saturn's SCSP"), (0xC0, "the WonderSwan's"), (0xC4, "the Virtual Boy's VSU"),
        (0xCC, "the ES5503"), (0xD0, "the ES5506"), (0xD8, "the X1-010"),
        (0xDC, "the C352"), (0xE0, "the GA20"),
    ]

    init(_ data: [UInt8]) throws(TuneError) {
        guard data.count >= 0x40, data.starts(with: [0x56, 0x67, 0x6D, 0x20]) else { throw .malformed("not a VGM file") } // "Vgm "
        self.data = data
        func bits(_ at: Int) -> UInt32 {
            guard at >= 0, at + 4 <= data.count else { return 0 }
            return UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24
        }
        // (A place or a length, which is never 2 GB: an Int is only 32 bits in the browser.)
        func word(_ at: Int) -> Int { Int(bits(at) & 0x7FFF_FFFF) }
        // (Offsets are counted from where they are written.)
        let version = word(0x08)
        let given = version >= 0x150 ? word(0x34) : 0
        let header = given > 0 ? 0x34 + given : 0x40
        guard header >= 0x40, header < data.count else { throw .malformed("a VGM file whose writes begin outside it") }
        // (The header ends where its extra part begins, if that is sooner.)
        let extra = header >= 0xC0 && word(0xBC) > 0 ? 0xBC + word(0xBC) : 0
        let headerEnd = extra > 0 ? min(header, extra) : header
        func clock(_ at: Int) -> UInt32 { at + 4 <= headerEnd ? bits(at) : 0 }
        func byte(_ at: Int) -> UInt8 { at < headerEnd ? data[at] : 0 }

        for other in Self.others where clock(other.place) & 0x3FFF_FFFF != 0 {
            throw .unsupported("a VGM file for \(other.name), which is not played: only the AdLib's and Sound Blaster's FM chips, the AY-3-8910, the SN76489, the SAA1099 and a DAC are")
        }
        ayType = byte(0x78)
        ayFlags = byte(0x79)
        // (Its noise's taps and length from version 1.10, as libvgm reads them, and the rest from
        // 1.51; nought for either is the Sega chip's.)
        var variant = SN76489Variant()
        let taps = version >= 0x110 ? Int(byte(0x28)) | Int(byte(0x29)) << 8 : 0
        let width = version >= 0x110 ? Int(byte(0x2A)) : 0
        let flags = version >= 0x151 ? byte(0x2B) : 0
        variant.taps = taps != 0 ? taps : 0x0009
        variant.width = width != 0 ? min(32, width) : 16
        variant.sega = flags & 0x01 == 0
        variant.stereo = flags & 0x04 == 0
        variant.divider = flags & 0x08 != 0 ? 1 : 8
        variant.ncr = flags & 0x10 != 0
        snVariant = variant
        let used = Chip.allCases.map { ($0, clock($0.place)) }.filter { $0.1 & 0x3FFF_FFFF != 0 }
        guard !used.isEmpty else { throw .unsupported("a VGM file for no chip that is played") }
        guard used.count(where: { $0.0.isOPL }) <= 1 else { throw .unsupported("a VGM file for two kinds of FM chip at once, which is not played") }
        if let sn = used.first(where: { $0.0 == .sn }), sn.1 & 0x8000_0000 != 0 {
            throw .unsupported("a VGM file for the T6W28 (a Neo Geo Pocket's), which is not played: only the SN76489 and the chips made like it are")
        }
        if used.contains(where: { $0.0 == .ay }), ayType == 0x03 {
            throw .unsupported("a VGM file for the AY8930, which is not played: only the AY-3-8910 and the chips made like it are")
        }
        var parts: [Part] = []
        for (chip, clocked) in used {
            let two = clocked & 0x4000_0000 != 0
            var hertz = Double(clocked & 0x3FFF_FFFF)
            // (A YM2149 can be wired to halve its clock.)
            if chip == .ay, ayType >= 0x10, ayFlags & 0x10 != 0 { hertz /= 2 }
            // (How many samples a second the chip makes, which the clock is checked by. The DAC
            // makes its sound when it is written to, whatever its clock.)
            let rate: Double = switch chip {
            case .opl3: (hertz / 288).rounded(.down)
            case .opl, .opl2: (hertz / 72).rounded(.down)
            case .ay: hertz / 8
            case .dac: 100_000.0
            case .sn: hertz / 16
            case .saa: hertz / 128
            }
            guard rate >= 10000, rate <= 1_000_000 else { throw .malformed("a VGM file whose chip's clock is \(clocked & 0x3FFF_FFFF) Hz") }
            parts.append(Part(chip: chip, two: two, clock: hertz, volumes: Array(repeating: two ? 0.5 : 1, count: two ? 2 : 1)))
        }
        let opl2 = used.first { $0.0 == .opl2 }?.1 ?? 0
        sides = opl2 & 0x4000_0000 != 0 && opl2 & 0x8000_0000 != 0

        start = header
        let stated = word(0x04)
        end = stated > 0 ? min(data.count, 0x04 + stated) : data.count
        ticks = word(0x18)
        let loopOffset = word(0x1C), loopTicks = word(0x20)
        if loopOffset > 0, loopTicks > 0, 0x1C + loopOffset >= start, 0x1C + loopOffset < end {
            loopStart = 0x1C + loopOffset
            self.loopTicks = loopTicks
        } else {
            loopStart = nil
            self.loopTicks = 0
        }

        // How loud: a power of two in 32nds, from 0 to 192 and below nought above that, as VGMPlay has it.
        var gain = 0
        if header > 0x7C {
            let byte = Int(data[0x7C])
            gain = byte <= 0xC0 ? byte : byte == 0xC1 ? -0x40 : byte - 0x100
        }
        volume = Float(pow(2, Double(gain) / 32))

        // How loud each chip is, which the extra header may say, in 256ths: as it is, or of what it
        // would have been. A half each for two, as VGMPlay has it.
        if extra > 0, word(extra) >= 12, word(extra + 8) > 0 {
            let list = extra + 8 + word(extra + 8)
            let count = list < data.count ? Int(data[list]) : 0
            for entry in 0 ..< count {
                let at = list + 1 + entry * 4
                guard at + 4 <= data.count else { break }
                let which = Int(data[at + 1] & 1), value = Int(data[at + 2]) | Int(data[at + 3]) << 8
                guard let part = parts.firstIndex(where: { $0.chip.number == Int(data[at]) }), which < parts[part].volumes.count else { continue }
                let was = parts[part].volumes[which]
                parts[part].volumes[which] = value & 0x8000 != 0 ? was * Float(value & 0x7FFF) / 256 : Float(value) / 256
            }
        }
        self.parts = parts

        readTags(at: word(0x14) > 0 ? 0x14 + word(0x14) : 0)
        try scan()
    }

    /// The data the file holds for its chips to play, by the number of each bank: everything its
    /// blocks for a bank hold, one after another; and where each block begins in it, and how long it
    /// is. A block that is packed in a way that is not read here is there with nothing in it.
    private(set) var banks = [[UInt8]](repeating: [], count: 64)
    private(set) var blocks = [[(start: Int, count: Int)]](repeating: [], count: 64)

    /// Goes through the commands once, for the blocks of data they hold and for anything that is
    /// asked of a chip and not played here.
    private mutating func scan() throws(TuneError) {
        var at = start
        while at < end {
            let command = data[at]
            func byte(_ offset: Int) -> UInt8 { at + offset < end ? data[at + offset] : 0 }
            switch command {
            case 0x66:
                return
            case 0x67:
                let type = Int(byte(2))
                let size = Int(byte(3)) | Int(byte(4)) << 8 | Int(byte(5)) << 16 | Int(byte(6) & 0x7F) << 24
                let from = at + 7, to = min(end, from + size)
                if type < 0x40 {
                    blocks[type].append((banks[type].count, to - from))
                    banks[type] += data[from ..< to]
                } else if type < 0x7F {
                    // Packed: what is read of it, or nothing, with a mark that it was not played.
                    let unpacked = Self.unpack(data[from ..< to])
                    if unpacked == nil { unread = true }
                    blocks[type & 0x3F].append((banks[type & 0x3F].count, unpacked?.count ?? 0))
                    banks[type & 0x3F] += unpacked ?? []
                }
                at = from + size
                continue
            case 0x52 where byte(1) == 0x28 && byte(2) & 0xF0 != 0:
                // (The YM2612's FM voices are started by this; a file that never starts one has
                // only the DAC to be heard.)
                throw .unsupported("a VGM file for the YM2612's FM voices (a Sega Mega Drive's), which are not played: only its DAC is")
            default:
                break
            }
            at += Self.length(of: command)
        }
    }

    /// True if the file has samples packed in a way that is not read here, and so not played.
    private(set) var unread = false

    /// A block of samples as the format packs them, unpacked: those of eight bits or fewer, each kept
    /// in so many bits, highest first, as they are or moved up, with an amount added. A block packed
    /// any other way (by differences, or by a table of values) gives nil.
    static func unpack(_ block: ArraySlice<UInt8>) -> [UInt8]? {
        let bytes = Array(block)
        guard bytes.count >= 10, bytes[0] == 0x00 else { return nil }
        let length = Int(bytes[1]) | Int(bytes[2]) << 8 | Int(bytes[3]) << 16 | Int(bytes[4] & 0x7F) << 24
        let full = Int(bytes[5]), packed = Int(bytes[6]), kind = bytes[7], add = Int(bytes[8])
        guard full >= 1, full <= 8, packed >= 1, packed <= full, kind <= 1 else { return nil }
        let count = min(length, (bytes.count - 10) * 8 / packed)
        var out = [UInt8](repeating: 0, count: count)
        var bit = 10 * 8
        for index in 0 ..< count {
            var value = 0
            for _ in 0 ..< packed {
                value = value << 1 | Int(bytes[bit >> 3] >> (7 - UInt8(bit & 7)) & 1)
                bit += 1
            }
            out[index] = UInt8(truncatingIfNeeded: (kind == 1 ? value << (full - packed) : value) + add)
        }
        return out
    }

    /// How long a command is, with what goes with it, as the format has it: all but a block of data.
    static func length(of command: UInt8) -> Int {
        switch command {
        case 0x30 ... 0x3F, 0x4F, 0x50: 2
        case 0x40 ... 0x4E, 0x51 ... 0x5F, 0x61, 0xA0 ... 0xBF: 3
        case 0xC0 ... 0xDF: 4
        case 0xE0 ... 0xFF: 5
        case 0x68: 12
        case 0x90, 0x91, 0x95: 5
        case 0x92: 6
        case 0x93: 11
        case 0x94: 2
        default: 1
        }
    }

    /// What the chips are called, for saying what a file is played on.
    var chipNames: String {
        parts.map { part in
            let name = switch part.chip {
            case .opl: "YM3526 (OPL)"
            case .opl2: "YM3812 (OPL2)"
            case .opl3: "YMF262 (OPL3)"
            case .ay: ayName
            case .dac: "DAC (as a YM2612's)"
            case .sn: "SN76489"
            case .saa: "SAA1099"
            }
            return (part.two ? "2 × " : "") + name + (part.chip == .opl2 && sides ? ", left and right" : "")
        }.joined(separator: " and ")
    }

    private var ayName: String {
        switch ayType {
        case 0x01: "AY-3-8912"
        case 0x02: "AY-3-8913"
        case 0x04: "AY-3-8914"
        case 0x10: "YM2149"
        case 0x11: "YM3439"
        case 0x12: "YMZ284"
        case 0x13: "YMZ294"
        default: "AY-3-8910"
        }
    }

    /// What the file says of itself, in its GD3 tags: eleven pieces of text, each in English and
    /// then in Japanese where it has both, in UTF-16.
    private mutating func readTags(at place: Int) {
        guard place > 0, place + 12 <= data.count, data[place ..< place + 4].elementsEqual([0x47, 0x64, 0x33, 0x20]) else { return } // "Gd3 "
        let length = Int(data[place + 8]) | Int(data[place + 9]) << 8 | Int(data[place + 10]) << 16 | Int(data[place + 11] & 0x7F) << 24
        var at = place + 12
        let end = min(data.count, at + length)
        var texts: [String] = []
        while texts.count < 11, at + 1 < end {
            var units: [UInt16] = []
            while at + 1 < end {
                let unit = UInt16(data[at]) | UInt16(data[at + 1]) << 8
                at += 2
                if unit == 0 { break }
                units.append(unit)
            }
            texts.append(Self.text(units))
        }
        func piece(_ english: Int, _ japanese: Int? = nil) -> String {
            let first = english < texts.count ? texts[english] : ""
            guard first.isEmpty, let japanese, japanese < texts.count else { return first }
            return texts[japanese]
        }
        title = piece(0, 1)
        game = piece(2, 3)
        system = piece(4, 5)
        author = piece(6, 7)
        date = piece(8)
        notes = piece(10)
    }

    /// Text in UTF-16, with its pairs of halves put together. A half on its own is left out.
    private static func text(_ units: [UInt16]) -> String {
        var scalars = String.UnicodeScalarView()
        var i = 0
        while i < units.count {
            let unit = UInt32(units[i])
            i += 1
            if unit >= 0xD800, unit < 0xDC00, i < units.count, units[i] >= 0xDC00, units[i] < 0xE000 {
                let low = UInt32(units[i])
                i += 1
                if let scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) { scalars.append(scalar) }
            } else if let scalar = Unicode.Scalar(unit) {
                scalars.append(scalar)
            }
        }
        return String(scalars).trimmingSpaces
    }
}

private extension String {
    var trimmingSpaces: String {
        var text = Substring(self)
        while text.first == " " || text.first == "\n" || text.first == "\r" { text = text.dropFirst() }
        while text.last == " " || text.last == "\n" || text.last == "\r" { text = text.dropLast() }
        return String(text)
    }
}
