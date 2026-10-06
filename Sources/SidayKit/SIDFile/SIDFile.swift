// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A parsed PSID/RSID file. Layout per HVSC's SID_file_format.txt.
struct SIDFile {
    enum Clock { case unknown, pal, ntsc, both }

    var isRSID = false
    var version = 0
    var loadAddress = 0
    var initAddress = 0
    var playAddress = 0
    var songs = 1
    var startSong = 1
    var speed: UInt32 = 0
    var name = "", author = "", released = ""
    var flags = 0
    var relocStartPage = 0
    var relocPages = 0
    /// The C64 memory image, without the load address.
    var image: [UInt8] = []

    var clock: Clock {
        switch (flags >> 2) & 3 {
        case 1: .pal
        case 2: .ntsc
        case 3: .both
        default: .unknown
        }
    }

    /// Model the tune asks for; "either" and "unknown" fall back to the 6581.
    var model: SIDModel { (flags >> 4) & 3 == 2 ? .mos8580 : .mos6581 }
    var isMUS: Bool { flags & 1 != 0 }
    var needsBASIC: Bool { isRSID && flags & 2 != 0 }
    var playSIDSpecific: Bool { !isRSID && flags & 2 != 0 }

    /// True when the given song (zero-based) is driven by the CIA timer rather than the vertical blank.
    func usesCIA(song: Int) -> Bool {
        let bit: Int
        if version < 2 || playSIDSpecific {
            bit = song % 32
        } else {
            bit = min(song, 31)
        }
        return speed & (1 << UInt32(bit)) != 0
    }

    init(_ data: [UInt8]) throws {
        let r = ByteReader(data)
        let magic = r.ascii(at: 0, length: 4)
        guard magic == "PSID" || magic == "RSID" else { throw TuneError.malformed("not a SID file") }
        isRSID = magic == "RSID"
        version = r.u16be(4)
        let dataOffset = r.u16be(6)
        guard dataOffset >= 0x76, dataOffset < r.count else { throw TuneError.malformed("bad SID header") }
        loadAddress = r.u16be(8)
        initAddress = r.u16be(0x0A)
        playAddress = r.u16be(0x0C)
        songs = max(1, r.u16be(0x0E))
        startSong = min(max(1, r.u16be(0x10)), songs)
        speed = UInt32(truncatingIfNeeded: r.u32be(0x12))
        func text(_ offset: Int) -> String {
            var end = offset
            while end < offset + 32, r[end] != 0 { end += 1 }
            return (TextEncoding.windows1252.decode(r.data[offset ..< min(end, r.count)]) ?? "").trimmed()
        }
        name = text(0x16)
        author = text(0x36)
        released = text(0x56)
        if version >= 2, dataOffset >= 0x7C {
            flags = r.u16be(0x76)
            relocStartPage = Int(r[0x78])
            relocPages = Int(r[0x79])
        }
        var start = dataOffset
        if loadAddress == 0 {
            loadAddress = r.u16le(start)
            start += 2
        }
        guard start < r.count else { throw TuneError.malformed("SID file has no data") }
        image = Array(r.data[start...])
        if initAddress == 0 { initAddress = loadAddress }
    }
}

/// HVSC's Songlengths.md5: play time of every subtune, keyed by the MD5 of the whole SID file.
/// Each entry is preceded by a comment line with the tune's path inside HVSC, which serves as a second
/// key for copies of a tune from a different HVSC release.
public final class SongLengthDatabase: Sendable {
    private let byHash: [String: [Double]]
    private let byPath: [String: [Double]]

    /// - Parameter data: the contents of a `Songlengths.md5` file.
    public init(_ data: [UInt8]) {
        (byHash, byPath) = Self.parse(data)
    }

    /// True when the file gave no tune's length: it was not a song-length database.
    public var isEmpty: Bool { byHash.isEmpty }

