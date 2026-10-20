// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ProWizard for libxmp (src/loaders/prowizard), Copyright (C) 1997-1999 Sylvain "Asle"
// Chipaux and Copyright (C) 1996-2021 Claudio Matsuoka and Hipolito Carraro Jr, used under the MIT
// licence (see THIRD-PARTY.md).

/// Modules packed to be played in a game or a demo. A ProTracker module keeps its notes as four bytes
/// each, room for anything, and most of them nothing; so the programmers who put the music into their
/// games packed it, each with a packer of their own or of their group's, into something smaller that
/// a replayer of their own read: The Player, NoisePacker, ProRunner and the rest. What was packed was
/// a ProTracker module, and that is what each is unpacked to again here, to be played as ProTracker
/// played it. Sylvain Chipaux's ProWizard knew how to unpack each; libxmp keeps it, and this is a port
/// of the part of it these files need.
enum ProWizard {
    /// The packers, in the order libxmp asks each whether a file is its: a file another packer's test
    /// would also take is taken by the first. (SoundTracker 2.6's, which libxmp loads as a format of
    /// its own, is asked last.)
    enum Packer: CaseIterable {
        case ac1d, novotrade, promizer18, proRunner1, proRunner2, pha, trackerPacker3, digitalIllusions
        case player4, proPacker21, proPacker30, player50, player60, player61
        case noisePacker2, noisePacker1, noisePacker3, gameMusicCreator, iceTracker

        /// What it is called, as ProWizard calls it.
        var name: String {
            switch self {
            case .ac1d: "AC1D Packer"
            case .novotrade: "Novotrade Packer"
            case .promizer18: "Promizer 1.8a"
            case .proRunner1: "Prorunner 1.0"
            case .proRunner2: "Prorunner 2.0"
            case .pha: "Pha Packer"
            case .trackerPacker3: "Tracker Packer v3"
            case .digitalIllusions: "Digital Illusions"
            case .player4: "The Player 4.x"
            case .proPacker21: "ProPacker 2.1"
            case .proPacker30: "ProPacker 3.0"
            case .player50: "The Player 5.0a"
            case .player60: "The Player 6.0a"
            case .player61: "The Player 6.1a"
            case .noisePacker2: "NoisePacker v2"
            case .noisePacker1: "NoisePacker v1"
            case .noisePacker3: "NoisePacker v3"
            case .gameMusicCreator: "Game Music Creator"
            case .iceTracker: "SoundTracker 2.6"
            }
        }

        /// ProWizard's test of whether a file is one of this packer's, given the file and how much of
        /// it has been read, as ProWizard reads it (see `packer(of:)`): nought if it is, less than
        /// nought if it is not, and more than nought for how many bytes more it needs to say. (A test
        /// looks at no more of the file than it has been given, and asks for more with `request`.)
        func test(_ data: [UInt8], _ size: Int) -> Int {
            switch self {
            case .ac1d: AC1DPacker.test(data, size)
            case .novotrade: NovotradePacker.test(data, size)
            case .promizer18: Promizer.test(data, size)
            case .proRunner1: ProRunner.test1(data, size)
            case .proRunner2: ProRunner.test2(data, size)
            case .pha: PhaPacker.test(data, size)
            case .trackerPacker3: TrackerPacker3.test(data, size)
            case .digitalIllusions: DigitalIllusions.test(data, size)
            case .player4: ThePlayer4.test(data, size)
            case .proPacker21: ProPacker.test21(data, size)
            case .proPacker30: ProPacker.test30(data, size)
            case .player50: ThePlayer.test50(data, size)
            case .player60: ThePlayer.test60(data, size)
            case .player61: ThePlayer61.test(data, size)
            case .noisePacker2: NoisePacker.test2(data, size)
            case .noisePacker1: NoisePacker.test1(data, size)
            case .noisePacker3: NoisePacker.test3(data, size)
            case .gameMusicCreator: GameMusicCreator.test(data, size)
            case .iceTracker: IceTracker.test(data, size)
            }
        }

        /// Unpacks a file this packer's test took into the ProTracker module it was packed from.
        func depack(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
            switch self {
            case .ac1d: try AC1DPacker.depack(&input, &output)
            case .novotrade: try NovotradePacker.depack(&input, &output)
            case .promizer18: try Promizer.depack(&input, &output)
            case .proRunner1: try ProRunner.depack1(&input, &output)
            case .proRunner2: try ProRunner.depack2(&input, &output)
            case .pha: try PhaPacker.depack(&input, &output)
            case .trackerPacker3: try TrackerPacker3.depack(&input, &output)
            case .digitalIllusions: try DigitalIllusions.depack(&input, &output)
            case .player4: try ThePlayer4.depack(&input, &output)
            case .proPacker21: try ProPacker.depack21(&input, &output)
            case .proPacker30: try ProPacker.depack30(&input, &output)
            case .player50: try ThePlayer.depack50(&input, &output)
            case .player60: try ThePlayer.depack60(&input, &output)
            case .player61: try ThePlayer61.depack(&input, &output)
            case .noisePacker2: try NoisePacker.depack2(&input, &output)
            case .noisePacker1: try NoisePacker.depack1(&input, &output)
            case .noisePacker3: try NoisePacker.depack3(&input, &output)
            case .gameMusicCreator: try GameMusicCreator.depack(&input, &output)
            case .iceTracker: try IceTracker.depack(&input, &output)
            }
        }
    }

