// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A file the listener gives siday once and that it keeps from then on, until told to forget it: a ROM of
/// an MT-32 or its kind, by which MIDI files written for the MT-32 are played on its synthesiser; a ROM of a
/// Roland SC-55, by which the others are played on the Sound Canvas; or HVSC's list of song lengths,
/// `Songlengths.md5`. What it is is known by what is in it, never by its name: an MT-32's ROM by its size and
/// its SHA-1 digest, as Munt knows them; an SC-55's by its size and its SHA-256 digest, as jcmoyer's Nuked
/// SC-55 knows them; a list of song lengths by its having lengths in it.
public struct KeptFile: Sendable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case mt32ROM = "mt32rom"
        case sc55ROM = "sc55rom"
        case songLengths = "songlengths"
    }

    public let kind: Kind
    /// Its SHA-1 digest, in lower-case hexadecimal.
    public let sha1: String
    public let size: Int
    /// What it is, for a listener: Munt's name for an MT-32's ROM, Roland's part number for an SC-55's.
    public let name: String

    /// The name it is kept under: its kind and its digest, so that the same file is kept once, whatever it
    /// was called.
    public var keptName: String { kind.rawValue + "-" + sha1 }

    /// What a file is, if it is one that siday keeps; nil for any other.
    public static func recognise(_ data: [UInt8]) -> KeptFile? {
        if let rom = MT32ROMFile.identify(data) {
            return KeptFile(kind: .mt32ROM, sha1: rom.sha1, size: data.count, name: rom.name)
        }
        if let rom = SC55ROMFile.identify(data) {
            return KeptFile(kind: .sc55ROM, sha1: SHA1.hex(data), size: data.count, name: rom.name)
        }
        if mayBeSongLengths(data.prefix(64)), !SongLengthDatabase(data).isEmpty {
            return KeptFile(kind: .songLengths, sha1: SHA1.hex(data), size: data.count, name: "HVSC's song lengths (Songlengths.md5)")
        }
        return nil
    }

    /// A file as it was kept: what its kept name says it is, if what is in it agrees.
    public static func readBack(keptName: String, data: [UInt8]) -> KeptFile? {
        guard let file = recognise(data), file.keptName == keptName else { return nil }
        return file
    }

    /// True if a file of `size` bytes beginning with `start` may be one that siday keeps, for a look
    /// through many files that reads only those that may: the size of a ROM Munt or Nuked SC-55 knows, or the
    /// start of a list of song lengths.
    public static func mayBe(size: Int, start: [UInt8]) -> Bool {
        MT32ROMFile.known.contains { $0.size == size } || SC55ROMFile.sizes.contains(size) || mayBeSongLengths(start)
    }

    /// HVSC's list begins with a heading, "[Database]"; one that begins with a comment line is looked at too.
    private static func mayBeSongLengths<Bytes: Collection>(_ start: Bytes) -> Bool where Bytes.Element == UInt8 {
        let text = Array(start.drop { $0 == 0xEF || $0 == 0xBB || $0 == 0xBF || $0 == 0x20 || $0 == 0x0D || $0 == 0x0A })
        return text.starts(with: Array("[Database]".utf8)) || text.first == 0x3B
    }
}

/// The files siday keeps (see `KeptFile`), with what they are for: the MT-32's ROMs that make a whole set
/// of the LAPC-I's kind, the SC-55's that make a whole SC-55, and the list of song lengths. A front end keeps them where it keeps its own things,
/// and hands them here as they are read back, and as they are given.
public struct KeptFiles: Sendable {
    public private(set) var files: [KeptFile] = []
    private var contents: [String: [UInt8]] = [:]
    /// The ROMs kept, made into a set for the LAPC-I's synthesiser; nil while they do not make one.
    public private(set) var mt32ROMs: MT32ROMSet?
    /// The ROMs kept, made into a whole SC-55; nil while they do not make one.
    public private(set) var sc55ROMs: SC55ROMSet?
    /// The list of song lengths kept, if one is.
    public private(set) var songLengths: SongLengthDatabase?

    public init() {}

    /// Takes a file if it is one siday keeps.
    /// - Returns: what it is, and the kept files it replaces (a list of song lengths replaces the one kept
    ///   before: one is used); nil for a file that is not one, or is kept already.
    @discardableResult
    public mutating func add(_ data: [UInt8]) -> (file: KeptFile, replaced: [KeptFile])? {
        guard let file = KeptFile.recognise(data) else { return nil }
        return take(file, data)
    }

    /// Takes each of these files that is one siday keeps, as `add(_:)` does, and puts together what they
    /// make once, after taking them all.
    public mutating func add(eachOf datas: [[UInt8]]) {
        for data in datas {
            if let file = KeptFile.recognise(data) { _ = take(file, data, updating: false) }
        }
        update()
    }

