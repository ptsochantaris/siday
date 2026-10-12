// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A playlist: a file that is not a tune but a list of tunes, to be played in the order it has them.
///
/// The kind read is Ay_Emul's (AYL), which is text: a line that says what the file is, and then the
/// tunes, one to a line, each by its path from the folder the list is in, written as Windows writes
/// one. A tune may be followed by what Ay_Emul knew about it, between a line that is `<` and a line
/// that is `>`: its name and author, how long it is, the chip it is to be played on. Of those only
/// the comment is kept, to be shown with the tune: the rest is what the tune's own file says, or what
/// Ay_Emul needed to find a module inside a larger file, which is found here without being told.
///
/// Like the rest of the library this reads no files. Whoever has the list finds its tunes: on a disk
/// by following each path (`Entry.path`), and where files are known only by their names, as in a
/// browser, with a `Finder`.
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

    public private(set) var entries: [Entry] = []

    /// True if a file of this extension, in any case, is a playlist.
    public static func reads(fileExtension: String) -> Bool {
        fileExtension.lowercased() == "ayl"
    }

    /// What every list begins with, before the number of the version of the format it is in.
    private static let heading = Array("ZX Spectrum Sound Chip Emulator Play List File".utf8)
    private static let comment = Array("Comment=".utf8)

    /// The list in a file's bytes; nil if they are not a list.
    public init?(_ data: [UInt8]) {
        var data = data[...]
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
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

    /// A name of a file or a folder as it is compared with another: in small letters, and without the
    /// full stops and spaces at its end, which Windows, where these lists were made, does not keep.
    public static func plain(_ name: String) -> [UInt8] {
        var bytes = Array(name.lowercased().utf8)
        while bytes.count > 1, bytes.last == 0x2E || bytes.last == 0x20 { bytes.removeLast() }
        return bytes
    }

    // MARK: Finding

    /// Finds a list's tunes among files that are known only by their paths, and not on a disk that can
    /// be looked through: the files a browser has been given. Where the list itself was among them is
    /// not known, and nor is how much of the disk they came with, so a tune is found by the end of its
    /// path: it is the file whose name is the same and which has the most folders above it of the same
    /// names as the list gives, and the first of those if there are several.
    public struct Finder: Sendable {
        private let paths: [String]
        /// The places in `paths` of the files of each name.
        private var named: [[UInt8]: [Int]] = [:]

        /// - Parameter paths: each file by its path, with a stroke between folders.
        public init(_ paths: [String]) {
            self.paths = paths
            for (place, path) in paths.enumerated() {
                guard let file = Self.parts(path).last else { continue }
                named[file, default: []].append(place)
            }
        }

        private static func parts(_ path: String) -> [[UInt8]] {
            path.utf8.split(separator: 0x2F).map { PlaylistFile.plain(String(decoding: Array($0), as: UTF8.self)) }
        }

        /// The place of the file a list's entry means when it is a tune beside the list or below it,
        /// and where the list itself is among the paths is known: the file at just that path. Nil
        /// if the entry is of a tune somewhere else, or there is no such file.
        public func place(of entry: Entry, besideList list: String) -> Int? {
            guard !entry.absolute, !entry.path.contains("..") else { return nil }
            let wanted = Self.parts(list).dropLast() + entry.path.map { PlaylistFile.plain($0) }
            guard let file = wanted.last, let candidates = named[file] else { return nil }
            return candidates.first { Self.parts(paths[$0]).elementsEqual(wanted) }
        }

        /// The place, in the paths this was made with, of the file a list's entry means; nil if none
        /// of them is it.
        public func place(of entry: Entry) -> Int? {
            let wanted = entry.path.filter { $0 != ".." }.map { PlaylistFile.plain($0) }
            guard let file = wanted.last, let candidates = named[file] else { return nil }
            var best: Int?
            var most = 0
            for candidate in candidates {
                let has = Self.parts(paths[candidate])
                var same = 0
                while same < wanted.count, same < has.count, wanted[wanted.count - 1 - same] == has[has.count - 1 - same] { same += 1 }
                if same > most {
                    best = candidate
                    most = same
                }
            }
            return best
        }
    }
}
