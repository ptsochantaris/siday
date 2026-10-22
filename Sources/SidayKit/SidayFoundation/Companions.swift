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
    /// True if it is not a file but a folder beside the tune, of one of `names` in any case, and what
    /// the tune has is every file in it (and none in the folders below), brought as one, by
    /// `CompanionFolder.pack`.
    public var folder = false

    /// What it is, as said of the tune: "its samples".
    public var what: String {
        switch part {
        case .samples: "its samples"
        case .instruments: "its instruments"
        }
    }
}

/// The files of a folder that is a tune's companion (`Companion.folder`), as they are brought to the
/// library: one run of bytes, so that they go wherever a companion's file does. Each file is its
/// name's length in UTF-8 and then the name, and its length and then its bytes, each length in four
/// bytes with the highest first.
public enum CompanionFolder {
    public static func pack(_ files: [(name: String, bytes: [UInt8])]) -> [UInt8] {
        var packed: [UInt8] = []
        packed.reserveCapacity(files.reduce(0) { $0 + 8 + $1.name.utf8.count + $1.bytes.count })
        func count(_ n: Int) {
            for shift in [24, 16, 8, 0] { packed.append(UInt8(truncatingIfNeeded: n >> shift)) }
        }
        for file in files {
            count(file.name.utf8.count)
            packed += file.name.utf8
            count(file.bytes.count)
            packed += file.bytes
        }
        return packed
    }

