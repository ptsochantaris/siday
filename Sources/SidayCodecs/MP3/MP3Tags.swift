// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The skipping of tags is derived from minimp3_ex.h, by lieff (https://github.com/lieff/minimp3),
// dedicated to the public domain under CC0.

import SidayFoundation

/// The tags an MP3 file may have about its stream: an ID3v2 tag at the start, and an ID3v1 tag
/// (perhaps with its "TAG+" extension) or an APE tag at the end. What minimp3_ex.h skips of them, and
/// the title and artist from them.
struct MP3Tags {
    var title = "", artist = ""

    /// The title and artist from the ID3v2 tag (TIT2 and TPE1, or TT2 and TP1 in version 2.2), else from
    /// the ID3v1 tag.
    init(_ file: [UInt8]) {
        if Self.id3v2Size(file) != 0 {
            let frames = Self.id3v2Frames(file)
            title = frames.title ?? ""
            artist = frames.artist ?? ""
        }
        let count = file.count
        if count >= 128, file[count - 128] == 0x54, file[count - 127] == 0x41, file[count - 126] == 0x47 {
            if title.isEmpty { title = Self.id3v1Text(file[count - 125 ..< count - 95]) }
            if artist.isEmpty { artist = Self.id3v1Text(file[count - 95 ..< count - 65]) }
        }
    }

    /// mp3dec_skip_id3v2: the size of the ID3v2 tag at the start, with its footer, or 0 if there is
    /// none (or its header is not one that minimp3 takes as a tag).
    static func id3v2Size(_ buf: [UInt8]) -> Int {
        guard buf.count >= 10, buf[0] == 0x49, buf[1] == 0x44, buf[2] == 0x33 else { return 0 }
        if buf[5] & 15 != 0 || buf[6] & 0x80 != 0 || buf[7] & 0x80 != 0 || buf[8] & 0x80 != 0 || buf[9] & 0x80 != 0 {
            return 0
        }
        var size = (Int(buf[6] & 0x7F) << 21 | Int(buf[7] & 0x7F) << 14 | Int(buf[8] & 0x7F) << 7 | Int(buf[9] & 0x7F)) + 10
        if buf[5] & 16 != 0 {
            size += 10 // footer
        }
        return size
    }

    /// mp3dec_skip_id3v1: `size` bytes from `start` made fewer by an ID3v1 tag at their end (and the
    /// "TAG+" extension before it), and then an APE tag.
    static func skipID3v1(_ buf: [UInt8], _ start: Int, _ size: inout Int) {
        func matches(_ at: Int, _ text: [UInt8]) -> Bool {
            for (i, byte) in text.enumerated() where buf[start + at + i] != byte { return false }
            return true
        }
        var bufSize = size
        if bufSize >= 128, matches(bufSize - 128, [0x54, 0x41, 0x47]) {
            bufSize -= 128
            if bufSize >= 227, matches(bufSize - 227, [0x54, 0x41, 0x47, 0x2B]) {
                bufSize -= 227
            }
        }
        if bufSize > 32, matches(bufSize - 32, [0x41, 0x50, 0x45, 0x54, 0x41, 0x47, 0x45, 0x58]) {
            bufSize -= 32
            let tag = start + bufSize + 8 + 4
            let tagSize = UInt32(buf[tag + 3]) << 24 | UInt32(buf[tag + 2]) << 16 | UInt32(buf[tag + 1]) << 8 | UInt32(buf[tag])
            if UInt64(bufSize) >= UInt64(tagSize) {
                bufSize -= Int(tagSize)
            }
        }
        size = bufSize
    }

    /// An ID3v1 field: Latin-1, to its first zero, without the spaces it is padded with.
    private static func id3v1Text(_ bytes: ArraySlice<UInt8>) -> String {
        let text = bytes.prefix { $0 != 0 }
        return (TextEncoding.latin1.decode(text) ?? "").trimmed()
    }

