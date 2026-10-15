// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// After the DEFLATE decompressor in Teemu Suutari's ancient (BSD 2-Clause; see THIRD-PARTY.md), and
// RFC 1950 and RFC 1951, which describe the zlib stream and DEFLATE.

/// DEFLATE, the packer of PKZIP 2, of gzip and of zlib, by Phil Katz: what came before told again
/// either as it is, or as Huffman's codes for bytes and for copies of what came before, as far back
/// as 32 kilobytes and as long as 258 bytes. It goes in blocks, each stored, or told in a code fixed
/// by the format, or in one of its own that it describes first, itself in codes. A zlib stream is
/// DEFLATE with two bytes before, to say so, and Mark Adler's checksum of what it unpacks to after.
enum Inflate {
    private static func refused() -> TuneError { .malformed("a zlib stream that does not unpack") }

    /// What a zlib stream unpacks to, which is to be exactly so many bytes and is checked against the
    /// stream's checksum. A stream that is not one, or is damaged, is refused.
    static func zlib(_ data: [UInt8], from start: Int, to end: Int, size: Int) throws(TuneError) -> [UInt8] {
        guard start >= 0, end <= data.count, end - start >= 6 else { throw refused() }
        let method = data[start], flags = data[start + 1]
        // (Method 8 is DEFLATE; a window of no more than 32 kilobytes; a check that the two bytes are
        // what they say; and no dictionary, which this has no way to be given.)
        guard method & 15 == 8, method >> 4 <= 7, (Int(method) << 8 | Int(flags)) % 31 == 0, flags & 0x20 == 0 else { throw refused() }
        var inflater = Inflater(data, from: start + 2, to: end, size: size)
        try inflater.run()
        guard inflater.written == size else { throw refused() }
        let at = inflater.byteAfter
        guard at + 4 <= end else { throw refused() }
        let said = UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
        guard adler32(inflater.output) == said else { throw refused() }
        return inflater.output
    }

    /// Mark Adler's checksum, which a zlib stream ends with: two sums of the bytes, one of them a sum
    /// of the sums, each kept below the greatest prime under 65,536.
    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var at = 0
        while at < data.count {
            // (5,552 bytes is as many as the sums can take before they must be brought down.)
            let end = min(data.count, at + 5552)
            while at < end {
                a &+= UInt32(data[at])
                b &+= a
                at += 1
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }

    /// The checksum of Ethernet, of PKZIP and of gzip (CRC-32, the polynomial 0xEDB88320 read from its
    /// lowest bit), over part of some bytes.
    static func crc32(_ data: [UInt8], from start: Int, to end: Int) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for at in max(0, start) ..< min(end, data.count) {
            crc = crcTable[Int((crc ^ UInt32(data[at])) & 0xFF)] ^ crc >> 8
        }
        return ~crc
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { (n: Int) -> UInt32 in
        var c = UInt32(n)
        for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ c >> 1 : c >> 1 }
        return c
    }

    // MARK: The tables of the format

    /// How long a copy is, for each of the codes from 257: the least, and how many bits more follow.
    fileprivate static let lengthBase: [UInt16] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    fileprivate static let lengthExtra: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    /// How far back a copy is from, for each of the codes for that.
    fileprivate static let distanceBase: [UInt16] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
    ]
    fileprivate static let distanceExtra: [UInt8] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    /// The order in which a block of its own codes gives the lengths of the codes it describes them in.
    fileprivate static let lengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
}

/// A code of Huffman's as DEFLATE has one: each symbol's code is given only by how many bits long it
/// is, and the codes of a length are in the order of their symbols, the shorter before the longer
/// ("canonical"). It is looked up by as many of the next bits as the longest code has, which are read
/// from the first bit of a code, the lowest of the bits.
private struct HuffmanTable {
    /// For every value of so many bits: the symbol whose code they begin with, above four bits that
    /// say how long its code is (and nought where no code begins so).
    var entries: [UInt16] = []
    var bits = 0

