// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Written against the AmigaDOS executable format as Commodore's AmigaDOS Manual describes it (its
// chapter on the format of object and load files), as far as a player's or a tune's file uses it.

/// An AmigaDOS executable, a "hunk file", as the system's LoadSeg puts it into memory: its segments
/// (hunks of code, of data, and of BSS, which is only room) one after another, each at an address of
/// its own, and every place its relocation tables name made to hold the address of the segment it
/// points into. The players of DeliTracker and EaglePlayer are such files, and so are some tunes.
///
/// What is loaded is the first and only program of the file: overlays and libraries resident in it are
/// refused, and debugging information and symbols are passed over.
enum AmigaHunks {
    /// A segment as it was put into memory.
    struct Segment: Equatable {
        enum Kind: Equatable { case code, data, bss }
        var kind: Kind
        var address: UInt32
        /// Its size in memory, from the file's header (which may be more than it holds).
        var size: Int
    }

    private static let header: UInt32 = 0x3F3
    private static let unit: UInt32 = 0x3E7, name: UInt32 = 0x3E8
    private static let code: UInt32 = 0x3E9, data: UInt32 = 0x3EA, bss: UInt32 = 0x3EB
    private static let reloc32: UInt32 = 0x3EC, reloc16: UInt32 = 0x3ED, reloc8: UInt32 = 0x3EE
    private static let ext: UInt32 = 0x3EF, symbol: UInt32 = 0x3F0, debug: UInt32 = 0x3F1, end: UInt32 = 0x3F2
    private static let overlay: UInt32 = 0x3F5, `break`: UInt32 = 0x3F6
    /// The short form of relocation that version 36 of the system's LoadSeg reads, by both its numbers.
    private static let reloc32Short: UInt32 = 0x3FC, dosReloc32Short: UInt32 = 0x3F7

    /// True for a file that begins as a hunk file does.
    static func isOne(_ file: [UInt8]) -> Bool {
        file.count >= 24 && long(file, 0) == header
    }

    /// The sizes of the file's segments in memory, in bytes, from its header.
    static func sizes(_ file: [UInt8]) throws(TuneError) -> [Int] {
        var at = 0
        return try readHeader(file, &at)
    }

    /// Loads the file into `memory` (of `capacity` bytes), its first segment at `address` and each of the
    /// others after the one before, on an eight-byte boundary. The memory the segments take is cleared
    /// first. Throws for a file that is not one, is cut short, or would not fit.
    static func load(_ file: [UInt8], at address: UInt32, into memory: UnsafeMutablePointer<UInt8>,
                     capacity: Int) throws(TuneError) -> [Segment]
    {
        var at = 0
        let sizes = try readHeader(file, &at)
        var segments: [Segment] = []
        var next = Int(address)
        for size in sizes {
            guard next + size <= capacity else { throw .malformed("the program does not fit in the machine's memory") }
            segments.append(Segment(kind: .bss, address: UInt32(next), size: size))
            memory.advanced(by: next).initialize(repeating: 0, count: size)
            next = (next + size + 7) & ~7
        }
        var current = -1
        var ended = true
        while at + 4 <= file.count {
            let type = long(file, at) & 0x3FFF_FFFF
            at += 4
            switch type {
            case code, data, bss:
                current += 1
                guard current < segments.count else { throw .malformed("the program has more hunks than it says") }
                let longs = try counted(file, &at, mask: 0x3FFF_FFFF)
                segments[current].kind = type == code ? .code : type == data ? .data : .bss
                ended = false
                guard type != bss else { break }
                let bytes = longs * 4
                guard at + bytes <= file.count else { throw .malformed("the program's file is cut short") }
                guard bytes <= segments[current].size else { throw .malformed("a hunk holds more than the header gives it") }
                let base = Int(segments[current].address)
                for i in 0 ..< bytes { memory[base + i] = file[at + i] }
                at += bytes
            case reloc32:
                try relocate(file, &at, segments, current, memory, short: false)
            case reloc32Short, dosReloc32Short:
                try relocate(file, &at, segments, current, memory, short: true)
                // (The short tables are padded to a long.)
                at = (at + 3) & ~3
            case symbol:
                // Names, each a long of its length in longs and that many, then a long of its value.
                while true {
                    let longs = Int(try count(file, &at) & 0x00FF_FFFF)
                    if longs == 0 { break }
                    at += longs * 4 + 4
                    guard at <= file.count else { throw .malformed("the program's file is cut short") }
                }
            case debug, name, unit:
                let longs = try counted(file, &at)
                at += longs * 4
                guard at <= file.count else { throw .malformed("the program's file is cut short") }
            case end, `break`:
                ended = true
            case reloc16, reloc8, ext, overlay:
                throw .unsupported("an AmigaDOS program that needs linking or overlays")
            default:
                throw .malformed("an AmigaDOS program with a hunk of an unknown kind")
            }
            if type == `break` { break }
        }
        guard current + 1 == segments.count, ended else { throw .malformed("the program's file is cut short") }
        return segments
    }

