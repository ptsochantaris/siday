// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// After the XPK, SQSH and NUKE decompressors in Teemu Suutari's ancient (BSD 2-Clause; see
// THIRD-PARTY.md).

import SidayFoundation

/// XPK, the Amiga's library of packers, each a plug-in of four letters that the library called on to
/// pack and unpack: such a file begins "XPKF" and names its packer after it. Modules are found packed
/// with three of them: SQSH, which was made for sampled sound, and NUKE and DUKE, which pack as most
/// packers did, by copies of what came before (DUKE taking the differences between bytes first, as
/// suits a sample).
///
/// A file is a list of chunks, each unpacked on its own and put after the one before.
enum XPK {
    static func isPacked(_ data: [UInt8]) -> Bool {
        data.count >= 44 && data[0] == 0x58 && data[1] == 0x50 && data[2] == 0x4B && data[3] == 0x46
    }

    /// The four letters naming the packer, as text.
    static func packer(_ data: [UInt8]) -> String {
        String(decoding: data[8 ..< 12].map { $0 >= 0x20 && $0 < 0x7F ? $0 : 0x3F }, as: UTF8.self)
    }

    /// The unpacked data, or why not.
    static func unpack(_ data: [UInt8]) throws(TuneError) -> [UInt8] {
        guard isPacked(data) else { throw .malformed("not an XPK file") }
        let file = ByteReader(data)
        let packedSize = file.u32be(4), size = file.u32be(12)
        let packer = packer(data)
        guard ["SQSH", "NUKE", "DUKE"].contains(packer) else { throw .unsupported("a file packed with XPK's \(packer)") }
        guard size > 0, packedSize > 0, packedSize + 8 <= data.count, size <= 1 << 28 else { throw .malformed("an XPK file cut short") }
        let flags = file[32]
        guard flags & 2 == 0 else { throw .unsupported("an XPK file locked with a password") }
        let longHeaders = flags & 1 != 0
        let headerLength = longHeaders ? 12 : 8
        func number(_ at: Int, short: Int, long: Int) -> Int {
            longHeaders ? file.u32be(at + long) : file.u16be(at + short)
        }

        var output = [UInt8](repeating: 0, count: size)
        var written = 0
        var at = flags & 4 != 0 ? 38 + file.u16be(36) : 36
        while true {
            guard at + headerLength <= packedSize + 8 else { throw .malformed("an XPK file cut short") }
            let kind = file[at]
            let chunkSize = number(at, short: 4, long: 4), rawSize = number(at, short: 6, long: 8)
            let start = at + headerLength
            guard start + chunkSize <= data.count else { throw .malformed("an XPK file cut short") }
            if kind == 15 { break }
            guard written + rawSize <= size else { throw .malformed("an XPK file that unpacks to more than it says") }
            if rawSize > 0 {
                let chunk = data[start ..< start + chunkSize]
                switch kind {
                case 0:
                    // Stored as it is.
                    guard chunkSize == rawSize else { throw .malformed("an XPK file that does not unpack") }
                    output.replaceSubrange(written ..< written + rawSize, with: chunk)
                case 1:
                    let unpacked = packer == "SQSH" ? try squashed(Array(chunk), size: rawSize) : try nuked(Array(chunk), size: rawSize, deltas: packer == "DUKE")
                    output.replaceSubrange(written ..< written + rawSize, with: unpacked)
                default:
                    throw .malformed("an XPK file that does not unpack")
                }
                written += rawSize
            }
            at = start + (chunkSize + 3) & ~3
        }
        guard written == size else { throw .malformed("an XPK file that does not unpack") }
        return output
    }

    /// Bits read from the first of them down, from bytes or from pairs of bytes, as a packer wrote them.
    private struct HighBits {
        var held: UInt32 = 0, count = 0

