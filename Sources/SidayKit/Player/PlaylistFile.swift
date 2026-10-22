// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A playlist: a file that is not a tune but a list of tunes, to be played in the order it has them.
///
/// Two kinds are read, both text. Ay_Emul's (AYL) is a line that says what the file is, and then the
/// tunes, one to a line, each by its path from the folder the list is in, written as Windows writes
/// one. A tune may be followed by what Ay_Emul knew about it, between a line that is `<` and a line
/// that is `>`: its name and author, how long it is, the chip it is to be played on. Of those only
/// the comment is kept, to be shown with the tune: the rest is what the tune's own file says, or what
/// Ay_Emul needed to find a module inside a larger file, which is found here without being told.
///
/// The other is M3U, the plainest of all: a tune's path on each line, and lines that begin with `#`,
/// which are about the list or the tune after them and are passed over (a tune's name and length are
/// read from its own file). It is how the packs of VGM files give the order of a game's music.
///
/// Like the rest of the library this reads no files. Whoever has the list finds its tunes: on a disk
/// by following each path (`Entry.path`), and where files are known only by their names, as in a
/// browser, with a `FileFinder`.
public struct PlaylistFile: Sendable {
    public struct Entry: Sendable, Equatable {
        /// Where the tune is, from the folder the list is in: the names of the folders on the way and
        /// then the file's own, with ".." for each step up.
        public var path: [String]
        /// True if the path is not from the list's folder but from the top of the disk.
        public var absolute = false
        /// What the list says about the tune; empty if it says nothing.
        public var note = ""

        public init(path: [String], absolute: Bool = false, note: String = "") {
            self.path = path
            self.absolute = absolute
            self.note = note
        }

        /// The path as one piece of text.
        public var name: String {
            (absolute ? "/" : "") + path.joined(separator: "/")
        }

        /// What comes after the last full stop of the file's name; empty if it has none.
        public var fileExtension: String {
            guard let file = path.last else { return "" }
            let bytes = Array(file.utf8)
            guard let stop = bytes.lastIndex(of: 0x2E) else { return "" }
            return String(decoding: bytes[(stop + 1)...], as: UTF8.self)
        }
    }

    /// The kinds of playlist that are read.
    public enum Kind: Sendable {
        /// Ay_Emul's.
        case ayl
        /// The plain list of paths that players on every kind of computer read and write, M3U, and
        /// M3U8, which is the same in Unicode.
        case m3u

        /// Every extension a playlist's file can have, in lower case.
        public static let fileExtensions = ["ayl", "m3u", "m3u8"]

        /// The kind of playlist a file of this extension, in any case, is; nil if it is none.
        public init?(fileExtension: String) {
            switch fileExtension.lowercased() {
            case "ayl": self = .ayl
            case "m3u", "m3u8": self = .m3u
            default: return nil
            }
        }
    }

    public private(set) var entries: [Entry] = []

    /// True if a file of this extension, in any case, is a playlist.
    public static func reads(fileExtension: String) -> Bool {
        Kind(fileExtension: fileExtension) != nil
    }

    /// What every list begins with, before the number of the version of the format it is in.
    private static let heading = Array("ZX Spectrum Sound Chip Emulator Play List File".utf8)
    private static let comment = Array("Comment=".utf8)

