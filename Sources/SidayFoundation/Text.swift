// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Reading and tidying the text inside tune files, and writing a number the way a person would.
// Each of these does exactly what the Foundation call it replaced did (the tests hold them to that),
// so titles and authors read the same wherever the library is built.

/// The single-byte encodings tune files were written in.
package enum TextEncoding {
    /// ISO 8859-1: every byte is the character of the same number.
    case latin1
    /// Windows Cyrillic, what the users of the ZX Spectrum trackers and Ay_Emul wrote in.
    case windows1251
    /// Windows Western, HVSC's encoding for SID titles and authors.
    case windows1252
    /// The IBM PC's own set of characters (code page 437), with its lines, blocks and faces: what
    /// the titles of modules made in the DOS trackers are in, and often decorated with.
    case dos
    /// The Atari ST's own set: much of the PC's, with Hebrew and more accented letters in place of
    /// the lines and blocks. The titles of SNDH and YM files, both formats of the ST, are in it.
    case atariST

    private static let unassigned: UInt16 = 0xFFFF

    /// Bytes 0x80 to 0xBF of Windows-1251; the letters from 0xC0 on are U+0410 onwards, in order.
    package static let cyrillic: [UInt16] = [
        0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021,
        0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
        0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0xFFFF, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
        0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
        0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
        0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
        0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
    ]

    /// Bytes 0x80 to 0x9F of Windows-1252; from 0xA0 on it is ISO 8859-1.
    private static let western: [UInt16] = [
        0x20AC, 0xFFFF, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFF, 0x017D, 0xFFFF,
        0xFFFF, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFF, 0x017E, 0x0178,
    ]

    /// Bytes 0x01 to 0x1F of the PC's characters, which on its screen were not controls but pictures.
    private static let dosPictures: [UInt16] = [
        0x263A, 0x263B, 0x2665, 0x2666, 0x2663, 0x2660, 0x2022, 0x25D8, 0x25CB, 0x25D9, 0x2642, 0x2640, 0x266A, 0x266B, 0x263C,
        0x25BA, 0x25C4, 0x2195, 0x203C, 0x00B6, 0x00A7, 0x25AC, 0x21A8, 0x2191, 0x2193, 0x2192, 0x2190, 0x221F, 0x2194, 0x25B2, 0x25BC,
    ]

    /// Bytes 0x80 to 0xFF of the PC's characters.
    private static let dosUpper: [UInt16] = [
        0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7, 0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
        0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9, 0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
        0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA, 0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
        0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
        0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F, 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
        0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B, 0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
        0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4, 0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
        0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248, 0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
    ]

    /// Bytes 0x80 to 0xFF of the Atari ST's characters.
    private static let atariUpper: [UInt16] = [
        0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7, 0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
        0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9, 0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x00DF, 0x0192,
        0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA, 0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
        0x00E3, 0x00F5, 0x00D8, 0x00F8, 0x0153, 0x0152, 0x00C0, 0x00C3, 0x00D5, 0x00A8, 0x00B4, 0x2020, 0x00B6, 0x00A9, 0x00AE, 0x2122,
        0x0133, 0x0132, 0x05D0, 0x05D1, 0x05D2, 0x05D3, 0x05D4, 0x05D5, 0x05D6, 0x05D7, 0x05D8, 0x05D9, 0x05DB, 0x05DC, 0x05DE, 0x05E0,
        0x05E1, 0x05E2, 0x05E4, 0x05E6, 0x05E7, 0x05E8, 0x05E9, 0x05EA, 0x05DF, 0x05DA, 0x05DD, 0x05E3, 0x05E5, 0x00A7, 0x2227, 0x221E,
        0x03B1, 0x03B2, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4, 0x03A6, 0x0398, 0x03A9, 0x03B4, 0x222E, 0x03D5, 0x2208, 0x2229,
        0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248, 0x00B0, 0x2022, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x00B3, 0x00AF,
    ]

    /// The text, or nil if any byte has no character in this encoding.
    package func decode(_ bytes: some Sequence<UInt8>) -> String? {
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            var value = UInt16(byte)
            if self == .dos {
                if byte >= 0x80 { value = Self.dosUpper[Int(byte) - 0x80] } else if byte == 0x7F { value = 0x2302 } else if byte > 0, byte < 0x20 { value = Self.dosPictures[Int(byte) - 1] }
            } else if byte >= 0x80 {
                switch self {
                case .latin1, .dos: break
                case .atariST: value = Self.atariUpper[Int(byte) - 0x80]
                case .windows1251: value = byte >= 0xC0 ? 0x0410 + UInt16(byte - 0xC0) : Self.cyrillic[Int(byte) - 0x80]
                case .windows1252: if byte < 0xA0 { value = Self.western[Int(byte) - 0x80] }
                }
            }
            guard value != Self.unassigned, let scalar = Unicode.Scalar(value) else { return nil }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}

extension String {
    /// Without the spaces at either end: tabs and every kind of Unicode space, and line breaks too if asked.
    package func trimmed(newlines: Bool = false) -> String {
        func strip(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x09, 0x20, 0xA0, 0x1680, 0x2000 ... 0x200B, 0x202F, 0x205F, 0x3000: true
            case 0x0A ... 0x0D, 0x85, 0x2028, 0x2029: newlines
            default: false
            }
        }
        // (By index: dropping the last of a view of scalars counts the whole view each time, which for
        // a long run of spaces, such as a damaged file can have, is a wait of minutes.)
        let view = unicodeScalars
        var start = view.startIndex, end = view.endIndex
        while start < end, strip(view[start]) { start = view.index(after: start) }
        while start < end {
            let before = view.index(before: end)
            guard strip(view[before]) else { break }
            end = before
        }
        return String(String.UnicodeScalarView(view[start ..< end]))
    }
}

