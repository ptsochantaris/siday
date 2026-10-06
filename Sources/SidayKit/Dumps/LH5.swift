// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// After ar002 by Haruhiko Okumura, which is in the public domain.
//
// LHA "-lh5-" decoder (8 KB dictionary, static Huffman), after Haruhiko Okumura's public-domain ar002.

private struct BitReader {
    let data: [UInt8]
    var pos: Int
    var buffer: UInt32 = 0
    var available = 0

    init(_ data: [UInt8], offset: Int) {
        self.data = data
        pos = offset
    }

    /// Past the end of input, zero bits are returned.
    mutating func bits(_ n: Int) -> Int {
        if n == 0 { return 0 }
        while available < n {
            let byte: UInt32 = pos < data.count ? UInt32(data[pos]) : 0
            pos += 1
            buffer = (buffer << 8) | byte
            available += 8
        }
        available -= n
        return Int((buffer >> UInt32(available)) & ((1 << UInt32(n)) - 1))
    }

    var exhausted: Bool { pos > data.count + 8 }
}

/// Canonical Huffman code built from code lengths.
private struct HuffmanCode {
    var counts = [Int](repeating: 0, count: 17)
    var symbols: [Int] = []
    /// When every length is zero the code is a single fixed symbol that takes no bits.
    var single: Int?

    init(single: Int) {
        self.single = single
    }

    init(lengths: [Int]) {
        for l in lengths where l > 0 && l <= 16 { counts[l] += 1 }
        var offsets = [Int](repeating: 0, count: 18)
        for l in 1 ... 16 { offsets[l + 1] = offsets[l] + counts[l] }
        symbols = [Int](repeating: 0, count: offsets[17])
        for (symbol, l) in lengths.enumerated() where l > 0 && l <= 16 {
            symbols[offsets[l]] = symbol
            offsets[l] += 1
        }
    }

    func decode(_ reader: inout BitReader) -> Int? {
        if let single { return single }
        var code = 0, first = 0, index = 0
        for length in 1 ... 16 {
            code |= reader.bits(1)
            let count = counts[length]
            if code - count < first {
                return symbols[index + (code - first)]
            }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        return nil
    }
}

public enum LH5 {
    private static let nc = 510, np = 14, nt = 19

    private static func readPTLengths(_ r: inout BitReader, count nn: Int, bits nbit: Int, special: Int) -> HuffmanCode {
        let n = r.bits(nbit)
        if n == 0 {
            return HuffmanCode(single: r.bits(nbit))
        }
        var lengths = [Int](repeating: 0, count: nn)
        var i = 0
        while i < min(n, nn) {
            var c = r.bits(3)
            if c == 7 {
                while r.bits(1) == 1, c < 32 { c += 1 }
            }
            lengths[i] = c
            i += 1
            if i == special {
                var skip = r.bits(2)
                while skip > 0, i < nn {
                    lengths[i] = 0
                    i += 1
                    skip -= 1
                }
            }
        }
        return HuffmanCode(lengths: lengths)
    }

    private static func readCLengths(_ r: inout BitReader, pt: HuffmanCode) -> HuffmanCode? {
        let n = r.bits(9)
        if n == 0 {
            return HuffmanCode(single: r.bits(9))
        }
        var lengths = [Int](repeating: 0, count: nc)
        var i = 0
        while i < min(n, nc) {
            guard let c = pt.decode(&r) else { return nil }
            if c <= 2 {
                var run = c == 0 ? 1 : (c == 1 ? r.bits(4) + 3 : r.bits(9) + 20)
                while run > 0, i < nc {
                    lengths[i] = 0
                    i += 1
                    run -= 1
                }
            } else {
                lengths[i] = c - 2
                i += 1
            }
        }
        return HuffmanCode(lengths: lengths)
    }

    /// Decodes `originalSize` bytes of raw lh5 data starting at `offset`. Returns nil if the stream is invalid.
    /// A stream that merely stops early (a truncated file) yields what it held, padded with zeros.
    public static func decode(_ source: [UInt8], offset: Int, originalSize: Int) -> [UInt8]? {
        guard originalSize >= 0, originalSize <= 64 << 20 else { return nil }
        var r = BitReader(source, offset: offset)
        var out = [UInt8](repeating: 0, count: originalSize)
        var outPos = 0
        func stopped() -> [UInt8]? { r.pos >= source.count && outPos > 0 ? out : nil }
        var blockRemaining = 0
        var cCode = HuffmanCode(single: 0)
        var pCode = HuffmanCode(single: 0)

        while outPos < originalSize {
            if blockRemaining == 0 {
                if r.exhausted { return stopped() }
                blockRemaining = r.bits(16)
                if blockRemaining == 0 { return stopped() }
                let pt = readPTLengths(&r, count: nt, bits: 5, special: 3)
                guard let c = readCLengths(&r, pt: pt) else { return stopped() }
                cCode = c
                pCode = readPTLengths(&r, count: np, bits: 4, special: -1)
            }
            blockRemaining -= 1
            guard let c = cCode.decode(&r) else { return stopped() }
            if c < 256 {
                out[outPos] = UInt8(c)
                outPos += 1
            } else {
                let length = c - 256 + 3
                guard var p = pCode.decode(&r) else { return stopped() }
                if p != 0 {
                    p = (1 << (p - 1)) + r.bits(p - 1)
                }
                var from = outPos - p - 1
                for _ in 0 ..< length where outPos < originalSize {
                    // LHA starts with a dictionary full of spaces.
                    out[outPos] = from >= 0 ? out[from] : 0x20
                    outPos += 1
                    from += 1
                }
            }
        }
        return out
    }

    /// Unwraps a single-file LHA archive (level 0 or 1 header) using lh5 or lh0. Returns nil if `data` is not one.
    public static func unwrapArchive(_ data: [UInt8]) -> [UInt8]? {
        guard data.count > 22, data[2] == UInt8(ascii: "-"), data[3] == UInt8(ascii: "l"), data[6] == UInt8(ascii: "-") else { return nil }
        let r = ByteReader(data)
        let headerSize = Int(data[0])
        let method = data[5]
        var packed = r.u32le(7)
        let original = r.u32le(11)
        let level = data[20]
        var dataStart = headerSize + 2
        if level == 1 {
            // Extended headers follow, each ending with the size of the next; their total is counted in `packed`.
            var next = r.u16le(dataStart - 2)
            while next != 0, dataStart + next <= data.count {
                dataStart += next
                packed -= next
                next = r.u16le(dataStart - 2)
            }
        } else if level != 0 {
            return nil
        }
        guard dataStart <= data.count else { return nil }
        switch method {
        case UInt8(ascii: "0"):
            return Array(data[dataStart ..< min(data.count, dataStart + original)])
        case UInt8(ascii: "5"), UInt8(ascii: "4"):
            _ = packed
            return decode(data, offset: dataStart, originalSize: original)
        default:
            return nil
        }
    }
}