        mutating func read(_ wanted: Int, width: Int, next: () throws(TuneError) -> UInt32) throws(TuneError) -> Int {
            var value: UInt32 = 0, wanted = wanted
            while wanted > 0 {
                if count == 0 {
                    held = try next()
                    count = width
                }
                let taken = min(wanted, count)
                count -= taken
                value = value << UInt32(taken) | (held >> UInt32(count)) & (1 << UInt32(taken) - 1)
                wanted -= taken
            }
            return Int(value)
        }
    }

    /// SQSH: each byte of a sample told by how much it differs from the byte before,
    /// in as few bits as the last few differences needed, or else a copy of what came before. A chunk
    /// begins with its own length.
    private static func squashed(_ chunk: [UInt8], size: Int) throws(TuneError) -> [UInt8] {
        guard chunk.count >= 3, Int(chunk[0]) << 8 | Int(chunk[1]) == size else { throw .malformed("an XPK file that does not unpack") }
        var at = 2
        func byte() throws(TuneError) -> UInt32 {
            guard at < chunk.count else { throw .malformed("an XPK file cut short") }
            defer { at += 1 }
            return UInt32(chunk[at])
        }
        var reader = HighBits()
        func bits(_ count: Int) throws(TuneError) -> Int { try reader.read(count, width: 8, next: byte) }
        func signed(_ count: Int) throws(TuneError) -> Int {
            let value = try bits(count)
            return value & 1 << (count - 1) != 0 ? value - 1 << count : value
        }

        // How many bits the next differences take, from how many the last ones took and a code.
        let widths: [[Int]] = [
            [2, 3, 4, 5, 6, 7, 8, 0], [3, 2, 4, 5, 6, 7, 8, 0], [4, 3, 5, 2, 6, 7, 8, 0], [5, 4, 6, 2, 3, 7, 8, 0],
            [6, 5, 7, 2, 3, 4, 8, 0], [7, 6, 8, 2, 3, 4, 5, 0], [8, 7, 6, 2, 3, 4, 5, 0],
        ]
        var output = [UInt8](repeating: 0, count: size)
        var current = UInt8(try byte())
        output[0] = current
        var written = 1
        var runs = 0, wide = 0, lastWidth = 0
        while written < size {
            var width = 0, count = 0, copy = false
            if runs >= 8 {
                func counted() {
                    if width == 8 {
                        if wide < 20 {
                            count = 1
                        } else {
                            count = 2
                            wide += 8
                        }
                    } else {
                        count = 5
                        wide += 8
                    }
                }
                func fromTable(_ code: Int) throws(TuneError) {
                    guard lastWidth >= 2, code > 0, case let found = widths[lastWidth - 2][code - 1], found > 0 else { throw .malformed("an XPK file that does not unpack") }
                    width = found
                    counted()
                }
                // 1, 00, 010, 0110, 0111.
                if try bits(1) == 1 {
                    if lastWidth == 8 {
                        width = 8
                        counted()
                    } else {
                        width = lastWidth
                        count = 5
                        wide += 8
                    }
                } else if try bits(1) == 0 {
                    copy = true
                } else if try bits(1) == 0 {
                    try fromTable(2)
                } else if try bits(1) == 0 {
                    try fromTable(3)
                } else {
                    try fromTable(try bits(2) + 4)
                }
            } else if try bits(1) == 1 {
                copy = true
            } else {
                count = 1
                width = 8
            }

            if copy {
                // How long (0, 10, 110, 1110, 1111, then so many bits more), and how far back (1, 00, 01).
                var lengthCode = 0
                while lengthCode < 4, try bits(1) == 1 { lengthCode += 1 }
                count = [0, 2, 4, 6, 14][lengthCode] + (try bits([1, 1, 1, 3, 5][lengthCode])) + 2
                if count >= 3 {
                    if runs > 0 { runs -= 1 }
                    if count > 3, runs > 0 { runs -= 1 }
                }
                let distanceCode = try bits(1) == 1 ? 1 : try bits(1) == 0 ? 0 : 2
                let distance = [0, 256, 4352][distanceCode] + (try bits([8, 12, 14][distanceCode])) + 1
                count = min(count, size - written)
                guard distance <= written else { throw .malformed("an XPK file that does not unpack") }
                for _ in 0 ..< count {
                    output[written] = output[written - distance]
                    written += 1
                }
                current = output[written - 1]
            } else {
                count = min(count, size - written)
                for _ in 0 ..< count {
                    current &-= UInt8(truncatingIfNeeded: try signed(width))
                    output[written] = current
                    written += 1
                }
                if runs != 31 { runs += 1 }
                lastWidth = width
            }
            wide -= wide >> 3
        }
        return output
    }