    /// The packer a file is from, if it is from one of them. Each test is given the first 64 KB of
    /// the file, or all of it if it is shorter, and given more when it asks, in steps of 4 KB; one that
    /// asks for more than the file has is taken to have said no. (`pw_check`, reading a file)
    ///
    /// A request that cannot be met still reads what is left of the file, without its being given to
    /// the test; so after one, any request finds nothing more to read, and is not met either.
    static func packer(of data: [UInt8]) -> Packer? {
        var size = min(data.count, 0x10000)
        var atTheEnd = false
        var packers = Packer.allCases[...]
        while let packer = packers.first {
            let answer = packer.test(data, size)
            if answer == 0 { return packer }
            if answer > 0 {
                // (Compared before it is rounded up, which could be more than a whole number holds in
                // a browser, where it has 32 bits.)
                if !atTheEnd, answer <= data.count - size {
                    size += min((answer + 0xFFF) & ~0xFFF, data.count - size)
                    continue
                }
                atTheEnd = true
            }
            packers = packers.dropFirst()
        }
        return nil
    }

    /// For a test: how many bytes more it needs, if it has been given fewer than `needed`, and
    /// otherwise nil. (`PW_REQUEST_DATA`)
    static func request(_ size: Int, _ needed: Int) -> Int? {
        size < needed ? needed - size : nil
    }

    /// The ProTracker module a packed file was packed from, and the packer's name; nil if it is not
    /// one of theirs, or does not unpack. As in libxmp, a file that is read past its end in the
    /// unpacking is taken not to unpack.
    static func unpack(_ data: [UInt8]) -> (packer: String, module: [UInt8])? {
        guard let packer = packer(of: data) else { return nil }
        var input = PackedReader(data)
        var output = ModuleWriter()
        do {
            try packer.depack(&input, &output)
        } catch {
            return nil
        }
        guard !input.failed else { return nil }
        var module = output.bytes
        // A Pha Packer file does not say how long its song is, and ProWizard counts it to the last place
        // in the order that plays a pattern other than the first: so one whose every place plays that
        // one pattern, a jingle, comes out as a song of no length. It is a song of that pattern once.
        // (This is the player's own, not ProWizard's; UADE plays such a file for as long.)
        if packer == .pha, module.count > 950, module[950] == 0 { module[950] = 1 }
        return (packer.name, module)
    }

    /// The byte at a place in a file, for a test; nought past its end. (A test looks no further than
    /// it has asked for, so this is only ever past the end of a file that is not the packer's.)
    static func byte(_ data: [UInt8], _ at: Int) -> Int {
        at >= 0 && at < data.count ? Int(data[at]) : 0
    }

    /// Two bytes at a place in a file, the first the higher, for a test. (`readmem16b`)
    static func word(_ data: [UInt8], _ at: Int) -> Int {
        byte(data, at) << 8 | byte(data, at + 1)
    }

    /// Four bytes at a place in a file, the first the highest, for a test. (`readmem32b`)
    static func long(_ data: [UInt8], _ at: Int) -> Int {
        word(data, at) << 16 | word(data, at + 2)
    }

    /// The endings of the names of files packed by these packers, as UnExoticA and others name them.
    static let extensions: Set<String> = [
        "ac1d", "ntp", "prun", "pru1", "pru2", "pha", "tp3", "di", "p4x", "p40a", "p40b", "p41a",
        "pp21", "pp30", "p50a", "p60", "p60a", "p6x", "p61", "p61a", "np1", "np2", "np3", "gmc", "pro", "pr1", "pm1", "pm18a", "st26", "ice",
    ]

