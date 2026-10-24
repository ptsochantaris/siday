// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from libopenmpt (`soundlib/Load_mo3.cpp`), Copyright (c) 2004-2026 OpenMPT Project
// Developers and Contributors, used under the BSD 3-Clause licence (see THIRD-PARTY.md), whose MO3
// unpacking is based on UNMO3 by Laurent Clévy, relicensed to BSD with his permission.

/// A window on bytes, read as libopenmpt's `FileReader` reads them: a read that would go past the end
/// reads nothing, gives 0 and leaves the place where it was; a chunk asked for longer than what is
/// left is what is left.
struct MO3Bytes {
    let data: [UInt8]
    let start: Int
    let end: Int
    var pos: Int

    init(_ data: [UInt8]) {
        self.data = data
        start = 0
        end = data.count
        pos = 0
    }

    init(_ data: [UInt8], from start: Int, to end: Int) {
        self.data = data
        self.start = start
        self.end = end
        pos = start
    }

    static let empty = MO3Bytes([])

    var length: Int { end - start }
    var bytesLeft: Int { end - pos }
    /// Where the cursor is, counted from the start of the window (`FileReader::GetPosition`).
    var position: Int { pos - start }

    func canRead(_ count: Int) -> Bool { count >= 0 && end - pos >= count }
    /// A length from the file, which may be more than an `Int` holds where `Int` is 32 bits.
    func canRead(_ count: UInt32) -> Bool { UInt64(count) <= UInt64(end - pos) }

    mutating func rewind() { pos = start }

    /// `FileReader::Seek`: false, and no move, past the end.
    @discardableResult
    mutating func seek(_ offset: Int) -> Bool {
        guard offset >= 0, offset <= end - start else { return false }
        pos = start + offset
        return true
    }

    /// `FileReader::Skip`: past the end, the cursor goes to the end and the answer is false.
    @discardableResult
    mutating func skip(_ count: Int) -> Bool {
        guard canRead(count) else {
            pos = end
            return false
        }
        pos += count
        return true
    }

    mutating func u8() -> UInt8 {
        guard pos < end else { return 0 }
        pos += 1
        return data[pos - 1]
    }

    /// `FileReader::Read` of one byte, which says whether there was one.
    mutating func byte() -> UInt8? {
        guard pos < end else { return nil }
        pos += 1
        return data[pos - 1]
    }

    mutating func u16() -> UInt16 {
        guard canRead(2) else { return 0 }
        pos += 2
        return UInt16(data[pos - 2]) | UInt16(data[pos - 1]) << 8
    }

    mutating func u32() -> UInt32 {
        guard canRead(4) else { return 0 }
        pos += 4
        return UInt32(data[pos - 4]) | UInt32(data[pos - 3]) << 8 | UInt32(data[pos - 2]) << 16 | UInt32(data[pos - 1]) << 24
    }

    mutating func i16() -> Int16 { Int16(bitPattern: u16()) }
    mutating func i32() -> Int32 { Int32(bitPattern: u32()) }

    /// The bytes of a structure of `count` bytes, all of them or none (`FileReader::ReadStruct`).
    mutating func structure(_ count: Int) -> MO3Bytes? {
        guard canRead(count) else { return nil }
        pos += count
        return MO3Bytes(data, from: pos - count, to: pos)
    }

    /// `FileReader::ReadChunk`: the next `count` bytes, or as many as there are.
    mutating func chunk(_ count: Int) -> MO3Bytes {
        let taken = max(0, min(count, end - pos))
        pos += taken
        return MO3Bytes(data, from: pos - taken, to: pos)
    }

    mutating func chunk(_ count: UInt32) -> MO3Bytes {
        chunk(UInt64(count) < UInt64(end - pos) ? Int(count) : end - pos)
    }

    /// `FileReader::ReadNullString`: the bytes up to a 0, which is passed over, or to the end.
    mutating func nullString() -> [UInt8] {
        var text: [UInt8] = []
        while pos < end {
            let b = data[pos]
            pos += 1
            if b == 0 { break }
            text.append(b)
        }
        return text
    }

    /// `FileReader::ReadMagic`: the bytes are passed over only if they are there.
    mutating func magic(_ text: StaticString) -> Bool {
        let count = text.utf8CodeUnitCount
        guard canRead(count) else { return false }
        let p = text.utf8Start
        for i in 0 ..< count where data[pos + i] != p[i] { return false }
        pos += count
        return true
    }

    /// All the bytes of the window, from its start.
    var all: ArraySlice<UInt8> { data[start ..< end] }
    /// The bytes from the cursor to the end.
    var rest: ArraySlice<UInt8> { data[pos ..< end] }
}

extension UInt32 {
    /// `MagicLE`: four characters as a little-endian number, as they are in the file.
    init(magic text: StaticString) {
        let p = text.utf8Start
        self = UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
    }
}

/// A file being written, in little-endian order.
struct MO3Writer {
    var bytes: [UInt8] = []

    var count: Int { bytes.count }

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func i8(_ v: Int8) { bytes.append(UInt8(bitPattern: v)) }
    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }
    mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 24))
    }
    mutating func u16be(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v))
    }
    mutating func text(_ s: StaticString) {
        let p = s.utf8Start
        for i in 0 ..< s.utf8CodeUnitCount { bytes.append(p[i]) }
    }
    mutating func append<S: Sequence>(_ s: S) where S.Element == UInt8 { bytes.append(contentsOf: s) }
    mutating func zeros(_ n: Int) { if n > 0 { bytes.append(contentsOf: repeatElement(0, count: n)) } }
    /// A string in a field of `size` bytes, cut to fit, the rest filled with `pad`.
    mutating func field(_ s: [UInt8], _ size: Int, pad: UInt8 = 0, terminated: Bool = false) {
        let n = min(s.count, terminated ? size - 1 : size)
        bytes.append(contentsOf: s[0 ..< n])
        if size > n { bytes.append(contentsOf: repeatElement(pad, count: size - n)) }
    }
    mutating func put16(_ v: UInt16, at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: v)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }
    mutating func put32(_ v: UInt32, at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: v)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: v >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: v >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }
}
