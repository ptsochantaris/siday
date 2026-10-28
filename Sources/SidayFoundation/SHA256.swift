// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// The SHA-256 digest (FIPS 180-4), by which jcmoyer's Nuked SC-55 names the Sound Canvas's ROMs. It
/// identifies files here and protects nothing.
package enum SHA256 {
    private static let k: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]

    /// The thirty-two bytes of the digest.
    package static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A, 0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19]
        // The last block or two: what is left of the message, a 1 bit, zeros, and the length in bits.
        let whole = message.count / 64 * 64
        var tail = Array(message[whole...])
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = UInt64(message.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }

        var w = [UInt32](repeating: 0, count: 64)
        func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { x >> n | x << (32 - n) }
        func block(_ bytes: UnsafePointer<UInt8>) {
            for i in 0 ..< 16 {
                w[i] = UInt32(bytes[i * 4]) << 24 | UInt32(bytes[i * 4 + 1]) << 16 | UInt32(bytes[i * 4 + 2]) << 8 | UInt32(bytes[i * 4 + 3])
            }
            for i in 16 ..< 64 {
                let s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ w[i - 15] >> 3
                let s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ w[i - 2] >> 10
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0 ..< 64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ choice &+ k[i] &+ w[i]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ majority
                hh = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            h[0] &+= a
            h[1] &+= b
            h[2] &+= c
            h[3] &+= d
            h[4] &+= e
            h[5] &+= f
            h[6] &+= g
            h[7] &+= hh
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
        for word in h {
            digest += [UInt8(word >> 24), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)]
        }
        return digest
    }

    /// The digest in lower-case hexadecimal, as `shasum -a 256` writes it.
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