    /// The periods of ProTracker's three octaves, as the two bytes a note is written in: the first
    /// for no note. (`ptk_table`)
    static let notes: [(UInt8, UInt8)] = [
        (0x00, 0x00),
        (0x03, 0x58), (0x03, 0x28), (0x02, 0xFA), (0x02, 0xD0), (0x02, 0xA6), (0x02, 0x80),
        (0x02, 0x5C), (0x02, 0x3A), (0x02, 0x1A), (0x01, 0xFC), (0x01, 0xE0), (0x01, 0xC5),
        (0x01, 0xAC), (0x01, 0x94), (0x01, 0x7D), (0x01, 0x68), (0x01, 0x53), (0x01, 0x40),
        (0x01, 0x2E), (0x01, 0x1D), (0x01, 0x0D), (0x00, 0xFE), (0x00, 0xF0), (0x00, 0xE2),
        (0x00, 0xD6), (0x00, 0xCA), (0x00, 0xBE), (0x00, 0xB4), (0x00, 0xAA), (0x00, 0xA0),
        (0x00, 0x97), (0x00, 0x8F), (0x00, 0x87), (0x00, 0x7F), (0x00, 0x78), (0x00, 0x71),
    ]

    /// True for a note that is in `notes`. (`PTK_IS_VALID_NOTE`)
    static func isNote(_ note: Int) -> Bool { note >= 0 && note < notes.count }

    /// The four letters ProTracker writes after the order of patterns: "M.K.".
    static let proTrackerLetters: UInt32 = 0x4D2E_4B2E
}

/// A packed file, read as libxmp reads a file: in the Amiga's order, high byte first, and a read past
/// the end gives what a read of a file past its end gives there (every bit set). Each keeps one error,
/// as libxmp does: a read past the end marks it as at the end, which the next seek clears; a seek to
/// before the start marks it as refused, which a seek does not clear but a later read past the end
/// replaces; and taking the error clears either. (`HIO_HANDLE` and `hio_read8` and the rest)
struct PackedReader {
    let data: [UInt8]
    private(set) var position = 0
    private enum Error { case none, atTheEnd, refused }
    private var error = Error.none

    /// True while there is an error: of something read past the end since the last seek, or of a seek
    /// to before the start; either since the error was last taken.
    var failed: Bool { error != .none }

    init(_ data: [UInt8]) {
        self.data = data
    }

    var size: Int { data.count }

    /// (`hio_seek` from the start)
    mutating func seek(_ place: Int) {
        guard place >= 0 else {
            error = .refused
            return
        }
        position = place
        if error == .atTheEnd { error = .none }
    }

    /// (`hio_seek` from where the reading is)
    mutating func skip(_ count: Int) {
        seek(position + count)
    }

    /// Whether there is an error, as `failed` says; and the error is cleared. (`hio_error`)
    mutating func takeError() -> Bool {
        let was = failed
        error = .none
        return was
    }

    mutating func read8() -> UInt8 {
        guard position < data.count else {
            error = .atTheEnd
            return 0xFF
        }
        position += 1
        return data[position - 1]
    }

    /// (A read that finds only one of its bytes takes it, as reading a file does, and fails.)
    mutating func read16b() -> UInt16 {
        guard position + 2 <= data.count else {
            position = max(position, data.count)
            error = .atTheEnd
            return 0xFFFF
        }
        position += 2
        return UInt16(data[position - 2]) << 8 | UInt16(data[position - 1])
    }

    mutating func read32b() -> UInt32 {
        guard position + 4 <= data.count else {
            position = max(position, data.count)
            error = .atTheEnd
            return 0xFFFF_FFFF
        }
        position += 4
        return UInt32(data[position - 4]) << 24 | UInt32(data[position - 3]) << 16 | UInt32(data[position - 2]) << 8 | UInt32(data[position - 1])
    }

    /// Up to `count` bytes, fewer if the file ends first, which fails. (`hio_read`)
    mutating func read(_ count: Int) -> [UInt8] {
        let start = min(position, data.count)
        let end = min(data.count, start + max(0, count))
        if end - start < count { error = .atTheEnd }
        position = end
        return Array(data[start ..< end])
    }
}

/// The ProTracker module being written, byte after byte. (The `FILE` a ProWizard depacker writes to,
/// and `write8` and the rest.)
struct ModuleWriter {
    private(set) var bytes: [UInt8] = []

    init() {
        bytes.reserveCapacity(65536)
    }

    mutating func write8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func write16b(_ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    mutating func write32b(_ value: UInt32) {
        bytes.append(UInt8(value >> 24))
        bytes.append(UInt8(value >> 16 & 0xFF))
        bytes.append(UInt8(value >> 8 & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    mutating func write(_ values: [UInt8]) {
        bytes.append(contentsOf: values)
    }

    mutating func write(_ values: ArraySlice<UInt8>) {
        bytes.append(contentsOf: values)
    }

    /// So many noughts. (`pw_write_zero`)
    mutating func writeZero(_ count: Int) {
        if count > 0 { bytes.append(contentsOf: repeatElement(0, count: count)) }
    }

    /// Copies up to `count` bytes from where the file is being read, fewer if it ends first, which
    /// marks the reading as failed. (`pw_move_data`)
    mutating func move(_ count: Int, from input: inout PackedReader) {
        bytes.append(contentsOf: input.read(count))
    }
}
