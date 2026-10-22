// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayFoundation
import CryptoKit
import Foundation
import Testing

// SidayKit uses none of Foundation. Where it once did, it now has code of its own, and these tests
// hold that code to what Foundation gives.

@Test func md5MatchesCryptoKit() {
    var generator = SystemRandomNumberGenerator()
    for length in [0, 1, 3, 55, 56, 57, 63, 64, 65, 119, 120, 128, 1000, 65536, 100_003] {
        let message = (0 ..< length).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
        let expected = Insecure.MD5.hash(data: Data(message)).map { String(format: "%02x", $0) }.joined()
        #expect(MD5.hex(message) == expected, "length \(length)")
    }
    #expect(MD5.hex([]) == "d41d8cd98f00b204e9800998ecf8427e")
    #expect(MD5.hex(Array("abc".utf8)) == "900150983cd24fb0d6963f7d28e17f72")
}

@Test func textIsDecodedAsFoundationDecodesIt() {
    let encodings: [(TextEncoding, String.Encoding)] = [(.latin1, .isoLatin1), (.windows1251, .windowsCP1251), (.windows1252, .windowsCP1252)]
    for (ours, theirs) in encodings {
        for byte in UInt8.min ... UInt8.max {
            #expect(ours.decode([byte]) == String(data: Data([byte]), encoding: theirs), "byte \(byte)")
        }
        // A byte with no character spoils the whole string, there and here.
        for bytes: [UInt8] in [[0x41, 0x98, 0x42], [0x41, 0x81, 0x42], [0xC0, 0xE0, 0xFF, 0x20, 0xA8], []] {
            #expect(ours.decode(bytes) == String(data: Data(bytes), encoding: theirs))
        }
    }
}

@Test func dosTextIsDecodedAsFoundationDecodesIt() {
    // The PC's own characters. Foundation has them too, but for the first 32 and the 128th, which to
    // it are controls and on the PC's screen were pictures: a face, a heart, a pair of quavers.
    let theirs = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
    for byte in UInt8.min ... UInt8.max where byte == 0 || (byte >= 0x20 && byte != 0x7F) {
        #expect(TextEncoding.dos.decode([byte]) == String(data: Data([byte]), encoding: theirs), "byte \(byte)")
    }
    #expect(TextEncoding.dos.decode([0x0E, 0x20, 0x01, 0x03, 0x7F]) == "♫ ☺♥⌂")
    // A title as a tracker's user decorated it, read up to its first zero and no further.
    let title: [UInt8] = [0xC4, 0x7B, 0x9F, 0x6F, 0x72, 0x65, 0x76, 0x65, 0x72, 0x7D, 0xC4, 0x20, 0x00, 0x41]
    #expect(ByteReader(title).dos(at: 0, length: 20) == "─{ƒorever}─")
    #expect(ByteReader(title).dos(at: 12, length: 20) == "")
    #expect(ByteReader(title).dos(at: 9, length: -3) == "")
    // In an encoding that has no character for a byte, a field is read as plain letters.
    #expect(ByteReader([0x41, 0x81, 0x42]).encoded(at: 0, length: 3, as: .windows1252) == "A B")
}

@Test func textIsTrimmedAsFoundationTrimsIt() {
    // Every character there is, alone between two letters and at each end of a word.
    for value in UInt32(0) ... 0x10FFFF {
        guard let scalar = Unicode.Scalar(value) else { continue }
        var text = String.UnicodeScalarView()
        text.append(scalar); text.append("a"); text.append(scalar); text.append("b"); text.append(scalar)
        let string = String(text)
        if string.trimmed() != string.trimmingCharacters(in: .whitespaces)
            || string.trimmed(newlines: true) != string.trimmingCharacters(in: .whitespacesAndNewlines) {
            Issue.record("U+\(String(value, radix: 16)) is trimmed differently")
        }
    }
    #expect("  \t a b \u{A0}".trimmed() == "a b")
    #expect(" \n".trimmed() == "\n")
    #expect(" \n".trimmed(newlines: true) == "")
}

@Test func numbersAreWrittenAsPrintfWritesThem() {
    // The two things the library writes this way, over everything a VTX or YM file can ask for:
    // a chip clock in megahertz to four digits (the file gives hertz in 32 bits), and a frame rate.
    func checkClock(_ megahertz: Double) {
        if significant(megahertz, digits: 4) != String(format: "%.4g", megahertz) {
            Issue.record("\(megahertz): \(significant(megahertz, digits: 4)), not \(String(format: "%.4g", megahertz))")
        }
    }
    func checkRate(_ hertz: Double) {
        if significant(hertz) != String(format: "%g", hertz) {
            Issue.record("\(hertz): \(significant(hertz)), not \(String(format: "%g", hertz))")
        }
    }
    for hertz in stride(from: 0, through: 4_500_000, by: 25) { checkClock(Double(hertz) / 1_000_000) }
    for hertz in stride(from: 0, through: Int(UInt32.max), by: 99_991) { checkClock(Double(hertz) / 1_000_000) }
    for hertz in [1_773_400, 1_750_000, 2_000_000, 1_000_000, 1_789_772, 3_546_900, 3_579_545, 1_773_500, 999_950, 999_949, 99, 100, 101, Int(UInt32.max)] {
        checkClock(Double(hertz) / 1_000_000)
    }
    for rate in 0 ... 65535 { checkRate(Double(rate)) }
    for thousandths in stride(from: 1, through: 400_000, by: 7) { checkRate(Double(thousandths) / 1000) }
    for value in [0.0001, 0.00012345, 0.5, 0.99995, 0.999949, 9.9995, 9.99949, 99999.5, 999999, 48.828125, 50.0, 59.94] { checkRate(value) }
}