    /// The code of so many symbols, of these lengths (nought for a symbol that has none). Nil if no
    /// such code can be: one with more codes than there is room for, or, unless `incompleteAllowed`,
    /// with room left over (but for a code of one symbol of one bit, or of none, which zlib allows).
    init?(_ lengths: [UInt8], count: Int, incompleteAllowed: Bool) {
        var counts = [Int](repeating: 0, count: 16)
        for i in 0 ..< count { counts[Int(lengths[i])] += 1 }
        counts[0] = 0
        var left = 1
        for length in 1 ... 15 {
            left = left * 2 - counts[length]
            if left < 0 { return nil }
        }
        let longest = (1 ... 15).last { counts[$0] > 0 } ?? 0
        // (A code with nothing in it at all is allowed too, for the distances of a block that copies
        // nothing; and one that is used is then refused.)
        if left > 0, !(incompleteAllowed && longest <= 1) { return nil }
        bits = max(1, longest)
        entries = [UInt16](repeating: 0, count: 1 << bits)
        // The first code of each length.
        var next = [Int](repeating: 0, count: 16)
        var code = 0
        for length in 1 ... 15 {
            code = (code + counts[length - 1]) << 1
            next[length] = code
        }
        for symbol in 0 ..< count {
            let length = Int(lengths[symbol])
            guard length > 0 else { continue }
            let value = next[length]
            next[length] += 1
            // (Its bits the other way round, as they are read.)
            var reversed = 0
            for b in 0 ..< length where value & (1 << b) != 0 { reversed |= 1 << (length - 1 - b) }
            let entry = UInt16(symbol << 4 | length)
            var at = reversed
            while at < entries.count {
                entries[at] = entry
                at += 1 << length
            }
        }
    }
}

/// One unpacking of a DEFLATE stream.
private struct Inflater {
    let data: [UInt8]
    var at: Int
    let end: Int
    var output: [UInt8]
    var written = 0
    /// Bits read and not yet used, the first of them the lowest.
    var held: UInt64 = 0, heldCount = 0
    /// How many bytes it is to come to: no more are made than that.
    let size: Int

    init(_ data: [UInt8], from start: Int, to end: Int, size: Int) {
        self.data = data
        at = start
        self.end = end
        self.size = size
        output = [UInt8](repeating: 0, count: max(0, size))
    }

    /// The place of the first byte after the stream, once it has been unpacked: its bits are read a
    /// byte at a time, and those of the last that were not used are of no account.
    var byteAfter: Int { at - heldCount / 8 }

    private func refused() -> TuneError { .malformed("a zlib stream that does not unpack") }

    private mutating func fill(_ count: Int) throws(TuneError) {
        while heldCount < count {
            guard at < end else { throw refused() }
            held |= UInt64(data[at]) << UInt64(heldCount)
            at += 1
            heldCount += 8
        }
    }

    private mutating func bits(_ count: Int) throws(TuneError) -> Int {
        if count == 0 { return 0 }
        try fill(count)
        let value = Int(held & (1 << UInt64(count) - 1))
        held >>= UInt64(count)
        heldCount -= count
        return value
    }

    private mutating func decode(_ table: HuffmanTable) throws(TuneError) -> Int {
        // (Near the end of the stream there may not be as many bits left as the longest code has.)
        while heldCount < table.bits, at < end {
            held |= UInt64(data[at]) << UInt64(heldCount)
            at += 1
            heldCount += 8
        }
        let entry = table.entries[Int(held & (1 << UInt64(table.bits) - 1))]
        let length = Int(entry & 15)
        guard length > 0, length <= heldCount else { throw refused() }
        held >>= UInt64(length)
        heldCount -= length
        return Int(entry >> 4)
    }

    private mutating func put(_ byte: UInt8) throws(TuneError) {
        guard written < size else { throw refused() }
        output[written] = byte
        written += 1
    }

