// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// Tables too big to write as numbers are kept in the source as base64 text, and read back once.
enum Base64 {
    /// The bytes the text stands for. Line breaks and the padding at the end are passed over.
    static func decode(_ text: StaticString) -> [UInt8] {
        text.withUTF8Buffer { text in
            var bytes: [UInt8] = []
            bytes.reserveCapacity(text.count / 4 * 3)
            var bits: UInt32 = 0, held = 0
            for character in text {
                let value: UInt32
                switch character {
                case UInt8(ascii: "A") ... UInt8(ascii: "Z"): value = UInt32(character - UInt8(ascii: "A"))
                case UInt8(ascii: "a") ... UInt8(ascii: "z"): value = UInt32(character - UInt8(ascii: "a")) + 26
                case UInt8(ascii: "0") ... UInt8(ascii: "9"): value = UInt32(character - UInt8(ascii: "0")) + 52
                case UInt8(ascii: "+"): value = 62
                case UInt8(ascii: "/"): value = 63
                default: continue
                }
                bits = bits << 6 | value
                held += 6
                if held >= 8 {
                    held -= 8
                    bytes.append(UInt8(truncatingIfNeeded: bits >> UInt32(held)))
                }
            }
            return bytes
        }
    }
}