    /// NUKE (and DUKE, which is NUKE with the bytes' differences packed in place of the bytes): the
    /// bytes that are not copies are read from the end of the chunk backwards, and the bits that say
    /// what to do from its start, in four streams of their own, until the two meet.
    private static func nuked(_ chunk: [UInt8], size: Int, deltas: Bool) throws(TuneError) -> [UInt8] {
        var front = 0, back = chunk.count
        func byte() throws(TuneError) -> UInt32 {
            guard front < back else { throw .malformed("an XPK file cut short") }
            defer { front += 1 }
            return UInt32(chunk[front])
        }
        func pair() throws(TuneError) -> UInt32 { try byte() << 8 | byte() }
        func quad() throws(TuneError) -> UInt32 { try pair() << 16 | pair() }
        func backByte() throws(TuneError) -> UInt8 {
            guard back > front else { throw .malformed("an XPK file cut short") }
            back -= 1
            return chunk[back]
        }
        var ones = HighBits(), twos = HighBits(), more = HighBits()
        // The stream of fours is read from the lowest bit of each 32 up.
        var fours: UInt32 = 0, foursHeld = 0
        func bit() throws(TuneError) -> Int { try ones.read(1, width: 16, next: pair) }
        func two() throws(TuneError) -> Int { try twos.read(2, width: 16, next: pair) }
        func bits(_ count: Int) throws(TuneError) -> Int { try more.read(count, width: 16, next: pair) }
        func four() throws(TuneError) -> Int {
            if foursHeld == 0 {
                fours = try quad()
                foursHeld = 32
            }
            defer {
                fours >>= 4
                foursHeld -= 4
            }
            return Int(fours & 15)
        }

        // How far back a copy reaches: its code says how many bits more and from where they count.
        let widths = [4, 6, 8, 9, 4, 7, 9, 11, 13, 14, 5, 7, 9, 11, 13, 14]
        var bases = [Int](repeating: 0, count: 16), base = 0
        for (code, width) in widths.enumerated() {
            if code == 4 || code == 10 { base = 0 }
            bases[code] = base
            base += 1 << width
        }

        var output = [UInt8](repeating: 0, count: size)
        var written = 0
        while true {
            if try bit() == 0 {
                var count = 0
                if try bit() == 1 {
                    count = 1
                } else {
                    var code: Int
                    repeat {
                        code = try two()
                        count += code != 0 ? 5 - code : 3
                    } while code == 0
                }
                guard written + count <= size else { throw .malformed("an XPK file that does not unpack") }
                for _ in 0 ..< count {
                    output[written] = try backByte()
                    written += 1
                }
            }
            if written == size { break }
            let code = try four()
            let distance = bases[code] + (try bits(widths[code]))
            var count = code < 4 ? 2 : code < 10 ? 3 : 0
            if count == 0 {
                count = try two()
                if count == 0 {
                    count = 6
                    var more: Int
                    repeat {
                        more = try four()
                        count += more != 0 ? 16 - more : 15
                    } while more == 0
                } else {
                    count = 7 - count
                }
            }
            guard distance > 0, distance <= written, written + count <= size else { throw .malformed("an XPK file that does not unpack") }
            for _ in 0 ..< count {
                output[written] = output[written - distance]
                written += 1
            }
        }
        if deltas {
            var sum: UInt8 = 0
            for i in output.indices {
                sum &+= output[i]
                output[i] = sum
            }
        }
        return output
    }
}
