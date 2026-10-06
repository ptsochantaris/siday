// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Reading and tidying the text inside tune files, and writing a number the way a person would.
// Each of these does exactly what the Foundation call it replaced did (the tests hold them to that),
// so titles and authors read the same wherever the library is built.

/// The single-byte encodings tune files were written in.
enum TextEncoding {
    /// ISO 8859-1: every byte is the character of the same number.
    case latin1
    /// Windows Cyrillic, what the users of the ZX Spectrum trackers and Ay_Emul wrote in.
    case windows1251
    /// Windows Western, HVSC's encoding for SID titles and authors.
    case windows1252

    private static let unassigned: UInt16 = 0xFFFF

    /// Bytes 0x80 to 0xBF of Windows-1251; the letters from 0xC0 on are U+0410 onwards, in order.
    private static let cyrillic: [UInt16] = [
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

    /// The text, or nil if any byte has no character in this encoding.
    func decode(_ bytes: some Sequence<UInt8>) -> String? {
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            var value = UInt16(byte)
            if byte >= 0x80 {
                switch self {
                case .latin1: break
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
    func trimmed(newlines: Bool = false) -> String {
        func strip(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x09, 0x20, 0xA0, 0x1680, 0x2000 ... 0x200B, 0x202F, 0x205F, 0x3000: true
            case 0x0A ... 0x0D, 0x85, 0x2028, 0x2029: newlines
            default: false
            }
        }
        var view = unicodeScalars[...]
        while let first = view.first, strip(first) { view = view.dropFirst() }
        while let last = view.last, strip(last) { view = view.dropLast() }
        return String(String.UnicodeScalarView(view))
    }
}

/// A number to so many significant digits with no trailing zeros: 1.7734 to four is "1.773", 50 is "50".
/// This is C's `%g`, for numbers it would not write with an exponent (from 0.0001 up to the point where
/// the digits run out); anything else is written in full.
func significant(_ value: Double, digits: Int = 6) -> String {
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
