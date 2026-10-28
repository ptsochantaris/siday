// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// The SHA-1 digest (FIPS 180-4), by which Munt names the MT-32's ROMs and siday knows the files it keeps.
/// It identifies files here and protects nothing.
package enum SHA1 {
    /// The twenty bytes of the digest.
    package static func hash(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x6745_2301, h1: UInt32 = 0xEFCD_AB89, h2: UInt32 = 0x98BA_DCFE, h3: UInt32 = 0x1032_5476, h4: UInt32 = 0xC3D2_E1F0
        // The last block or two: what is left of the message, a 1 bit, zeros, and the length in bits.
        let whole = message.count / 64 * 64
        var tail = Array(message[whole...])
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = UInt64(message.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }

        var w = [UInt32](repeating: 0, count: 80)
        func block(_ bytes: UnsafePointer<UInt8>) {
            for i in 0 ..< 16 {
                w[i] = UInt32(bytes[i * 4]) << 24 | UInt32(bytes[i * 4 + 1]) << 16 | UInt32(bytes[i * 4 + 2]) << 8 | UInt32(bytes[i * 4 + 3])
            }
            for i in 16 ..< 80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = x << 1 | x >> 31
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0 ..< 80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0 ..< 20: f = (b & c) | (~b & d); k = 0x5A82_7999
                case 20 ..< 40: f = b ^ c ^ d; k = 0x6ED9_EBA1
                case 40 ..< 60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
                default: f = b ^ c ^ d; k = 0xCA62_C1D6
                }
                let temp = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = b << 30 | b >> 2
                b = a
                a = temp
            }
            h0 &+= a
            h1 &+= b
            h2 &+= c
            h3 &+= d
            h4 &+= e
        }
        message.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < whole {
                block(buffer.baseAddress! + offset)
                offset += 64
            }
        }
        tail.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                block(buffer.baseAddress! + offset)
                offset += 64
            }
        }
        var digest: [UInt8] = []
        for h in [h0, h1, h2, h3, h4] {
            digest += [UInt8(h >> 24), UInt8(truncatingIfNeeded: h >> 16), UInt8(truncatingIfNeeded: h >> 8), UInt8(truncatingIfNeeded: h)]
        }
        return digest
    }

    /// The digest in lower-case hexadecimal, as Munt and `shasum` write it.
    package static func hex(_ message: [UInt8]) -> String {
        let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
        var text = ""
        for byte in hash(message) {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 15)])
        }
        return text
    }
}