    /// The files packed in a run of bytes, in their order; as many as are whole, if it is cut short.
    public static func unpack(_ packed: [UInt8]) -> [(name: String, bytes: [UInt8])] {
        var files: [(name: String, bytes: [UInt8])] = []
        var at = 0
        func count() -> Int? {
            guard at + 4 <= packed.count else { return nil }
            defer { at += 4 }
            return packed[at ..< at + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        while let length = count(), length <= packed.count - at {
            let name = String(decoding: packed[at ..< at + length], as: UTF8.self)
            at += length
            guard let size = count(), size <= packed.count - at else { break }
            files.append((name, Array(packed[at ..< at + size])))
            at += size
        }
        return files
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
/// - a MaxTrax file of scores alone has its instruments in `set.smpl` beside it (on the Amiga's own
///   disks, `mxtx.title`'s in `smpl.title`), or the one file ending `.smpl` beside it.
/// - a module of Richard Joseph's player, `title.rjp`, has its samples in `title.smp`, or, where the
///   modules of a game share them, `set.smp` (or `smp.set`); on the Amiga's own disks `rjp.title` in
///   `smp.title`. Failing those, the one file ending `.smp` beside it, if there is only one.
/// - a score of the Sonix Music Driver, `title.smus`, `title.tiny` or `title.snx`, names its
///   instruments, and has them in a folder beside it, `Instruments` (`NAME.instr`, and the sampled
///   sound of one that names one, `NAME.ss`): the whole folder is brought, and the player finds them
///   in it.
/// - an Infogrames score, `TITLE.DUM`, has its instruments in `TITLE.INS`, or in that name less its last
///   letter (`BOB4B.DUM` in `BOB4.INS`), or, for Stir Crazy's and Captain Blood's, in `rh.ins`.
/// - a module of the Alcatraz Packer's, `title.alp`, mostly has its samples in `title.smp`.
/// - a module of Ashley Hogg's of 1993, `title.ash`, has its samples in `title.smp`.
/// - a module of Kris Hatlelid's that is music alone is played by his replayer, beside it as `songplay`.
/// - a module of Jesper Olsen's that is music alone is played by its game's driver, beside it as
///   `WantedTeam.bin`; one of the Dynamic Synthesizer's, `title.dns`, has its samples in `title.smp`
///   (`SMP.title` for `DNS.title`).
/// - a replayer of Mark Cooksey's of 1988, `title.mcr`, has its song data and samples in `title.mcs`
///   (on the Amiga's own disks `MCR.title`'s in `MCS.title`).
/// - a score of Scott Johnston's SoundPlayer, `title.sjs`, has its samples in `title.smp` (on the Amiga's
///   own disks `SJS.title`'s in `SMP.title`).
/// - a score of Paul Robotham's on Pete Barnett's driver, `title.dat`, has its samples in `title.ssd`, or,
///   where the scores of a game share them, `mdtest.ssd`.
/// - a module of Thomas Hermann's, `title.thm`, has its samples in `title.smp` (`SMP.title` for
///   `THM.title`), or failing that each in its own file in the folder `Instruments` beside it, by the name
///   the module gives it, in any case.
/// - a module of Synth Dream's, `title.sdr`, has its samples in `title.smp` (`SMP.title` for
///   `SDR.title`), or, as the modules of a game share them, `set.smp` (`SMP.set`).
/// - a module of the Blade Packer's, `title.uds`, has its samples in `title.smp` (`SMP.title` for
///   `UDS.title`).
/// - a Cinemaware score, `title.cin`, as Sonix's, has its instruments in the folder beside it,
///   `Instruments`, each named in the score.
/// - a module of Startrekker's that has synthesised instruments keeps them in a file beside it, which
///   Startrekker named for the module with `.nt` after it (`.as` from Audio Sculpture), and the
///   collections as `title_nt.mod` beside `title.mod`.
/// - a ROL tune takes its instruments from a bank of its own name, `TUNE.BNK` for `TUNE.ROL`, and then
///   from `STANDARD.BNK`, and what neither has from the bank built into the player.
public enum Companions {
    /// The name of the file of song data and samples beside a replayer of Mark Cooksey's of 1988:
    /// `MCS.title` for `MCR.title`, `title.mcs` for `title.mcr`.
    static func markCookseySongs(of fileName: String) -> String {
        let letters = Array(fileName.utf8)
        if fileName.lowercased().hasPrefix("mcr.") { return "MCS." + String(decoding: letters.dropFirst(4), as: UTF8.self) }
        let stem = letters.lastIndex(of: 0x2E).map { String(decoding: letters[..<$0], as: UTF8.self) } ?? fileName
        return "\(stem).mcs"
    }

    /// The endings of the names of companion files, of every kind: a file with one of these is part of
    /// a tune, not a tune.
    public static let endings: Set<String> = ["smp", "bnk", "smpl", "sam", "instr", "ss", "mcs", "ins", "ssd"]

    /// The names, whole, of companion files kept under a name of their own and not an ending: Kris
    /// Hatlelid's replayer and Jesper Olsen's games' driver.
    public static let names: Set<String> = ["songplay", "wantedteam.bin"]

    /// True if a file of this extension, in any case, is a companion of a tune.
    public static func are(fileExtension: String) -> Bool {
        endings.contains(fileExtension.lowercased())
    }

    /// True if a file of this name (the last part of its path), in any case, is a companion of a tune:
    /// by its ending, or by the whole of it.
    public static func are(fileName: String) -> Bool {
        let lowered = fileName.lowercased()
        if names.contains(lowered) { return true }
        let letters = Array(lowered.utf8)
        guard let stop = letters.lastIndex(of: 0x2E) else { return false }
        return endings.contains(String(decoding: letters[(stop + 1)...], as: UTF8.self))
    }

    /// The last part of a path, the file's own name; empty if there is no path.
    package static func fileName(_ path: String?) -> String {
        guard let path else { return "" }
        return path.utf8.split(separator: 0x2F).last.map { String(decoding: Array($0), as: UTF8.self) } ?? ""
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
        case .mxtx:
            // Only a file of scores alone needs them (see `MaxTraxPlayer.needsInstruments`): the
            // instruments of A-Train's and Kyrandia's, in `set.smpl` beside them; on the Amiga's own
            // disks `mxtx.title` has them in `smpl.title`.
            var names = ["set.smpl"]
            if fileName.lowercased().hasPrefix("mxtx.") { names.insert("smpl." + fileName.dropFirst(5), at: 0) }
            return [Companion(part: .samples, names: names, kind: "smpl", required: false)]
        case .dum:
            // As Infogrames' player looks for them: the score's name with `.ins`, then that name less its
            // last letter (so `BOB4B.DUM` has them in `BOB4.INS`); and, siday's own, `rh.ins`, which Stir
            // Crazy's and Captain Blood's scores share.
            var names = ["\(stem).ins"]
            if stem.count > 1 { names.append("\(stem.dropLast()).ins") }
            names.append("rh.ins")
            return [Companion(part: .samples, names: names, kind: nil, required: true)]
        case .alp:
            // Most have their samples beside them, `title.smp` for `title.alp` (`SMP.title` for
            // `ALP.title`); one of one file needs none, which is known only once it is read.
            var names = ["\(stem).smp"]
            if fileName.lowercased().hasPrefix("alp.") { names.insert("SMP." + fileName.dropFirst(4), at: 0) }
            return [Companion(part: .samples, names: names, kind: nil, required: false)]
        case .ash:
            // Those of 1993 have their samples beside them, `title.smp` for `title.ash` (`SMP.title` for
            // `ASH.title`); those of 1991 keep theirs in the module, which is known only once it is read.
            var names = ["\(stem).smp"]
            if fileName.lowercased().hasPrefix("ash.") { names.insert("SMP." + fileName.dropFirst(4), at: 0) }
            return [Companion(part: .samples, names: names, kind: nil, required: false)]
        case .kh:
            // His replayer, which a module of music alone is played by, in a file of its own beside it.
            return [Companion(part: .samples, names: ["songplay"], kind: nil, required: false)]
        case .jo:
            // The game's own driver, for the modules that are music and samples alone, as Wanted Team
            // kept it beside them; a module with the driver in it needs none, which is known only once it
            // is read.
            return [Companion(part: .samples, names: ["WantedTeam.bin"], kind: nil, required: false)]
        case .dns:
            // `title.smp` for `title.dns`; on the Amiga's own disks `SMP.title` for `DNS.title`.
            var names = ["\(stem).smp"]
            if fileName.lowercased().hasPrefix("dns.") { names.insert("SMP." + fileName.dropFirst(4), at: 0) }
            return [Companion(part: .samples, names: names, kind: "smp", required: true)]
        case .sjs:
            // `title.smp` for `title.sjs`; on the Amiga's own disks `SMP.title` for `SJS.title`.
            var names = ["\(stem).smp"]
            if fileName.lowercased().hasPrefix("sjs.") { names.insert("SMP." + fileName.dropFirst(4), at: 0) }
            return [Companion(part: .samples, names: names, kind: "smp", required: true)]
        case .dat:
            // As the player looks for them: the score's name with `.ssd`, then the file the scores of a game
            // share, `mdtest.ssd`.
            return [Companion(part: .samples, names: ["\(stem).ssd", "mdtest.ssd"], kind: nil, required: true)]
        case .mcr:
            // Named as the replayer is, as Wanted Team's player looks for it: `MCS.title` for
            // `MCR.title`, and as UnExoticA keeps them, `title.mcs` for `title.mcr`.
            return [Companion(part: .samples, names: [markCookseySongs(of: fileName)], kind: nil, required: true)]
        case .rjp:
            // Kept as the modules of a game share them, in `set.smp` (UnExoticA's name, for James
            // Pond 2's for the Amiga 1200), or as Wanted Team's player looks for them, `smp.set`; on
            // the Amiga's own disks `rjp.title` has them in `smp.title`.
            var names = ["\(stem).smp", "set.smp", "smp.set"]
            if fileName.lowercased().hasPrefix("rjp.") { names.insert("smp." + fileName.dropFirst(4), at: 1) }
            return [Companion(part: .samples, names: names, kind: "smp", required: true)]
        case .sdr:
            // As the player looks for them, `SMP.title` for `SDR.title` and then `SMP.set`; and as the
            // collection keeps them, `title.smp`, or `set.smp` where a game's modules share them.
            var names = ["\(stem).smp", "set.smp", "SMP.set"]
            if fileName.lowercased().hasPrefix("sdr.") { names.insert("SMP." + fileName.dropFirst(4), at: 0) }
            return [Companion(part: .samples, names: names, kind: "smp", required: true)]
        case .uds:
            var names = ["\(stem).smp"]
            if fileName.lowercased().hasPrefix("uds.") { names.insert("SMP." + fileName.dropFirst(4), at: 0) }
            return [Companion(part: .samples, names: names, kind: "smp", required: true)]
        case .thm:
            // Its samples in one file beside it; or, failing that, each in a folder of instruments beside it.
            var names = ["\(stem).smp"]
            if fileName.lowercased().hasPrefix("thm.") { names.insert("SMP." + fileName.dropFirst(4), at: 0) }
            return [Companion(part: .samples, names: names, kind: nil, required: false),
                    Companion(part: .samples, names: ["Instruments"], kind: nil, required: false, folder: true)]
        case .sonix, .cin:
            // Named in the score, and kept, as the player looks for them, in a folder beside it.
            return [Companion(part: .instruments, names: ["Instruments"], kind: nil, required: true, folder: true)]
        case .mod:
            // Only a module of Startrekker's with synthesised instruments has one, which is known only once
            // it is read: so not required, and any other module plays as it is (`StartrekkerSynth`).
            let ending = bytes.lastIndex(of: 0x2E).map { String(decoding: bytes[($0 + 1)...], as: UTF8.self) } ?? "mod"
            return [Companion(part: .instruments, names: ["\(stem)_nt.\(ending)", "\(fileName).nt", "\(fileName).as"], kind: nil, required: false)]
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

    /// The files of a companion that is a folder (`Companion.folder`) among some files: those in the
    /// first folder of its names that is beside the tune and has any. Empty if there is none.
    /// - Parameter tune: the tune's path among the files.
    public static func findFolder(_ companion: Companion, for tune: String, among files: FileFinder) -> [Int] {
        for name in companion.names {
            let found = files.places(inFolder: name, beside: tune)
            if !found.isEmpty { return found }
        }
        return []
    }

    /// Where a companion is kept, as said of the tune: "in a file of their own, title.smp".
    public static func whereKept(_ companion: Companion) -> String {
        let names = companion.names.count > 1 ? companion.names.dropLast().joined(separator: ", ") + " or " + (companion.names.last ?? "")
            : companion.names.joined()
        return companion.folder ? "in a folder of their own beside it, \(names)" : "in a file of their own, \(names)"
    }

    /// The error of a tune that is not played because a companion it cannot be without was not found.
    public static func missing(_ companion: Companion) -> TuneError {
        .missingCompanion("\(companion.what) are kept \(whereKept(companion)), which was not found")
    }
}
