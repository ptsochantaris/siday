// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// Files that hold part of a tune: a kind of tune that keeps its samples in a file of their own, beside
/// the file of its notes, needs both. The library reads no files, so it says what the other file may be
/// called, and whoever loads the tune looks for it (on the disk; among the files a page was given) and
/// brings its bytes too (`TuneLoader.load(_:format:path:options:companion:)`).
///
/// The names are as the files are found named on the Amiga's collections today, by their endings: a
/// Magnetic Fields Packer song `title.mfp` with its samples in `title.smp`, or, where several songs share
/// their samples, `KidChaos Level 1-3.mfp` with `KidChaos Level 1_set.smp`. Failing those, the one file
/// of the companion's kind beside the tune is taken, if there is only one.
public enum Companions {
    /// The endings of the names of companion files, of every kind: a file with one of these is part of
    /// a tune, not a tune.
    public static let endings: Set<String> = ["smp"]

    /// The ending of the name of the file a tune of this kind keeps part of itself in; nil for a kind
    /// that keeps all of itself in its own file.
    public static func ending(for format: TuneFormat) -> String? {
        switch format {
        case .mfp: "smp"
        default: nil
        }
    }

    /// The names the file a tune keeps part of itself in may have, from the tune's own file name (the
    /// last part of its path), in the order they are to be looked for; empty for a kind that keeps all
    /// of itself in its own file.
    public static func names(for format: TuneFormat, fileName: String) -> [String] {
        guard let ending = ending(for: format) else { return [] }
        let stem = fileName.lastIndex(of: ".").map { String(fileName[..<$0]) } ?? fileName
        var names = ["\(stem).\(ending)"]
        // Samples shared by several songs: the name up to the last hyphen, "_set".
        if let hyphen = stem.lastIndex(of: "-") {
            names.append("\(stem[..<hyphen])_set.\(ending)")
        }
        return names
    }

    /// The one that a list of names found beside the tune has, of those `names` gives, in their order;
    /// failing that, the only one with the companion's ending, if there is only one. Names are compared
    /// as a person would, with no difference between capitals and small letters.
    public static func pick(for format: TuneFormat, fileName: String, among names: [String]) -> String? {
        guard let ending = ending(for: format) else { return nil }
        let lowered = names.map { $0.lowercased() }
        for wanted in Self.names(for: format, fileName: fileName) {
            if let place = lowered.firstIndex(of: wanted.lowercased()) { return names[place] }
        }
        let kind = names.filter { $0.lowercased().hasSuffix("." + ending) }
        return kind.count == 1 ? kind[0] : nil
    }
}