    /// The text of the title and artist frames of the ID3v2 tag at the start, versions 2.2, 2.3 and 2.4.
    private static func id3v2Frames(_ file: [UInt8]) -> (title: String?, artist: String?) {
        let version = file[3], flags = file[5]
        guard version >= 2, version <= 4 else { return (nil, nil) }
        let tagEnd = min(file.count, id3v2Size(file) - (flags & 16 != 0 ? 10 : 0))
        guard tagEnd > 10 else { return (nil, nil) }
        var body = Array(file[10 ..< tagEnd])
        // Unsynchronisation of the whole tag, in versions 2.2 and 2.3: a zero after every 0xFF.
        if flags & 0x80 != 0, version < 4 {
            body = resynchronised(body)
        }
        var at = 0
        if flags & 0x40 != 0 {
            if version == 2 { return (nil, nil) } // compression, which no one used
            guard body.count >= 4 else { return (nil, nil) }
            // (In 64 bits: a size of four bytes may be more than an Int of 32 bits holds.)
            let size = version == 3
                ? (Int64(body[0]) << 24 | Int64(body[1]) << 16 | Int64(body[2]) << 8 | Int64(body[3])) + 4
                : Int64(body[0] & 0x7F) << 21 | Int64(body[1] & 0x7F) << 14 | Int64(body[2] & 0x7F) << 7 | Int64(body[3] & 0x7F)
            guard size <= Int64(body.count) else { return (nil, nil) }
            at = Int(size)
        }

        var title: String?, artist: String?
        let headerSize = version == 2 ? 6 : 10
        while at + headerSize <= body.count, body[at] != 0 {
            let id: [UInt8], size: Int
            var frameFlags: UInt8 = 0
            if version == 2 {
                id = Array(body[at ..< at + 3])
                size = Int(body[at + 3]) << 16 | Int(body[at + 4]) << 8 | Int(body[at + 5])
            } else {
                id = Array(body[at ..< at + 4])
                // (Each byte by itself: a size of four bytes may be more than an Int of 32 bits holds.)
                let b0 = Int(body[at + 4]), b1 = Int(body[at + 5]), b2 = Int(body[at + 6]), b3 = Int(body[at + 7])
                if version == 4 {
                    size = (b0 & 0x7F) << 21 | (b1 & 0x7F) << 14 | (b2 & 0x7F) << 7 | (b3 & 0x7F)
                } else {
                    size = b0 >= 0x80 ? Int.max : b0 << 24 | b1 << 16 | b2 << 8 | b3
                }
                frameFlags = body[at + 9]
            }
            let dataStart = at + headerSize
            guard size <= body.count - dataStart else { break }
            var data = Array(body[dataStart ..< dataStart + size])
            at = dataStart + size

            let isTitle = id == (version == 2 ? [0x54, 0x54, 0x32] : [0x54, 0x49, 0x54, 0x32])
            let isArtist = id == (version == 2 ? [0x54, 0x50, 0x31] : [0x54, 0x50, 0x45, 0x31])
            guard isTitle || isArtist else { continue }
            if version == 3 {
                if frameFlags & 0xC0 != 0 { continue } // compressed or encrypted
                if frameFlags & 0x20 != 0 { data = Array(data.dropFirst()) } // a group's number
            } else if version == 4 {
                if frameFlags & 0x0C != 0 { continue } // compressed or encrypted
                if frameFlags & 0x40 != 0 { data = Array(data.dropFirst()) } // a group's number
                if frameFlags & 0x02 != 0 { data = resynchronised(data) }
                if frameFlags & 0x01 != 0 { data = Array(data.dropFirst(4)) } // the data's length
            }
            let text = Self.text(data)
            if isTitle, title == nil { title = text } else if isArtist, artist == nil { artist = text }
        }
        return (title, artist)
    }

    /// Bytes without the zero that unsynchronisation put after each 0xFF.
    private static func resynchronised(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            out.append(bytes[i])
            if bytes[i] == 0xFF, i + 1 < bytes.count, bytes[i + 1] == 0 { i += 1 }
            i += 1
        }
        return out
    }

    /// A text frame's first string: its first byte says how it is encoded, Latin-1 (0), UTF-16 with a
    /// byte order mark (1), UTF-16 big-endian (2) or UTF-8 (3).
    private static func text(_ data: [UInt8]) -> String? {
        guard let encoding = data.first else { return nil }
        let bytes = data.dropFirst()
        switch encoding {
        case 0:
            return TextEncoding.latin1.decode(bytes.prefix { $0 != 0 })?.trimmed()
        case 3:
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self).trimmed()
        case 1, 2:
            var units: [UInt16] = []
            var bigEndian = encoding == 2
            var i = bytes.startIndex
            while i + 1 < bytes.endIndex {
                let first = bytes[i], second = bytes[i + 1]
                i += 2
                if encoding == 1, units.isEmpty, first == 0xFE, second == 0xFF { bigEndian = true; continue }
                if encoding == 1, units.isEmpty, first == 0xFF, second == 0xFE { bigEndian = false; continue }
                let unit = bigEndian ? UInt16(first) << 8 | UInt16(second) : UInt16(second) << 8 | UInt16(first)
                if unit == 0 { break }
                units.append(unit)
            }
            var scalars = String.UnicodeScalarView()
            var k = 0
            while k < units.count {
                var value = UInt32(units[k])
                if value >= 0xD800, value < 0xDC00, k + 1 < units.count, units[k + 1] >= 0xDC00, units[k + 1] < 0xE000 {
                    value = 0x10000 + ((value - 0xD800) << 10) + (UInt32(units[k + 1]) - 0xDC00)
                    k += 1
                }
                scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
                k += 1
            }
            return String(scalars).trimmed()
        default:
            return nil
        }
    }
}
