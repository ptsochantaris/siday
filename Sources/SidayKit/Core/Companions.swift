// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A file a tune keeps part of itself in, or takes something from: a kind of tune that keeps its
/// samples in a file of their own, beside the file of its notes, or one that takes its instruments
/// from a bank beside it.
public struct Companion: Sendable, Equatable {
    /// What the tune has from it.
    public enum Part: Sendable, Equatable {
        /// Its samples, without which its notes are not heard.
        case samples
        /// Instruments, which the player has its own of, for those not found.
        case instruments
    }

    public var part: Part
    /// The names it may have, in the order they are looked for.
    public var names: [String]
    /// The ending of the names of files of its kind, when, failing those names, the one file of the
    /// kind beside the tune is taken, if there is only one; nil if no file is taken for its kind alone.
    public var kind: String?
    /// True if the tune cannot be played without it.
    public var required: Bool

    /// What it is, as said of the tune: "its samples".
    public var what: String {
        switch part {
        case .samples: "its samples"
        case .instruments: "its instruments"
        }
    }
}

/// What files a tune needs beside its own, and how they are found. The library reads no files, so
/// it says what the others may be called, and whoever loads the tune looks for them, among the
/// files of its folder on a disk or among those a page was given, with a `FileFinder`, and brings
/// their bytes too (`TuneLoader.load(_:format:path:options:companions:)`). The tunes a playlist names
/// are found in the same way, by `FileFinder`.
///
/// The names are as the files are found named on the collections today:
/// - a Magnetic Fields Packer song, `title.mfp`, has its samples in `title.smp`, or, where several
///   songs share them, `KidChaos Level 1-3.mfp` in `KidChaos Level 1_set.smp`; on the Amiga's own
///   disks, where the kind of a file was put before its name, `mfp.title` has them in `smp.title`.
///   Failing those, the one file ending `.smp` beside the song, if there is only one.
/// - a TFMX module, `title.mdat`, has its samples in `title.smpl` (`title.sam` for `title.tfx`); on
///   the Amiga's own disks `mdat.title` in `smpl.title`; where the songs of a folder share them,
///   `smpl.set` or `set.smpl`; failing those, the one file ending `.smpl` beside it, if there is only
///   one. A TFMX module of one file has its samples in it, and needs none.
/// - a song of Jochen Hippel's compressed TFMX (COSO) that keeps no samples of its own, as Amberstar's
///   do, has them in `set.smp` (in older copies, `samp.hipc`), or the one file ending `.smp` beside it.
/// - a song packed by Pierre Adane's packer, `title.pap`, has its samples in `title.smp`, or, as the
///   songs of a game share them, `set.smp` (or `smp.set`); on the Amiga's own disks `pap.title` in
///   `smp.title`. Failing those, the one file ending `.smp` beside it, if there is only one.
/// - a ROL tune takes its instruments from a bank of its own name, `TUNE.BNK` for `TUNE.ROL`, and then
///   from `STANDARD.BNK`, and what neither has from the bank built into the player.
public enum Companions {
    /// The endings of the names of companion files, of every kind: a file with one of these is part of
    /// a tune, not a tune.
    public static let endings: Set<String> = ["smp", "bnk", "smpl", "sam"]

    /// True if a file of this extension, in any case, is a companion of a tune.
    public static func are(fileExtension: String) -> Bool {
        endings.contains(fileExtension.lowercased())
    }

    /// The files a tune of this kind needs beside its own, by the tune's file name (the last part of
    /// its path), in the order they are to be brought; empty for a kind that keeps all of itself in
    /// its own file.
    public static func wanted(for format: TuneFormat, fileName: String) -> [Companion] {
        let bytes = Array(fileName.utf8)
        let stem = bytes.lastIndex(of: 0x2E).map { String(decoding: bytes[..<$0], as: UTF8.self) } ?? fileName
        switch format {
        case .mfp:
            var names = ["\(stem).smp"]
            // Samples shared by several songs: the name up to the last hyphen, "_set".
            if let hyphen = stem.lastIndex(of: "-") { names.append("\(stem[..<hyphen])_set.smp") }
            // The Amiga's way, with the kind before the name.
            if fileName.lowercased().hasPrefix("mfp.") { names.append("smp." + fileName.dropFirst(4)) }
            return [Companion(part: .samples, names: names, kind: "smp", required: true)]
        case .tfmx:
            // Not needed by a module that keeps its samples in its own file, which is known only once
            // it is read: so not required here, and the loader says when it is.
            let lowered = fileName.lowercased()
            var names = lowered.hasSuffix(".tfx") || lowered.hasSuffix(".tfm") ? ["\(stem).sam", "\(stem).smpl"] : ["\(stem).smpl", "\(stem).sam"]
            if lowered.hasPrefix("mdat.") { names.append("smpl." + fileName.dropFirst(5)) }
            // Samples shared by the songs of a folder, as libtfmxaudiodecoder looks for them, and as
            // they are named in one game's folder (Einmal Kanzler sein).
            names += ["smpl.set", "set.smpl"]
            return [Companion(part: .samples, names: names, kind: "smpl", required: false)]
        case .hip:
            // Only a compressed song that keeps none of its own needs them (see
            // `HippelPlayer.keepsSamplesApart`): Amberstar's, which share one file of them.
            return [Companion(part: .samples, names: ["set.smp", "smp.set", "samp.hipc"], kind: "smp", required: false)]
        case .pap:
            // Kept as the songs of a game share them, in `set.smp` (UnExoticA's name) beside them;
            // or as Wanted Team's player looks for them, `smp.set`, or for `pap.title` in `smp.title`.
            var names = ["\(stem).smp", "set.smp", "smp.set"]
            if fileName.lowercased().hasPrefix("pap.") { names.insert("smp." + fileName.dropFirst(4), at: 1) }
            return [Companion(part: .samples, names: names, kind: "smp", required: true)]
        case .rol:
            let own = Companion(part: .instruments, names: ["\(stem).bnk"], required: false)
            let standard = Companion(part: .instruments, names: ["standard.bnk"], required: false)
            return stem.lowercased() == "standard" ? [standard] : [own, standard]
        default:
            return []
        }
    }

    /// Where a companion of a tune is among some files: the first of its names beside the tune; then,
    /// for a kind that is taken for itself, the only file of the kind beside the tune; then the first
    /// of its names wherever it is, nearest the tune (for files given to a browser, where the tune
    /// may have come by itself and its companion in a folder). Nil if it is not there.
    /// - Parameter tune: the tune's path among the files.
    public static func find(_ companion: Companion, for tune: String, among files: FileFinder) -> Int? {
        for name in companion.names {
            if let place = files.place(of: [name], beside: tune) { return place }
        }
        if let kind = companion.kind {
            let beside = files.places(ending: kind, beside: tune)
            if beside.count == 1 { return beside[0] }
        }
        for name in companion.names {
            if let place = files.place(of: name, nearest: tune) { return place }
        }
        return nil
    }

    /// The error of a tune that is not played because a companion it cannot be without was not found.
    public static func missing(_ companion: Companion) -> TuneError {
        let names = companion.names.count > 1 ? companion.names.dropLast().joined(separator: ", ") + " or " + companion.names.last! : companion.names.joined()
        return .missingCompanion("\(companion.what) are kept in a file of their own, \(names), which was not found")
    }
}