    /// The list in a file's bytes; nil if they are not a list of that kind.
    public init?(_ data: [UInt8], kind: Kind = .ayl) {
        var data = data[...]
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        if kind == .m3u {
            readM3U(data)
            return
        }
        // A list is in Unicode, or, if it is an old one from Russia, as most are, in the Cyrillic of
        // the Windows of its day. Which, is decided for the whole of it.
        let unicode = Self.isUnicode(data)
        func text(_ bytes: ArraySlice<UInt8>) -> String {
            unicode ? String(decoding: bytes, as: UTF8.self) : Self.cyrillic(bytes)
        }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).map { line in
            line.last == 0x0D ? line.dropLast() : line
        }[...]
        guard let first = lines.popFirst(), first.starts(with: Self.heading) else { return nil }
        var described = false
        for line in lines {
            if line.elementsEqual([0x3C]) {
                described = true
            } else if line.elementsEqual([0x3E]) {
                described = false
            } else if described {
                // What is said before the first tune is said of them all, and is Ay_Emul's settings.
                if line.starts(with: Self.comment), !entries.isEmpty, entries[entries.count - 1].note.isEmpty {
                    entries[entries.count - 1].note = Self.tidy(text(line.dropFirst(Self.comment.count)))
                }
            } else {
                let parts = line.split(whereSeparator: { $0 == 0x2F || $0 == 0x5C }).map { text($0) }.filter { $0 != "." }
                guard !parts.isEmpty, !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { continue }
                entries.append(Entry(path: parts, absolute: line.first == 0x2F || line.first == 0x5C))
            }
        }
    }

    /// The tunes of an M3U list: every line that is not empty, nor a remark, nor the address of
    /// something on the internet. (M3U came with a player for Windows, WinPlay3, and an M3U file is
    /// in the characters of the computer that wrote it: in Unicode, if it is well formed as that,
    /// and otherwise taken to be in those of the Windows of the West, as the lists in VGM packs are.)
    private mutating func readM3U(_ data: ArraySlice<UInt8>) {
        let unicode = Self.isUnicode(data)
        for raw in data.split(separator: 0x0A) {
            var line = raw[...]
            while let last = line.last, last == 0x0D || last == 0x20 || last == 0x09 { line = line.dropLast() }
            while let first = line.first, first == 0x20 || first == 0x09 { line = line.dropFirst() }
            guard let first = line.first, first != 0x23 else { continue } // #
            if line.indices.dropLast(2).contains(where: { line[$0] == 0x3A && line[$0 + 1] == 0x2F && line[$0 + 2] == 0x2F }) { continue } // ://
            let parts = line.split(whereSeparator: { $0 == 0x2F || $0 == 0x5C }).map { part in
                unicode ? String(decoding: part, as: UTF8.self) : TextEncoding.windows1252.decode(part) ?? TextEncoding.latin1.decode(part) ?? ""
            }.filter { $0 != "." }
            guard !parts.isEmpty else { continue }
            entries.append(Entry(path: parts, absolute: first == 0x2F || first == 0x5C))
        }
    }

    // MARK: Text

    /// True if bytes are well-formed UTF-8.
    private static func isUnicode(_ bytes: ArraySlice<UInt8>) -> Bool {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            let more = byte < 0x80 ? 0 : byte & 0xE0 == 0xC0 && byte >= 0xC2 ? 1 : byte & 0xF0 == 0xE0 ? 2 : byte & 0xF8 == 0xF0 && byte <= 0xF4 ? 3 : -1
            guard more >= 0, index + more < bytes.endIndex else { return false }
            for following in 0 ..< more where bytes[index + 1 + following] & 0xC0 != 0x80 { return false }
            index += more + 1
        }
        return true
    }

    /// Text in the Cyrillic of Windows. (A byte that is no letter of it is shown as one that is not known.)
    private static func cyrillic(_ bytes: ArraySlice<UInt8>) -> String {
        var text = String.UnicodeScalarView()
        for byte in bytes {
            let code = byte < 0x80 ? UInt16(byte) : byte < 0xC0 ? TextEncoding.cyrillic[Int(byte) - 0x80] : 0x0410 + UInt16(byte - 0xC0)
            text.append(code == 0xFFFF ? "\u{FFFD}" : Unicode.Scalar(code) ?? "\u{FFFD}")
        }
        return String(text)
    }

    /// A note as it can be shown on one line: with a space for anything that is not a letter or a
    /// sign, and none at its ends.
    private static func tidy(_ note: String) -> String {
        var scalars = note.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : $0 }[...]
        while scalars.first == " " { scalars = scalars.dropFirst() }
        while scalars.last == " " { scalars = scalars.dropLast() }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: scalars)
        return String(text)
    }
}

extension FileFinder {
    /// The place of the file a list's entry means when it is a tune beside the list or below it,
    /// and where the list itself is among the paths is known: the file at just that path. Nil if
    /// the entry is of a tune somewhere else, or there is no such file.
    public func place(of entry: PlaylistFile.Entry, besideList list: String) -> Int? {
        guard !entry.absolute, !entry.path.contains("..") else { return nil }
        return place(of: entry.path, beside: list)
    }

    /// The place of the file a list's entry means, wherever it is; nil if none of them is it.
    public func place(of entry: PlaylistFile.Entry) -> Int? {
        place(of: entry.path.filter { $0 != ".." })
    }
}
