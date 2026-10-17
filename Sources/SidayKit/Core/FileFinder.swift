// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// Finds files by their names among files known only by their paths: the files a browser has been
/// given, or those a folder holds. It is how a file that comes with another is found, whatever the
/// other is: the tunes a playlist names (`PlaylistFile`), and the files a tune keeps part of itself
/// in (`Companions`).
///
/// Where the files came from is not known, nor how much of the disk came with them, so a file is
/// found by the end of its path, by the rules of Windows, where most of these files were made: a
/// capital is the same as a small letter, and a full stop or a space at the end of a name is
/// nothing. Where no file has the name so, one whose name is the same when compared `loose` is it.
public struct FileFinder: Sendable {
    /// Each file by its path, with a stroke between folders, in the order they were added.
    public private(set) var paths: [String] = []
    /// The places in `paths` of the files of each name, and of each name as it is compared loosely.
    private var named: [[UInt8]: [Int]] = [:]
    private var loosely: [[UInt8]: [Int]] = [:]
    /// The places of the files whose names end so, by the ending in small letters.
    private var ending: [String: [Int]] = [:]

    /// - Parameter paths: each file by its path, with a stroke between folders.
    public init(_ paths: [String] = []) {
        add(paths)
    }

    /// Makes more files known, after those that already are.
    public mutating func add(_ more: [String]) {
        for path in more {
            let place = paths.count
            paths.append(path)
            guard let file = Self.steps(path).last else { continue }
            named[Self.plain(file), default: []].append(place)
            loosely[Self.loose(file), default: []].append(place)
            let bytes = Array(file.utf8)
            if let stop = bytes.lastIndex(of: 0x2E) {
                ending[String(decoding: bytes[(stop + 1)...], as: UTF8.self).lowercased(), default: []].append(place)
            }
        }
    }

    public var count: Int { paths.count }

    // MARK: Names

    /// A name of a file or a folder as it is compared with another: in small letters, and without the
    /// full stops and spaces at its end, which Windows does not keep.
    public static func plain(_ name: String) -> [UInt8] {
        var bytes = Array(name.lowercased().utf8)
        while bytes.count > 1, bytes.last == 0x2E || bytes.last == 0x20 { bytes.removeLast() }
        return bytes
    }

    /// A name as it is compared when no file has it as `plain` has it: with only the letters of
    /// English, the figures and the signs a typewriter has, so that an accented letter is set aside,
    /// as written whole or as a letter and its accent, and so is whatever it was turned into on the way
    /// from one computer to another. (The music of The Secret of Monkey Island in its VGM pack has
    /// a list that says "Mêlée Island", and a file named "Mˆl‚e Island": the name was written in the
    /// PC's own characters, and read as those of Windows.)
    public static func loose(_ name: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var accentable = false
        for scalar in name.lowercased().unicodeScalars {
            if scalar.value < 0x80 {
                bytes.append(UInt8(scalar.value))
                accentable = (0x61 ... 0x7A).contains(scalar.value)
            } else if (0x300 ... 0x36F).contains(scalar.value) {
                if accentable { bytes.removeLast() }
                accentable = false
            } else {
                accentable = false
            }
        }
        while bytes.count > 1, bytes.last == 0x2E || bytes.last == 0x20 { bytes.removeLast() }
        return bytes
    }

    /// The folders of a path and then its file, as they are written.
    private static func steps(_ path: String) -> [String] {
        path.utf8.split(separator: 0x2F).map { String(decoding: Array($0), as: UTF8.self) }
    }

    /// A path's steps as they are compared: the file's own name loosely if `loose`.
    private static func parts(_ path: [String], loose: Bool = false) -> [[UInt8]] {
        path.indices.map { loose && $0 == path.count - 1 ? Self.loose(path[$0]) : plain(path[$0]) }
    }

    private static func parts(_ path: String, loose: Bool = false) -> [[UInt8]] {
        parts(steps(path), loose: loose)
    }

    /// The files a name can be, and whether they are of that name only loosely.
    private func candidates(_ file: String) -> (places: [Int], loose: Bool)? {
        if let places = named[Self.plain(file)] { return (places, false) }
        return loosely[Self.loose(file)].map { ($0, true) }
    }

    // MARK: Finding

    /// The place of the file at a path from the folder another file is in (a playlist, a tune): the
    /// file at just that path. Nil if there is no such file. (Of a name that is the same only
    /// loosely, there must be no other file at that place that it could be.)
    /// - Parameters:
    ///   - path: the folders on the way down from that folder, and the file's own name.
    ///   - other: the other file, by its path among these.
    public func place(of path: [String], beside other: String) -> Int? {
        guard let file = path.last, let (places, loose) = candidates(file) else { return nil }
        let wanted = Self.parts(other).dropLast() + Self.parts(path, loose: loose)
        let found = places.filter { Self.parts(paths[$0], loose: loose).elementsEqual(wanted) }
        return loose && found.count > 1 ? nil : found.first
    }

    /// The place of the file a path ends with, wherever it is: the file whose name is the same and
    /// which has the most folders above it of the same names as the path gives, and the first of those
    /// if there are several. Nil if no file has the name.
    public func place(of path: [String]) -> Int? {
        guard let file = path.last, let (places, loose) = candidates(file) else { return nil }
        let wanted = Self.parts(path, loose: loose)
        var best: Int?
        var most = 0
        for candidate in places {
            let has = Self.parts(paths[candidate], loose: loose)
            var same = 0
            while same < wanted.count, same < has.count, wanted[wanted.count - 1 - same] == has[has.count - 1 - same] { same += 1 }
            if same > most {
                best = candidate
                most = same
            }
        }
        return best
    }

    /// The place of the file of a name that is nearest another file: of those of the name, the one
    /// whose folder has the most of the other's folders above it, from the top, and the first of
    /// those that are as near. Nil if no file has the name.
    public func place(of name: String, nearest other: String) -> Int? {
        guard let (places, _) = candidates(name) else { return nil }
        let from = Self.parts(other).dropLast()
        var best: Int?
        var most = -1
        for candidate in places {
            let folder = Self.parts(paths[candidate]).dropLast()
            var same = 0
            while same < from.count, same < folder.count, from[from.startIndex + same] == folder[folder.startIndex + same] { same += 1 }
            if same > most {
                best = candidate
                most = same
            }
        }
        return best
    }

    /// The places of the files in the folder another file is in whose names have this ending, in
    /// any case, after their last full stop.
    public func places(ending wanted: String, beside other: String) -> [Int] {
        let folder = Self.parts(other).dropLast()
        return (ending[wanted.lowercased()] ?? []).filter { Self.parts(paths[$0]).dropLast().elementsEqual(folder) }
    }
}