    /// The header: no resident libraries, the number of segments, and each one's size (with its kind of
    /// memory in the size's top two bits, and when both are set, a long more of it).
    private static func readHeader(_ file: [UInt8], _ at: inout Int) throws(TuneError) -> [Int] {
        guard isOne(file) else { throw .malformed("not an AmigaDOS program") }
        at = 4
        guard try count(file, &at) == 0 else { throw .unsupported("an AmigaDOS program with resident libraries") }
        let total = try counted(file, &at)
        let first = try counted(file, &at), last = try counted(file, &at)
        guard total > 0, total <= 256, first == 0, last >= first, last - first + 1 == total else {
            throw .malformed("an AmigaDOS program whose header is not one")
        }
        var sizes: [Int] = []
        for _ in 0 ..< total {
            let word = try count(file, &at)
            if word & 0xC000_0000 == 0xC000_0000 { _ = try count(file, &at) }
            sizes.append(Int(min(word & 0x3FFF_FFFF, 0x20_0000)) * 4)
        }
        guard sizes.reduce(0, +) <= 0x80_0000 else { throw .malformed("an AmigaDOS program larger than any machine's memory") }
        return sizes
    }

    /// A relocation table: for each segment pointed into, its number and the places in the current
    /// segment that point into it, each made to hold that segment's address added to what it holds.
    private static func relocate(_ file: [UInt8], _ at: inout Int, _ segments: [Segment], _ current: Int,
                                 _ memory: UnsafeMutablePointer<UInt8>, short: Bool) throws(TuneError)
    {
        guard current >= 0 else { throw .malformed("an AmigaDOS program that relocates before its first hunk") }
        func next() throws(TuneError) -> Int {
            if short {
                guard at + 2 <= file.count else { throw .malformed("the program's file is cut short") }
                defer { at += 2 }
                return Int(file[at]) << 8 | Int(file[at + 1])
            }
            return try counted(file, &at)
        }
        while true {
            let places = try next()
            if places == 0 { return }
            let target = try next()
            guard target < segments.count else {
                throw .malformed("an AmigaDOS program that points into a hunk it does not have")
            }
            let add = segments[target].address
            let segment = segments[current]
            for _ in 0 ..< places {
                let offset = try next()
                guard offset + 4 <= segment.size else { throw .malformed("an AmigaDOS program that relocates outside its hunk") }
                let p = Int(segment.address) + offset
                let value = UInt32(memory[p]) << 24 | UInt32(memory[p + 1]) << 16
                    | UInt32(memory[p + 2]) << 8 | UInt32(memory[p + 3])
                let moved = value &+ add
                memory[p] = UInt8(truncatingIfNeeded: moved >> 24)
                memory[p + 1] = UInt8(truncatingIfNeeded: moved >> 16)
                memory[p + 2] = UInt8(truncatingIfNeeded: moved >> 8)
                memory[p + 3] = UInt8(truncatingIfNeeded: moved)
            }
        }
    }

    private static func long(_ file: [UInt8], _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= file.count else { return 0 }
        return UInt32(file[at]) << 24 | UInt32(file[at + 1]) << 16 | UInt32(file[at + 2]) << 8 | UInt32(file[at + 3])
    }

    /// A count, or a place, no more than the file could hold (as an Int on any machine).
    private static func counted(_ file: [UInt8], _ at: inout Int, mask: UInt32 = 0xFFFF_FFFF) throws(TuneError) -> Int {
        Int(min(try count(file, &at) & mask, UInt32(min(file.count, 0x1000_0000))))
    }

    private static func count(_ file: [UInt8], _ at: inout Int) throws(TuneError) -> UInt32 {
        guard at + 4 <= file.count else { throw .malformed("the program's file is cut short") }
        defer { at += 4 }
        return long(file, at)
    }
}