/// A number to so many significant digits with no trailing zeros: 1.7734 to four is "1.773", 50 is "50".
/// This is C's `%g`, for numbers it would not write with an exponent (from 0.0001 up to the point where
/// the digits run out); anything else is written in full.
package func significant(_ value: Double, digits: Int = 6) -> String {
    if value == 0 { return "0" }
    guard value.isFinite, value > 0 else { return value < 0 ? "-" + significant(-value, digits: digits) : "\(value)" }
    var exponent = Int(floor(log10(value)))
    var whole = 0.0, decimals = 0
    // The power of ten is guessed, the number rounded at that scale, and the guess put right if the
    // rounding (or the logarithm) crossed a power of ten.
    for _ in 0 ..< 3 {
        decimals = digits - 1 - exponent
        guard decimals >= 0, decimals <= 22 else { return "\(value)" }
        let scale = pow(10, Double(decimals))
        let scaled = value * scale
        whole = scaled.rounded(.down)
        // Halfway cases go by which side of half the number really is: the product above is rounded,
        // and what the rounding lost says which.
        let rest = scaled - whole, lost = (-scaled).addingProduct(value, scale)
        if rest > 0.5 || (rest == 0.5 && (lost > 0 || (lost == 0 && whole.truncatingRemainder(dividingBy: 2) == 1))) { whole += 1 }
        if whole >= pow(10, Double(digits)) {
            exponent += 1
        } else if whole < pow(10, Double(digits - 1)) {
            exponent -= 1
        } else {
            break
        }
    }
    guard exponent >= -4, decimals >= 0 else { return "\(value)" }
    var text = Array("\(UInt64(whole))".utf8)
    if decimals > 0 {
        while text.count <= decimals { text.insert(UInt8(ascii: "0"), at: 0) }
        text.insert(UInt8(ascii: "."), at: text.count - decimals)
        while text.last == UInt8(ascii: "0") { text.removeLast() }
        if text.last == UInt8(ascii: ".") { text.removeLast() }
    }
    return String(decoding: text, as: UTF8.self)
}
