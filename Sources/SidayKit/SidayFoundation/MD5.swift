// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// The MD5 digest (RFC 1321), which is how HVSC's song-length database and the table of AY files with
/// known timing faults name a file. It identifies files here and protects nothing.
enum MD5 {
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    /// floor(abs(sin(i + 1)) * 2^32) for i in 0 ..< 64.
    private static let sines: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
        0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
        0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
        0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
        0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    /// The sixteen bytes of the digest.
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var a0: UInt32 = 0x6745_2301, b0: UInt32 = 0xEFCD_AB89, c0: UInt32 = 0x98BA_DCFE, d0: UInt32 = 0x1032_5476

        // The last block or two: what is left of the message, a 1 bit, zeros, and the length in bits.
        let whole = message.count / 64 * 64
        var tail = Array(message[whole...])
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = UInt64(message.count) &* 8
        for i in 0 ..< 8 { tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(8 * i))) }

        let shifts = shifts, sines = sines
        func block(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) {
            var words: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)
                = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            withUnsafeMutableBytes(of: &words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for i in 0 ..< 16 {
                    let p = offset + i * 4
                    words[i] = UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24
                }
                var a = a0, b = b0, c = c0, d = d0
                for i in 0 ..< 64 {
                    var f: UInt32
                    let g: Int
                    switch i >> 4 {
                    case 0: f = (b & c) | (~b & d); g = i
                    case 1: f = (d & b) | (~d & c); g = (5 * i + 1) & 15
                    case 2: f = b ^ c ^ d; g = (3 * i + 5) & 15
                    default: f = c ^ (b | ~d); g = (7 * i) & 15
                    }
                    f = f &+ a &+ sines[i] &+ words[g]
                    a = d; d = c; c = b
                    b = b &+ (f << shifts[i] | f >> (32 - shifts[i]))
                }
                a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
            }
        }
        message.withUnsafeBufferPointer { bytes in
            for offset in stride(from: 0, to: whole, by: 64) { block(bytes, offset) }
        }
        tail.withUnsafeBufferPointer { bytes in
            for offset in stride(from: 0, to: bytes.count, by: 64) { block(bytes, offset) }
        }

        var digest: [UInt8] = []
        for word in [a0, b0, c0, d0] {
            for i in 0 ..< 4 { digest.append(UInt8(truncatingIfNeeded: word >> UInt32(8 * i))) }
        }
        return digest
    }

    /// The digest as it is written: 32 lower-case hexadecimal digits.
    static func hex(_ message: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        for byte in hash(message) {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 15)])
        }
        return String(decoding: text, as: UTF8.self)
    }
}