    /// Reads the database's text, which is ISO Latin-1. It is five megabytes, and is read as bytes: taken
    /// apart as a `String`, a line and a character at a time, it held up the first SID tune of every run
    /// by a third of a second.
    static func parse(_ data: [UInt8]) -> (byHash: [String: [Double]], byPath: [String: [Double]]) {
        var hashes: [String: [Double]] = [:]
        var paths: [String: [Double]] = [:]
        hashes.reserveCapacity(data.count / 80)
        paths.reserveCapacity(data.count / 80)
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func text(_ range: Range<Int>) -> String {
                let slice = UnsafeRawBufferPointer(rebasing: bytes[range])
                if slice.allSatisfy({ $0 < 0x80 }) { return String(decoding: slice, as: UTF8.self) }
                return TextEncoding.latin1.decode(slice) ?? ""
            }
            var currentPath: Range<Int>?
            var lengths: [Double] = []
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count, !Self.isNewline(bytes[end]) { end += 1 }
                let line = start ..< end
                start = end + 1
                guard !line.isEmpty else { continue }
                if line.count >= 2, bytes[line.lowerBound] == UInt8(ascii: ";"), bytes[line.lowerBound + 1] == UInt8(ascii: " ") {
                    var from = line.lowerBound + 2, to = line.upperBound
                    while from < to, Self.isSpace(bytes[from]) { from += 1 }
                    while to > from, Self.isSpace(bytes[to - 1]) { to -= 1 }
                    currentPath = from ..< to
                } else if bytes[line.lowerBound] != UInt8(ascii: "["), let equals = bytes[line].firstIndex(of: UInt8(ascii: "=")) {
                    lengths.removeAll(keepingCapacity: true)
                    var from = equals + 1
                    while from < line.upperBound {
                        var to = from
                        while to < line.upperBound, bytes[to] != UInt8(ascii: " ") { to += 1 }
                        if to > from, let length = seconds(UnsafeRawBufferPointer(rebasing: bytes[from ..< to])) { lengths.append(length) }
                        from = to + 1
                    }
                    guard !lengths.isEmpty else { continue }
                    hashes[text(line.lowerBound ..< equals)] = lengths
                    if let currentPath { paths[text(currentPath).lowercased()] = lengths }
                    currentPath = nil
                }
            }
        }
        return (hashes, paths)
    }

    @inline(__always) private static func isNewline(_ byte: UInt8) -> Bool {
        byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C || byte == 0x85
    }

    @inline(__always) private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0xA0
    }

    /// "m:ss" or "m:ss.SSS".
    private static func seconds(_ text: UnsafeRawBufferPointer) -> Double? {
        var parts = 0
        var minutes = 0.0, seconds = 0.0
        var from = 0
        while from < text.count {
            var to = from
            while to < text.count, text[to] != UInt8(ascii: ":") { to += 1 }
            if to > from {
                guard parts < 2, let value = number(UnsafeRawBufferPointer(rebasing: text[from ..< to])) else { return nil }
                if parts == 0 { minutes = value } else { seconds = value }
                parts += 1
            }
            from = to + 1
        }
        return parts == 2 ? minutes * 60 + seconds : nil
    }

    /// The value `Double` would read from the text. Plain digits with or without a decimal point, which
    /// is all the database has, are worked out here: a whole number divided by a power of ten gives the
    /// same result, to the last bit, as reading the decimal.
    private static func number(_ text: UnsafeRawBufferPointer) -> Double? {
        var digits: UInt64 = 0
        var scale = 1.0
        var seenPoint = false, seenDigit = false
        var simple = text.count <= 15
        for byte in text where simple {
            if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                digits = digits * 10 + UInt64(byte - UInt8(ascii: "0"))
                if seenPoint { scale *= 10 }
                seenDigit = true
            } else if byte == UInt8(ascii: "."), !seenPoint {
                seenPoint = true
            } else {
                simple = false
            }
        }
        if simple, seenDigit { return Double(digits) / scale }
        return Double(String(decoding: text, as: UTF8.self))
    }

    /// The lengths of a SID file's songs in seconds, in order.
    /// - Parameters:
    ///   - file: the whole SID file, which is looked up by its contents.
    ///   - path: where it is kept, if known. A tune from another HVSC release than the database's is found
    ///     by its place in the collection, from the `DEMOS`, `GAMES` or `MUSICIANS` folder down.
    public func lengths(of file: [UInt8], path: String?) -> [Double]? {
        if let found = byHash[MD5.hex(file)] { return found }
        guard let path else { return nil }
        let components = path.split(separator: "/")
        guard let top = components.lastIndex(where: { ["DEMOS", "GAMES", "MUSICIANS"].contains($0) }) else { return nil }
        return byPath[("/" + components[top...].joined(separator: "/")).lowercased()]
    }
}