    mutating func run() throws(TuneError) {
        var last = false
        while !last {
            last = try bits(1) == 1
            switch try bits(2) {
            case 0:
                // Stored: from the next whole byte, its length, the same with every bit the other
                // way, and the bytes.
                held = 0
                at -= heldCount / 8
                heldCount = 0
                guard at + 4 <= end else { throw refused() }
                let length = Int(data[at]) | Int(data[at + 1]) << 8, check = Int(data[at + 2]) | Int(data[at + 3]) << 8
                guard length == check ^ 0xFFFF, at + 4 + length <= end, written + length <= size else { throw refused() }
                for i in 0 ..< length { output[written + i] = data[at + 4 + i] }
                written += length
                at += 4 + length
            case 1:
                try codes(Self.fixedLiterals, Self.fixedDistances)
            case 2:
                let (literals, distances) = try ownCodes()
                try codes(literals, distances)
            default:
                throw refused()
            }
        }
    }

    /// The codes the format fixes: for bytes and lengths, 8 bits for the first 144, 9 for the next
    /// 112, 7 for the next 24 and 8 for the last 8; and 5 bits for every distance. (The last two of
    /// each are codes that are never to be used.)
    private static let fixedLiterals = HuffmanTable([UInt8](repeating: 8, count: 144) + [UInt8](repeating: 9, count: 112)
        + [UInt8](repeating: 7, count: 24) + [UInt8](repeating: 8, count: 8), count: 288, incompleteAllowed: false)!
    private static let fixedDistances = HuffmanTable([UInt8](repeating: 5, count: 32), count: 32, incompleteAllowed: false)!

    /// A block's own codes, which it gives as the lengths of their codes, in turn told in a code
    /// whose lengths come first, three bits each.
    private mutating func ownCodes() throws(TuneError) -> (HuffmanTable, HuffmanTable) {
        let literalCount = try bits(5) + 257, distanceCount = try bits(5) + 1, lengthCount = try bits(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else { throw refused() }
        var lengthLengths = [UInt8](repeating: 0, count: 19)
        for i in 0 ..< lengthCount { lengthLengths[Inflate.lengthOrder[i]] = UInt8(try bits(3)) }
        guard let lengthCode = HuffmanTable(lengthLengths, count: 19, incompleteAllowed: false) else { throw refused() }

        // The lengths of both codes, one after the other (a run may go on from the one into the other).
        var lengths = [UInt8](repeating: 0, count: literalCount + distanceCount)
        var i = 0
        while i < lengths.count {
            let symbol = try decode(lengthCode)
            var value: UInt8 = 0, times = 1
            switch symbol {
            case 0 ..< 16: value = UInt8(symbol)
            case 16:
                // The last length again, three to six times.
                guard i > 0 else { throw refused() }
                value = lengths[i - 1]
                times = try bits(2) + 3
            case 17: times = try bits(3) + 3
            default: times = try bits(7) + 11
            }
            guard i + times <= lengths.count else { throw refused() }
            for _ in 0 ..< times {
                lengths[i] = value
                i += 1
            }
        }
        // (A block must have a code for its own end.)
        guard lengths[256] != 0,
              let literals = HuffmanTable(lengths, count: literalCount, incompleteAllowed: true),
              let distances = HuffmanTable(Array(lengths[literalCount...]), count: distanceCount, incompleteAllowed: true)
        else { throw refused() }
        return (literals, distances)
    }

    /// A block told in codes: bytes, and copies of what came before, to the code for its end.
    private mutating func codes(_ literals: HuffmanTable, _ distances: HuffmanTable) throws(TuneError) {
        while true {
            let symbol = try decode(literals)
            if symbol < 256 {
                try put(UInt8(symbol))
                continue
            }
            if symbol == 256 { return }
            let code = symbol - 257
            guard code < 29 else { throw refused() }
            let length = Int(Inflate.lengthBase[code]) + (try bits(Int(Inflate.lengthExtra[code])))
            let distanceCode = try decode(distances)
            guard distanceCode < 30 else { throw refused() }
            let distance = Int(Inflate.distanceBase[distanceCode]) + (try bits(Int(Inflate.distanceExtra[distanceCode])))
            guard distance <= written, written + length <= size else { throw refused() }
            // (A copy may overlap what it makes, and so goes a byte at a time.)
            for _ in 0 ..< length {
                output[written] = output[written - distance]
                written += 1
            }
        }
    }
}