    /// Takes a file read back from where it was kept, under its kept name.
    @discardableResult
    public mutating func add(keptName: String, data: [UInt8]) -> KeptFile? {
        guard let file = KeptFile.readBack(keptName: keptName, data: data) else { return nil }
        return take(file, data)?.file
    }

    private mutating func take(_ file: KeptFile, _ data: [UInt8], updating: Bool = true) -> (file: KeptFile, replaced: [KeptFile])? {
        guard !files.contains(file) else { return nil }
        let replaced = file.kind == .songLengths ? files.filter { $0.kind == .songLengths } : []
        for old in replaced { remove(old) }
        files.append(file)
        contents[file.keptName] = data
        if updating { update() }
        return (file, replaced)
    }

    public mutating func forget(_ file: KeptFile) {
        remove(file)
        update()
    }

    public mutating func forgetAll() {
        files = []
        contents = [:]
        update()
    }

    private mutating func remove(_ file: KeptFile) {
        files.removeAll { $0 == file }
        contents[file.keptName] = nil
    }

    /// The bytes of a file kept.
    public func data(of file: KeptFile) -> [UInt8]? { contents[file.keptName] }

    private mutating func update() {
        let roms = files.filter { $0.kind == .mt32ROM }.compactMap { contents[$0.keptName] }
        mt32ROMs = roms.isEmpty ? nil : MT32ROMSet.assemble(roms)
        let canvas = files.filter { $0.kind == .sc55ROM }.compactMap { contents[$0.keptName] }
        sc55ROMs = canvas.isEmpty ? nil : SC55ROMSet.assemble(canvas, reusing: sc55ROMs)
        songLengths = files.last { $0.kind == .songLengths }.flatMap { contents[$0.keptName] }.map { SongLengthDatabase($0) }
    }

    /// What is kept, and what it does, a line for each, for a listener: nothing if nothing is kept.
    public var summary: [String] {
        var lines: [String] = []
        let roms = files.filter { $0.kind == .mt32ROM }
        if let set = mt32ROMs {
            lines.append("MIDI files written for the MT-32 are played on the LAPC-I's synthesiser (" + set.control.name + ").")
        } else if !roms.isEmpty {
            let control = roms.contains { MT32ROMFile.identify(size: $0.size, sha1: $0.sha1).map { file in file.kind == .control && file.whole.hasPrefix("ctrl_cm32l_") } ?? false }
            let pcm = roms.contains { MT32ROMFile.identify(size: $0.size, sha1: $0.sha1)?.whole == "pcm_cm32l" }
            lines.append("The MT-32 ROMs kept are not yet a whole CM-32L or LAPC-I set: it wants "
                + (control && !pcm ? "its PCM ROM" : !control && pcm ? "its control ROM" : "its control ROM and its PCM ROM")
                + "; MT-32 files are played on FM until then.")
        }
        // The ROMs of the set in use by name, and the others counted.
        let used = Set(mt32ROMs.map { set in roms.filter { rom in Self.belongs(rom, to: set.control) } } ?? [])
        for file in roms where used.contains(file) { lines.append("Kept: " + file.name) }
        let others = roms.count - used.count
        if others > 0 { lines.append("Kept: \(others) other MT-32 ROM" + (others == 1 ? "" : "s") + ", not used") }
        let canvas = files.filter { $0.kind == .sc55ROM }
        if let set = sc55ROMs {
            lines.append("MIDI files written for General MIDI, GS and XG are played on the " + set.name
                + (mt32ROMs == nil ? ", and those written for the MT-32 there too, on its MT-32 sounds." : "."))
        } else if !canvas.isEmpty {
            lines.append("The SC-55 ROMs kept are not yet a whole SC-55 (firmware " + SC55ROMSet.versions.joined(separator: ", ")
                + "): it wants its two program ROMs and its three wave ROMs; MIDI files are played on FM until then.")
        }
        for file in canvas { lines.append("Kept: " + file.name) }
        for file in files where file.kind == .songLengths { lines.append("Kept: " + file.name) }
        return lines
    }

    /// True for a ROM file that is part of the set of a control ROM: the control ROM itself, or the PCM ROM
    /// that goes with it, or a half of either.
    private static func belongs(_ file: KeptFile, to control: MT32ControlROM) -> Bool {
        guard let rom = MT32ROMFile.identify(size: file.size, sha1: file.sha1) else { return false }
        if rom.kind == .control { return rom.whole == control.rawValue }
        // (The first half of the CM-32L's PCM ROM is the MT-32's whole one.)
        return control.isCM32LKind ? rom.whole == "pcm_cm32l" || rom.id == "pcm_mt32" : rom.whole == "pcm_mt32"
    }
}
