// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// the layout of an MT2 file and what is made of it (`soundlib/Load_mt2.cpp`, with the way its
// samples are packed from `soundlib/SampleIO.cpp`), and what OpenMPT's player does differently for
// these files (`soundlib/Snd_fx.cpp`, `soundlib/Sndmix.cpp`).

import SidayFoundation

/// An MT2 file: MadTracker 2's kind of module.
///
/// MadTracker was a tracker for Windows by Yannick Delwiche, from the late nineties until about 2004:
/// up to 64 tracks, instruments with envelopes for volume, place, pitch and a resonant filter that
/// did what Impulse Tracker's do, samples of eight bits or sixteen and in stereo, a row of
/// FastTracker's commands and Impulse Tracker's both, eight tracks of drums laid out as a drum
/// machine's, and effects of its own on each track, VST plug-ins and envelopes drawn over a
/// pattern for any setting ("automation"). Its own player has never been published, and nor has
/// the format; OpenMPT reads it, and is the only other player that does.
///
/// OpenMPT reads one of these files into the shape of an IT file, and plays it as it plays one,
/// with a few ways of FastTracker's where MadTracker had them. So it is played here: by Impulse
/// Tracker's replayer, keeping time in OpenMPT's ways (see `OpenMPTSong`), and taught those few
/// ways (`IT2Module.madTracker`). Its commands become Impulse Tracker's under the letters that do
/// the same: a FastTracker command by FastTracker's meaning, an Impulse Tracker command as itself,
/// and MadTracker's own by what OpenMPT makes of them.
///
/// Left out, as OpenMPT leaves them out: the tracks' own effects, the automation, the VST plug-ins,
/// samples kept in files of their own, and MadTracker's commands that OpenMPT does not know. Each
/// that a file has is named in its shortfalls. An instrument that is a plug-in plays nothing, and a
/// file whose notes are half of them or more for such instruments is refused.
enum MT2File {
    // MARK: Reading

    /// A part of the file, read from its start on: whatever is asked for beyond its end is nought,
    /// and a length too large to be one in a file is brought down to one that is still too large.
    /// (A whole number in a browser has 32 bits.)
    private struct Reader {
        let data: [UInt8]
        private(set) var at: Int
        let end: Int

        init(_ data: [UInt8], from start: Int = 0, to end: Int? = nil) {
            self.data = data
            let last = max(0, min(end ?? data.count, data.count))
            self.end = last
            at = max(0, min(start, last))
        }

        var left: Int { end - at }

        mutating func skip(_ count: Int) {
            at = count >= left ? end : at + max(0, count)
        }

        mutating func u8() -> Int {
            guard at < end else { return 0 }
            at += 1
            return Int(data[at - 1])
        }

        mutating func s8() -> Int { Int(Int8(truncatingIfNeeded: u8())) }

        mutating func u16() -> Int {
            let low = u8()
            return low | u8() << 8
        }

        mutating func s16() -> Int { Int(Int16(truncatingIfNeeded: u16())) }

        /// Four bytes as a length or a count.
        mutating func u32() -> Int {
            let low = u16(), high = u16()
            return high >= 0x4000 ? 0x3FFF_FFFF : high << 16 | low
        }

        /// Four bytes as bits.
        mutating func bits32() -> UInt32 {
            let low = UInt32(u16())
            return low | UInt32(u16()) << 16
        }

        mutating func double() -> Double {
            var bits: UInt64 = 0
            for i in 0 ..< 8 { bits |= UInt64(u8()) << UInt64(i * 8) }
            return Double(bitPattern: bits)
        }

        /// The next `count` bytes as a part of their own, passed over; as much of them as there is.
        mutating func chunk(_ count: Int) -> Reader {
            let taken = max(0, min(count, left))
            let part = Reader(data, from: at, to: at + taken)
            at += taken
            return part
        }

        /// Text of so many bytes at most, up to a nought, in Windows's letters.
        mutating func text(_ count: Int) -> String {
            let start = at
            skip(count)
            return ByteReader(Array(data[start ..< at])).encoded(at: 0, length: at - start, as: .windows1252)
        }

        /// Text up to a nought, which is passed over.
        mutating func cString() -> [UInt8] {
            var bytes: [UInt8] = []
            while at < end {
                let byte = data[at]
                at += 1
                if byte == 0 { break }
                bytes.append(byte)
            }
            return bytes
        }
    }

    /// The header: the first 126 bytes.
    private struct Header {
        var version = 0
        var title = "", tracker = ""
        var orders = 0, restart = 0, patterns = 0, channels = 0
        var samplesPerTick = 0, ticksPerLine = 0, linesPerBeat = 0
        var flags = 0, instruments = 0, samples = 0

        static let packedPatterns = 1, automation = 2, drumsAutomation = 8, masterAutomation = 16

        init(_ r: inout Reader) {
            r.skip(4 + 4)
            version = r.u16()
            tracker = r.text(32)
            title = r.text(64)
            orders = r.u16()
            restart = r.u16()
            patterns = r.u16()
            channels = r.u16()
            samplesPerTick = r.u16()
            ticksPerLine = r.u8()
            linesPerBeat = r.u8()
            flags = r.u16()
            r.skip(2)
            instruments = r.u16()
            samples = r.u16()
        }
    }

    /// True for a file that says it is one of these, as OpenMPT knows one.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 126 + 256, data.starts(with: Array("MT20".utf8)) else { return false }
        let f = ByteReader(data)
        let version = f.u16le(8), orders = f.u16le(106), channels = f.u16le(112), instruments = f.u16le(122), samples = f.u16le(124)
        return version >= 0x200 && version < 0x300 && channels >= 1 && channels <= 64 && orders <= 256 && instruments < 256 && samples < 4000
    }

    /// One track's part of a row, as the file has it.
    private struct Cell {
        var note = 0, instrument = 0, volume = 0, pan = 0, command = 0, value1 = 0, value2 = 0

        init() {}

        init(_ r: inout Reader) {
            note = r.u8()
            instrument = r.u8()
            volume = r.u8()
            pan = r.u8()
            command = r.u8()
            value1 = r.u8()
            value2 = r.u8()
        }
    }

    /// A pattern as the file has it: so many rows of the tracks' cells.
    private struct Pattern {
        var rows: Int
        var cells: [Cell]
    }

    /// An envelope as the file has it.
    private struct Envelope {
        var flags = 0, points = 0, sustain = 0, loopStart = 0, loopEnd = 0
        var ticks: [Int] = [], levels: [Int] = []
    }

    // MARK: Commands

    typealias Command = IT2ForeignModule.Command
    private static let commandM: UInt8 = 13, commandP: UInt8 = 16, commandW: UInt8 = 23, commandY: UInt8 = 25, commandZ: UInt8 = 26

    /// What a cell's command comes to.
    private enum Meaning {
        case nothing
        /// One of Impulse Tracker's, with its value.
        case command(UInt8, UInt8)
        /// A volume of 0 to 64 for the note, which Impulse Tracker has in its volume column only.
        case volume(UInt8)
        /// A fine slide of volume, up or down, on the row's first tick; by nought for as much as the
        /// last fine slide of volume on the channel, either way.
        case fineVolume(up: Bool, UInt8)
        /// A fine slide of pitch (or with `extra`, an extra fine one), down by E and up by F; by
        /// nought for as much as the last fine slide of pitch on the channel, of either kind.
        case finePitch(UInt8, extra: Bool, UInt8)
        /// One of MadTracker's or FastTracker's that is not played: which, by its place in `leftOutNames`.
        case leftOut(Int)
    }

    private static let leftOutNames = [
        "FastTracker's slide of the whole tune's volume",
        "FastTracker's key let go after so many ticks",
        "FastTracker's setting of where an envelope is",
        "MadTracker's commands that OpenMPT does not play either",
        "a note started further into its sample beside a delay",
    ]

    /// A slide's value as MadTracker took one with both its halves set: by the first, as
    /// FastTracker does. (Impulse Tracker does nothing at all with such a slide; and a fine slide
    /// in Impulse Tracker's way, which has F in one half, is no fine slide here.)
    private static func firstHalf(_ value: UInt8) -> UInt8 {
        value & 0xF0 != 0 ? value & 0xF0 : value & 0x0F
    }

    /// A slide between the speakers as MadTracker has one, to the right by its first half and to
    /// the left by its second, as Impulse Tracker has it: the other way round.
    private static func panSlide(_ value: UInt8) -> UInt8 {
        let slide = firstHalf(value)
        return slide >> 4 | slide << 4
    }

    /// Which of FastTracker's commands OpenMPT has a command of its own for, by their numbers.
    private static let fastTrackerCommands: [Bool] = (0 ..< 39).map { ![18, 19, 22, 23, 24, 26, 28, 30, 31].contains($0) }

    /// FastTracker's command `command` with its value, as OpenMPT plays it in one of these files.
    private static func fastTracker(_ command: Int, _ value: UInt8) -> Meaning {
        let high = value >> 4, low = value & 15
        switch command {
        case 0x0: return value == 0 ? .nothing : .command(Command.J, value)
        case 0x1: return .command(Command.F, value)
        case 0x2: return .command(Command.E, value)
        case 0x3: return .command(Command.G, value)
        case 0x4: return .command(Command.H, value)
        case 0x5: return .command(Command.L, firstHalf(value))
        case 0x6: return .command(Command.K, firstHalf(value))
        case 0x7: return .command(Command.R, value)
        case 0x8: return .command(Command.X, value)
        case 0x9: return .command(Command.O, value)
        case 0xA: return .command(Command.D, firstHalf(value))
        case 0xB: return .command(Command.B, value)
        case 0xC: return .volume(min(value, 64))
        // (The row to go to is written in tens and ones.)
        case 0xD: return .command(Command.C, UInt8(min(255, Int(high) * 10 + Int(low))))
        case 0xE:
            switch high {
            case 0x1: return .finePitch(Command.F, extra: false, low)
            case 0x2: return .finePitch(Command.E, extra: false, low)
            case 0x3: return .command(Command.S, 0x10 | low)
            case 0x4: return .command(Command.S, 0x30 | low & 3)
            case 0x5: return .command(Command.S, 0x20 | low)
            case 0x6: return .command(Command.S, 0xB0 | low)
            case 0x7: return .command(Command.S, 0x40 | low & 3)
            case 0x8: return .command(Command.S, 0x80 | low)
            case 0x9: return low == 0 ? .nothing : .command(Command.Q, low)
            case 0xA: return .fineVolume(up: true, low)
            case 0xB: return .fineVolume(up: false, low)
            case 0xC: return .command(Command.S, 0xC0 | low)
            case 0xD: return .command(Command.S, 0xD0 | low)
            case 0xE: return .command(Command.S, 0xE0 | low)
            default: return .nothing
            }
        case 0xF: return value < 0x20 ? (value == 0 ? .nothing : .command(Command.A, value)) : .command(Command.T, value)
        // (The tune's volume is of 64 to FastTracker, where Impulse Tracker's is of 128.)
        case 0x10: return .command(Command.V, UInt8(min(128, Int(value) * 2)))
        case 0x11: return .leftOut(0)
        case 0x14: return .leftOut(1)
        case 0x15: return .leftOut(2)
        case 0x19: return .command(commandP, panSlide(value))
        case 0x1B: return .command(Command.Q, value)
        case 0x1D: return .command(Command.I, value)
        case 0x21:
            if high == 1 { return .finePitch(Command.F, extra: true, low) }
            if high == 2 { return .finePitch(Command.E, extra: true, low) }
            return .nothing
        case 0x22: return .command(commandY, value)
        case 0x23: return .command(commandZ, value)
        default: return .nothing
        }
    }

    /// Impulse Tracker's command `command` (by its letter, from 1 for A) with its value, as OpenMPT
    /// plays it in one of these files: its slides of volume as FastTracker's, by their first half.
    private static func impulseTracker(_ command: Int, _ value: UInt8) -> Meaning {
        switch command {
        case 1 ... 26:
            let letter = UInt8(command)
            switch letter {
            case Command.D, Command.K, Command.L, commandW: return .command(letter, firstHalf(value))
            case commandP: return .command(commandP, panSlide(value))
            case Command.A: return value == 0 ? .nothing : .command(letter, value)
            default: return .command(letter, value)
            }
        // (OpenMPT's own two after Z: a macro sent a little at a time, and a note delayed and cut.)
        case 28, 29: return .command(UInt8(command), value)
        default: return .nothing
        }
    }

    /// A cell's command as OpenMPT reads it: what it comes to; whether it sets the speed or the
    /// tempo as FastTracker or Impulse Tracker does, which says how the file keeps time; and
    /// whether OpenMPT has a command in the cell's place for it, which says where else a place
    /// between the speakers given beside it goes.
    private static func meaning(_ cell: Cell) -> (meaning: Meaning, oldTempo: Bool, taken: Bool) {
        guard cell.command != 0 || cell.value1 != 0 || cell.value2 != 0 else { return (.nothing, false, false) }
        let v1 = UInt8(cell.value1), v2 = UInt8(cell.value2)
        /// Two values as one, as MadTracker's slides of pitch have them, as far as a byte goes.
        let joined = UInt8(min(255, Int(v2) << 4 | Int(v1) >> 4))
        switch cell.command {
        case 0x00:
            let taken = cell.value2 < fastTrackerCommands.count && fastTrackerCommands[cell.value2] && !(cell.value2 == 0 && v1 == 0)
            return (fastTracker(cell.value2, v1), cell.value2 == 0x0F, taken)
        case 0x01: return (.command(Command.F, joined), false, true)
        case 0x02: return (.command(Command.E, joined), false, true)
        case 0x03: return (.command(Command.G, joined), false, true)
        case 0x04: return (.command(Command.H, v2 & 0xF0 | v1 >> 4), false, true)
        case 0x08:
            if v1 != 0 { return (.command(Command.X, v1), false, true) }
            if v2 == 1 || v2 == 2 { return (.command(Command.S, 0x91), false, true) }
            return (.nothing, false, false)
        case 0x0C: return (.volume(min(64, v2 / 2)), false, true)
        case 0x0F: return (v2 != 0 ? .command(Command.T, v2) : v1 & 0x0F == 0 ? .nothing : .command(Command.A, v1 & 0x0F), false, true)
        case 0x10:
            let taken = (cell.value2 >= 1 && cell.value2 <= 31) || (cell.value2 == 0 && v1 != 0)
            return (impulseTracker(cell.value2, v1), cell.value2 == 1 || cell.value2 == 20, taken)
        case 0x1D: return (.command(Command.I, v1), false, true)
        case 0x20: return (.command(commandZ, v2 >> 1), false, true)
        case 0x22: return (.command(commandZ, (v2 & 0xF0) >> 1), false, true)
        case 0x24: return (.command(Command.S, 0x9F), false, true)
        case 0x80: return (.command(commandM, v2 / 4), false, true)
        case 0x9D: return (.leftOut(4), false, true)
        case 0xCC: return (.nothing, false, false)
        default: return (.leftOut(3), false, false)
        }
    }

    /// What the volume column has, as OpenMPT reads it.
    private enum VolumeColumn {
        case none
        case volume(UInt8)
        /// A slide of so much, up or down, on every tick but the first or (`fine`) on the first only.
        case slide(up: Bool, fine: Bool, UInt8)
    }

    private static func volumeColumn(_ volume: Int) -> VolumeColumn {
        let amount = UInt8(volume & 0x0F)
        switch volume {
        case 0x10 ... 0x90: return .volume(UInt8((volume - 0x10) / 2))
        case 0xA0 ... 0xAF: return .slide(up: false, fine: false, amount)
        case 0xB0 ... 0xBF: return .slide(up: true, fine: false, amount)
        case 0xC0 ... 0xCF: return .slide(up: false, fine: true, amount)
        case 0xD0 ... 0xDF: return .slide(up: true, fine: true, amount)
        default: return .none
        }
    }

    /// A slide of the volume column's as Impulse Tracker's volume column has it, which goes by up to
    /// nine (by nine for one that is by more: then `nearest` is true).
    private static func column(up: Bool, fine: Bool, _ amount: UInt8) -> (byte: UInt8, nearest: Bool) {
        let base: UInt8 = fine ? (up ? 65 : 75) : (up ? 85 : 95)
        return (base + min(9, amount), amount > 9)
    }

    /// The same slide as Impulse Tracker's command D: which can do all but a fine slide down by
    /// fifteen, which is by fourteen (and then `nearest` is true).
    private static func commandD(up: Bool, fine: Bool, _ amount: UInt8) -> (value: UInt8, nearest: Bool) {
        if !fine { return (up ? amount << 4 : amount, false) }
        if up { return (amount << 4 | 0x0F, false) }
        return (0xF0 | min(14, amount), amount > 14)
    }

    // MARK: The renderer

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> ITRenderer {
        guard isOne(data) else { throw TuneError.malformed("not an MT2 file") }
        var file = Reader(data)
        let header = Header(&file)
        let version = header.version
        let channels = header.channels

        var orders = (0 ..< 256).map { _ in file.u8() }
        orders = Array(orders.prefix(header.orders))

        // MadTracker reads the drums' 274 bytes whenever this says there are any, whatever it says
        // their length is, and so does OpenMPT.
        let hasDrums = file.u16() != 0
        var drumHeader = file.chunk(hasDrums ? 274 : 0)
        var extras = file.chunk(file.u32())

        // MARK: Patterns

        var patterns: [Pattern?] = []
        var oldTempo = false
        for _ in 0 ..< header.patterns {
            let rows = min(file.u16(), 1024)
            let length = file.u32()
            var chunk = file.chunk(length >= 0x3FFF_FFFF ? length : (length + 1) & ~1)
            guard rows > 0 else {
                patterns.append(nil)
                continue
            }
            var pattern = Pattern(rows: rows, cells: [Cell](repeating: Cell(), count: rows * channels))
            if header.flags & Header.packedPatterns != 0 {
                // A track at a time, from its first row down: each cell says which of its seven
                // parts it has, and may say it is the same for so many rows below.
                var row = 0, channel = 0
                while chunk.left >= 1 {
                    var info = chunk.u8()
                    var repeats = 0
                    if info == 0xFF {
                        repeats = chunk.u8()
                        info = chunk.u8()
                    }
                    if info & 0x7F != 0 {
                        var cell = Cell()
                        if info & 0x01 != 0 { cell.note = chunk.u8() }
                        if info & 0x02 != 0 { cell.instrument = chunk.u8() }
                        if info & 0x04 != 0 { cell.volume = chunk.u8() }
                        if info & 0x08 != 0 { cell.pan = chunk.u8() }
                        if info & 0x10 != 0 { cell.command = chunk.u8() }
                        if info & 0x20 != 0 { cell.value1 = chunk.u8() }
                        if info & 0x40 != 0 { cell.value2 = chunk.u8() }
                        for r in row ... min(rows - 1, row + repeats) { pattern.cells[r * channels + channel] = cell }
                    }
                    row += repeats + 1
                    channel += row / rows
                    row %= rows
                    if channel >= channels { break }
                }
            } else {
                for row in 0 ..< rows {
                    for channel in 0 ..< channels { pattern.cells[row * channels + channel] = Cell(&chunk) }
                }
            }
            for cell in pattern.cells where cell.command == 0 && cell.value2 == 0x0F || cell.command == 0x10 && (cell.value2 == 1 || cell.value2 == 20) {
                oldTempo = true
                break
            }
            patterns.append(pattern)
        }

        // MARK: What follows the header

        var tempo = 125.0, modern = false
        let speed = max(1, min(31, header.ticksPerLine))
        let rowsPerBeat = max(1, min(32, header.linesPerBeat))
        if header.samplesPerTick > 1, header.samplesPerTick < 5000 {
            if oldTempo {
                tempo = 110_250.0 / Double(header.samplesPerTick)
            } else {
                tempo = 44100.0 * 60.0 / Double(speed * rowsPerBeat * header.samplesPerTick)
                modern = true
            }
        }
        var preAmp = 48 * 2
        var channelVolumes = [UInt8](repeating: 64, count: MAX_HOST_CHANNELS)
        var author = ""
        var plugIns: [(name: String, track: Int)] = []
        var trackEffects = 0
        while extras.left >= 8 {
            let id = extras.bits32()
            var chunk = extras.chunk(extras.u32())
            switch id {
            case 0x2B4D_5042: // "BPM+"
                if !oldTempo {
                    modern = true
                    let beat = chunk.double()
                    if beat > 0.00000001 { tempo = 44100.0 * 60.0 / (Double(speed * rowsPerBeat) * beat) }
                }
            case 0x534B_5254: // "TRKS"
                // How loud the whole is, and then each track's volume and whether it has an effect
                // of its own: the drums' tracks too, if the file has them. (A song whose volume is
                // nought from its start, to be faded in by its automation, which is not played, is
                // given the usual, as OpenMPT gives it.)
                preAmp = chunk.u16() / 256
                if preAmp == 0 { preAmp = 48 }
                for channel in 0 ..< min(MAX_HOST_CHANNELS, channels + (hasDrums ? 8 : 0)) where chunk.left >= 1030 {
                    channelVolumes[channel] = UInt8(min(64, chunk.u16() >> 10))
                    if chunk.u8() != 0 { trackEffects += 1 }
                    chunk.skip(1029 - 2)
                }
            case 0x0047_534D: // "MSG\0"
                break
            case 0x004D_5553: // "SUM\0"
                chunk.skip(6)
                let name = chunk.cString()
                if name != Array("Unregistered".utf8) {
                    author = ByteReader(name).encoded(at: 0, length: name.count, as: .windows1252)
                }
            case 0x3254_5356: // "VST2"
                let count = chunk.u32()
                for _ in 0 ..< min(count, 255) where chunk.left >= 128 {
                    var dllPart = chunk.chunk(64)
                    var dll = dllPart.cString()
                    if dll.count > 4, dll[dll.count - 4] == 0x2E { dll.removeLast(4) } // ".dll"
                    chunk.skip(28 + 4 + 4 + 4)
                    let useChunks = chunk.u8() != 0
                    let track = chunk.u8()
                    chunk.skip(1 + 17)
                    let n = chunk.u32()
                    if version >= 0x250 { chunk.skip(16 * 4) }
                    chunk.skip(useChunks ? n : n <= 0x0FFF_FFFF ? n * 4 : chunk.left)
                    plugIns.append((ByteReader(dll).encoded(at: 0, length: dll.count, as: .windows1252), track))
                }
            default:
                break
            }
        }
        // MARK: Drums

        // Eight tracks after the others, each a sample played at C-5, from patterns of their own: a
        // row of each is four bytes, whether it plays and after how many ticks, and how loud, of
        // 255. Which drum pattern goes with which pattern is said for each place in the list.
        var drumSamples = [Int](repeating: 0, count: 8)
        var drumOrder = [Int](repeating: 0, count: 256)
        var drumPatterns: [Reader] = []
        if hasDrums {
            let count = drumHeader.u16()
            for i in 0 ..< 8 { drumSamples[i] = drumHeader.u16() }
            for i in 0 ..< 256 { drumOrder[i] = drumHeader.u8() }
            for _ in 0 ..< count {
                let rows = file.u16()
                drumPatterns.append(file.chunk(rows * 32))
            }
        }

        // MARK: Automation

        // Envelopes drawn over each pattern for the tracks' settings, which are passed over.
        var automated = 0
        if header.flags & Header.automation != 0 {
            let tracks = header.flags & Header.drumsAutomation != 0 && hasDrums ? channels + 8 : channels
            let envelopes = tracks + (version >= 0x250 ? plugIns.count : 0) + (header.flags & Header.masterAutomation != 0 ? 1 : 0)
            for _ in 0 ..< header.patterns {
                for _ in 0 ..< envelopes where file.left >= 4 {
                    var flags = version >= 0x203 ? file.bits32() : UInt32(file.u16())
                    if version >= 0x203 { file.skip(4) } else { file.skip(2) }
                    while flags != 0 {
                        if flags & 1 != 0 {
                            file.skip(4 + 4 * 64)
                            automated += 1
                        }
                        flags >>= 1
                    }
                }
            }
        }

        // MARK: Instruments

        struct Instrument {
            var exists = false
            var hasData = false
            var groups = 0
            var groupMap = [Int](repeating: 255, count: 96)
            var vibratoType = 0, vibratoSweep = 0, vibratoDepth = 0, vibratoRate = 0
            var fadeOut = 0, newNote = 0
            var flags = 0
            var envelopes = [Envelope?](repeating: nil, count: 4)
            var highPass = false, cutoff = 0, resonance = 0
            /// True for one that is a VST instrument or a MIDI device, and plays nothing here.
            var plugIn = false
        }
        var instruments = [Instrument](repeating: Instrument(), count: 255)
        for i in 0 ..< 255 {
            file.skip(32)
            var length = file.u32()
            if length == 32 { length += 108 + 72 * 4 }
            if version > 0x201, length > 0, length < 0x3FFF_FFFF { length += 4 }
            var chunk = file.chunk(length)
            guard i < header.instruments else { continue }
            instruments[i].exists = true
            guard length > 0 else { continue }
            var ins = Instrument(exists: true, hasData: true)
            ins.groups = chunk.u16()
            for n in 0 ..< 96 { ins.groupMap[n] = chunk.u8() }
            ins.vibratoType = chunk.u8()
            ins.vibratoSweep = chunk.u8()
            ins.vibratoDepth = chunk.u8()
            ins.vibratoRate = chunk.u8()
            ins.fadeOut = chunk.u16()
            ins.newNote = chunk.u16()
            if version >= 0x201 { ins.flags = chunk.u16() }
            var mask = version >= 0x202 ? Int(chunk.bits32() & 0xFF) : 3
            for which in 0 ..< 4 {
                if mask & 1 != 0 {
                    var envelope = Envelope()
                    envelope.flags = chunk.u8()
                    envelope.points = min(16, chunk.u8())
                    envelope.sustain = chunk.u8()
                    envelope.loopStart = chunk.u8()
                    envelope.loopEnd = chunk.u8()
                    chunk.skip(3)
                    for _ in 0 ..< 16 {
                        envelope.ticks.append(chunk.u16())
                        envelope.levels.append(max(0, min(64, chunk.u16())))
                    }
                    ins.envelopes[which] = envelope
                }
                mask >>= 1
            }
            if ins.flags != 0 {
                chunk.skip(1)
                ins.highPass = chunk.u8() == 1
                ins.cutoff = chunk.u16()
                ins.resonance = chunk.u8()
                chunk.skip(3)
                if ins.flags & 4 != 0 { ins.plugIn = true }
            }
            instruments[i] = ins
        }

        // MARK: Samples

        struct Sample {
            var exists = false
            var frames = 0, rate = 0, sixteen = false, stereo = false
            var loops = false, backAndForth = false, loopStart = 0, loopEnd = 0
            var volume = 0, pan = 0, surround = false, note = 0
            var synchronised = false, elsewhere = false, unsmoothed = false
            /// What the instruments' groups give it.
            var fineTune = 0, globalVolume = 64
            var vibratoType = 0, vibratoSweep = 0, vibratoDepth = 0, vibratoRate = 0
        }
        var samples = [Sample](repeating: Sample(), count: 256)
        for i in 0 ..< 256 {
            file.skip(32)
            let length = file.u32()
            var chunk = file.chunk(length)
            guard length > 0, i < header.samples else { continue }
            var s = Sample(exists: true)
            s.frames = chunk.u32()
            s.rate = chunk.u32()
            s.sixteen = chunk.u8() > 1
            s.stereo = chunk.u8() > 1
            let flags = chunk.u8()
            let loopType = chunk.u8()
            s.loopStart = chunk.u32()
            s.loopEnd = chunk.u32()
            s.volume = chunk.u16()
            let pan = chunk.s8()
            s.note = chunk.s8()
            if s.sixteen { s.frames /= 2 }
            if s.stereo { s.frames /= 2 }
            s.loops = loopType == 1 || loopType == 2
            s.backAndForth = loopType == 2
            // (-128 is in surround: in the middle, and the right side the other way up.)
            s.surround = pan == -128
            s.pan = pan + 128
            s.synchronised = flags & 2 != 0
            s.elsewhere = flags & 5 != 0
            s.unsmoothed = flags & 8 != 0
            samples[i] = s
        }

        // The groups: each instrument's samples, each with a volume and a tuning of its own. (These
        // are the samples' to OpenMPT, and the last instrument to name a sample is the one whose
        // group it has.)
        var noteMaps = [[Int]](repeating: [], count: 255)
        var synchronisedNotes = [[Bool]](repeating: [], count: 255)
        for index in 0 ..< min(header.instruments, 255) where instruments[index].hasData {
            var groups: [(sample: Int, volume: Int, pitch: Int)] = []
            for _ in 0 ..< instruments[index].groups {
                let sample = file.u8(), volume = file.u8(), pitch = file.s8()
                file.skip(5)
                groups.append((sample, volume, pitch))
            }
            let ins = instruments[index]
            guard !ins.plugIn else { continue }
            var map = [Int](repeating: 0, count: 96), synchronised = [Bool](repeating: false, count: 96)
            for note in 0 ..< 96 where ins.groupMap[note] < ins.groups {
                let group = groups[ins.groupMap[note]]
                let sample = group.sample + 1
                map[note] = sample
                if sample <= header.samples {
                    samples[sample - 1].vibratoType = ins.vibratoType & 3
                    samples[sample - 1].vibratoSweep = ins.vibratoSweep
                    samples[sample - 1].vibratoDepth = ins.vibratoDepth
                    samples[sample - 1].vibratoRate = ins.vibratoRate
                    samples[sample - 1].globalVolume = min(64, group.volume * 2)
                    samples[sample - 1].fineTune = group.pitch
                    synchronised[note] = samples[sample - 1].synchronised
                }
            }
            noteMaps[index] = map
            synchronisedNotes[index] = synchronised
        }

        // Their sound, one after another: each as the difference from the sample before, and the
        // right of a stereo sample as the difference from the left.
        var cutShort = Shortfall.CutShort()
        var sounds = [(left: [Int16], right: [Int16])](repeating: ([], []), count: 256)
        var elsewhere = 0
        for i in 0 ..< min(header.samples, 256) {
            let s = samples[i]
            if s.elsewhere {
                if s.exists { elsewhere += 1 }
                let nameLength = file.u32()
                file.skip(12)
                file.skip(nameLength)
                continue
            }
            guard s.exists, s.frames > 0 else { continue }
            let sides = s.stereo ? 2 : 1, size = s.sixteen ? 2 : 1
            let frames = min(s.frames, 1 << 26)
            cutShort.add(length: min(frames * sides * size, 1 << 29), there: file.left)
            var decoded: [[Int16]] = []
            for _ in 0 ..< sides {
                var sound = [Int16](repeating: 0, count: frames)
                var last = 0
                for k in 0 ..< frames {
                    guard file.left >= size else { break }
                    if s.sixteen {
                        last = (last + file.u16()) & 0xFFFF
                        sound[k] = Int16(truncatingIfNeeded: last)
                    } else {
                        last = (last + file.u8()) & 0xFF
                        sound[k] = Int16(Int8(truncatingIfNeeded: last)) << 8
                    }
                }
                decoded.append(sound)
            }
            if sides == 2 {
                for k in 0 ..< frames {
                    let sum = Int(decoded[1][k]) + Int(decoded[0][k])
                    decoded[1][k] = s.sixteen ? Int16(truncatingIfNeeded: sum) : Int16(Int8(truncatingIfNeeded: sum >> 8)) << 8
                }
            }
            sounds[i] = (decoded[0], sides == 2 ? decoded[1] : [])
        }

        // MARK: Into Impulse Tracker's samples

        // As many as a byte can name, which is 253: a file's sample is at its own number among
        // them, and one beyond them at the number of one the file does not have and nothing plays,
        // while there are such. (A file may say it has 256, and have sound in a few of them.) One
        // that finds no place is said to be left out.
        let sampleCount = max(IT2Module.MAX_SAMPLES, min(header.samples, IT2Module.mostSamples))
        var named = [Bool](repeating: false, count: 257)
        for i in 0 ..< min(header.instruments, 255) {
            if instruments[i].hasData { for sample in noteMaps[i] { named[sample] = true } } else { named[min(256, i + 1)] = true }
        }
        if hasDrums { for sample in drumSamples { named[min(256, sample + 1)] = true } }
        var place = [Int?](repeating: nil, count: 256)
        for i in 0 ..< min(sampleCount, 256) { place[i] = i }
        var free = (0 ..< min(sampleCount, 256)).filter { !samples[$0].exists && !named[$0 + 1] }
        var tooMany = 0
        for i in min(sampleCount, 256) ..< max(min(sampleCount, 256), min(header.samples, 256)) where samples[i].exists && !sounds[i].left.isEmpty {
            if free.isEmpty {
                tooMany += 1
            } else {
                place[i] = free.removeFirst()
            }
        }
        let made = (0 ..< sampleCount).map { _ in IT2Sample() }
        for i in 0 ..< 256 where samples[i].exists {
            guard let at = place[i] else { continue }
            let it = made[at]
            let s = samples[i]
            it.GlobVol = UInt8(s.globalVolume)
            it.Vol = UInt8(min(64, s.volume >> 9))
            it.DefPan = 0x80 | (s.surround ? PAN_SURROUND : UInt8(min(64, (s.pan + 2) / 4)))
            // The rate, from what the file gives for its own note (49 being C-5) and the tuning its
            // group gives it in 128ths of a semitone.
            let rate = Double(s.rate) * pow(2.0, (49.0 - Double(s.note) + Double(s.fineTune) / 128.0) / 12.0)
            it.C5Speed = UInt32(max(0, min(Double(UInt32.max), rate.rounded())))
            it.AutoVibratoSpeed = UInt8(s.vibratoRate)
            it.AutoVibratoDepth = UInt8(s.vibratoDepth)
            it.AutoVibratoRate = UInt8(s.vibratoSweep)
            it.AutoVibratoWaveform = UInt8(s.vibratoType)
            let left = sounds[i].left, right = sounds[i].right
            guard !left.isEmpty else { continue }
            let frames = left.count
            let memory = IT2Module.allocate(frames * 2)
            it.OrigData = memory
            it.Data = memory + IT2Module.SMP_DAT_OFFSET
            left.withUnsafeBytes { it.Data!.copyMemory(from: $0.baseAddress!, byteCount: frames * 2) }
            it.Flags = SMPF_ASSOCIATED_WITH_HEADER | SMPF_16BIT
            if right.count == frames {
                let memoryR = IT2Module.allocate(frames * 2)
                it.OrigDataR = memoryR
                it.DataR = memoryR + IT2Module.SMP_DAT_OFFSET
                right.withUnsafeBytes { it.DataR!.copyMemory(from: $0.baseAddress!, byteCount: frames * 2) }
                it.Flags |= SMPF_STEREO
            }
            it.Length = UInt32(frames)
            let loopEnd = min(s.loopEnd, frames)
            if s.loops, s.loopStart < loopEnd {
                it.LoopBegin = UInt32(s.loopStart)
                it.LoopEnd = UInt32(loopEnd)
                it.Flags |= SMPF_USE_LOOP | (s.backAndForth ? SMPF_LOOP_PINGPONG : 0)
            }
        }

        // MARK: Into Impulse Tracker's instruments

        // Every instrument that has groups is half as loud as its samples to OpenMPT, which plays
        // the whole twice as loud, because a drum can be louder than a note; and the drums and an
        // instrument with nothing of its own are as loud as their samples. (Impulse Tracker's
        // replayer has a sample's and an instrument's volumes multiplied together, of 128.)
        let drumBase = header.instruments
        let instrumentCount = min(IT2Module.mostInstruments, header.instruments + (hasDrums ? 8 : 0))
        var madeInstruments: [IT2Instrument] = []
        func sampleNumber(_ sample: Int) -> UInt16 { sample >= 1 && sample <= 256 ? place[sample - 1].map { UInt16($0 + 1) } ?? 0 : 0 }
        for i in 0 ..< max(IT2Module.MAX_INSTRUMENTS, instrumentCount) {
            let it = IT2Instrument()
            madeInstruments.append(it)
            // (The fade is kept as OpenMPT keeps it, finer than Impulse Tracker's: see `madTrackerFadeStep`.)
            it.FadeOut = 256
            it.GlobVol = 128
            if i >= drumBase, i < instrumentCount {
                // A drum: its sample on every note.
                let sample = sampleNumber(drumSamples[i - drumBase] + 1)
                for note in 0 ..< 120 { it.SmpNoteTable[note] = sample << 8 | UInt16(note) }
                continue
            }
            guard i < header.instruments, i < instrumentCount else {
                it.GlobVol = 0
                continue
            }
            let ins = instruments[i]
            guard ins.hasData else {
                // Nothing of its own: the sample of its number, on every note.
                let sample = sampleNumber(i + 1)
                for note in 0 ..< 120 { it.SmpNoteTable[note] = sample << 8 | UInt16(note) }
                continue
            }
            it.GlobVol = 64
            it.NNA = UInt8(ins.newNote & 3)
            it.DCT = UInt8((ins.newNote >> 8) & 3)
            it.DCA = [0, 2, 1, 2][(ins.newNote >> 12) & 3]
            var fadeOut = ins.fadeOut
            if !(ins.envelopes[0].map { $0.flags & 1 != 0 } ?? false), ins.newNote & 3 != 3 { fadeOut = 32767 }
            it.FadeOut = UInt16(min(0xFFFF, fadeOut))
            for which in 0 ..< 4 {
                guard let from = ins.envelopes[which] else { continue }
                var envelope = IT2Envelope()
                let enabled = from.flags & 1 != 0
                envelope.Flags = (enabled ? ENVF_ENABLED : 0) | (from.flags & 2 != 0 ? ENVF_SUSTAINLOOP : 0) | (from.flags & 4 != 0 ? ENVF_LOOP : 0)
                    | (which == 3 && enabled ? ENVF_TYPE_FILTER : 0)
                envelope.Num = UInt8(from.points)
                // (As OpenMPT makes them: loops within the points there are, and ticks that go on from nought.)
                let last = max(0, from.points - 1)
                envelope.SustainLoopBegin = UInt8(min(last, from.sustain))
                envelope.SustainLoopEnd = envelope.SustainLoopBegin
                envelope.LoopEnd = UInt8(min(last, from.loopEnd))
                envelope.LoopBegin = UInt8(min(Int(envelope.LoopEnd), from.loopStart))
                var tick = 0
                for p in 0 ..< from.points {
                    tick = p == 0 ? 0 : max(tick, from.ticks[p])
                    envelope.Tick[p] = UInt16(tick)
                    envelope.Magnitude[p] = Int8(which == 0 ? from.levels[p] : from.levels[p] - 32)
                }
                // (The envelope for the filter is the one for pitch to Impulse Tracker, and takes its place.)
                if which == 0 { it.VolEnv = envelope } else if which == 1 { it.PanEnv = envelope } else { it.PitchEnv = envelope }
            }
            // A note starts with its instrument's filter, wide open if it has none.
            it.FilterCutoff = 0x80 | 127
            it.FilterResonance = 0x80
            if ins.flags != 0 {
                if ins.flags & 2 != 0 {
                    it.FilterCutoff = 0x80 | cutoff(ins.cutoff)
                    it.FilterResonance = 0x80 | UInt8(min(127, ins.resonance))
                }
                it.FilterMode = ins.highPass ? 1 : 0
            }
            for note in 0 ..< 120 { it.SmpNoteTable[note] = UInt16(note) }
            guard !ins.plugIn else { continue }
            for note in 0 ..< 96 {
                let played = synchronisedNotes[i][note] ? 60 : note + 12
                it.SmpNoteTable[note + 12] = sampleNumber(noteMaps[i][note]) << 8 | UInt16(played)
            }
        }

        // MARK: Into Impulse Tracker's patterns

        // Only the patterns the list plays are kept, numbered as it first plays them: a file can
        // have more than Impulse Tracker's numbers reach, most of them never played. And a pattern
        // that the list plays with more than one drum pattern is made once for each.
        var firstDrums = [Int?](repeating: nil, count: header.patterns)
        func drums(at place: Int) -> Int? { hasDrums && place < 256 && drumOrder[place] < drumPatterns.count ? drumOrder[place] : nil }
        for (place, pattern) in orders.enumerated() where pattern < header.patterns && firstDrums[pattern] == nil { firstDrums[pattern] = drums(at: place) }
        var versions: [(pattern: Int, drums: Int?)] = []
        var list: [UInt8] = []
        for (place, pattern) in orders.enumerated() {
            guard pattern < header.patterns, patterns[pattern] != nil else {
                list.append(254)
                continue
            }
            let wanted = drums(at: place) ?? firstDrums[pattern]
            if let index = versions.firstIndex(where: { $0.pattern == pattern && $0.drums == wanted }) {
                list.append(UInt8(index))
            } else {
                guard versions.count < IT2Module.mostPatterns else { throw TuneError.unsupported("an MT2 file that plays more patterns than can be played") }
                list.append(UInt8(versions.count))
                versions.append((pattern, wanted))
            }
        }

        var leftOut = Shortfall.Kinds()
        var noRoom = 0, nearest = 0, notes = 0, plugInNotes = 0, elsewhereNotes = 0
        var silentInstruments = Set<Int>()
        var fineVolume = [UInt8](repeating: 0, count: MAX_HOST_CHANNELS), finePitch = [UInt8](repeating: 0, count: MAX_HOST_CHANNELS)
        var playing = [Int](repeating: 0, count: MAX_HOST_CHANNELS)
        let played = Set(list.filter { $0 < 254 }.map { Int($0) })

        func convert(_ from: Cell, channel: Int, counted: Bool) -> IT2ForeignModule.Cell {
            var cell = IT2ForeignModule.Cell()
            let isNote = from.note >= 1 && from.note <= 96
            if isNote {
                cell.set(note: UInt8(from.note + 11))
            } else if from.note > 96 {
                cell.set(note: 255)
            }
            if from.instrument != 0 {
                cell.set(instrument: UInt8(from.instrument))
                playing[channel] = from.instrument
            }
            if counted, isNote {
                // What will play it, as far as can be told from the rows above it.
                notes += 1
                let number = playing[channel]
                if number >= 1, number <= min(header.instruments, 255) {
                    if instruments[number - 1].plugIn {
                        plugInNotes += 1
                        silentInstruments.insert(number)
                    } else if !noteMaps[number - 1].isEmpty {
                        let sample = noteMaps[number - 1][from.note - 1]
                        if sample >= 1, sample <= 256, samples[sample - 1].elsewhere { elsewhereNotes += 1 }
                    }
                }
            }

            // What OpenMPT reads: a volume column and a command, and the place between the
            // speakers as the command if there is none, else in the volume column if that is free.
            let reading = meaning(from)
            let volume = volumeColumn(from.volume)
            var command: (UInt8, UInt8)?
            var setVolume: UInt8?
            switch reading.meaning {
            case .nothing: break
            case let .command(letter, value): command = (letter, value)
            case let .volume(value): setVolume = value
            case let .fineVolume(up, amount):
                // (MadTracker's fine slide of nought goes on with the last of them, up or down,
                // where Impulse Tracker's goes on with whatever slide of volume was last.)
                if amount != 0 { fineVolume[channel] = amount }
                let by = amount != 0 ? amount : fineVolume[channel]
                if by != 0 {
                    let d = commandD(up: up, fine: true, by)
                    command = (Command.D, d.value)
                    if d.nearest, counted { nearest += 1 }
                }
            case let .finePitch(letter, extra, amount):
                if amount != 0 { finePitch[channel] = amount }
                let by = amount != 0 ? amount : finePitch[channel]
                if by != 0 { command = (letter, (extra ? 0xE0 : 0xF0) | by) }
            case let .leftOut(kind):
                if counted { leftOut.note(kind) }
            }
            var panColumn = false
            if from.pan != 0 {
                if !reading.taken {
                    command = (Command.X, UInt8(from.pan))
                } else if case .none = volume {
                    panColumn = true
                } else if counted {
                    // (OpenMPT has no room for it either.)
                    noRoom += 1
                }
            }

            // And then Impulse Tracker's, whose volume column has slides by no more than nine, and
            // no place for a volume that is given as a command.
            switch volume {
            case .none: break
            case let .volume(value): cell.set(volume: value)
            case let .slide(up, fine, amount):
                if amount > 9, command == nil, setVolume == nil {
                    let d = commandD(up: up, fine: fine, amount)
                    command = (Command.D, d.value)
                    if d.nearest, counted { nearest += 1 }
                } else {
                    let c = column(up: up, fine: fine, amount)
                    cell.set(volume: c.byte)
                    if c.nearest, counted { nearest += 1 }
                }
            }
            if panColumn {
                if setVolume == nil {
                    cell.set(volume: 128 + UInt8(from.pan / 4))
                } else if command == nil {
                    command = (Command.X, UInt8(from.pan))
                } else if counted {
                    noRoom += 1
                }
            }
            if let setVolume {
                if cell.hasVolume, cell.volume > 64, counted { noRoom += 1 }
                cell.set(volume: setVolume)
            }
            if let command { cell.set(command: command.0, command.1) }
            return cell
        }

        /// The drums' part of a row: a C-5 on a drum's instrument, as loud as it says, after so many ticks.
        func drumCell(_ bytes: (Int, Int), drum: Int, counted: Bool) -> IT2ForeignModule.Cell {
            var cell = IT2ForeignModule.Cell()
            guard bytes.0 & 0x80 != 0, drumBase + drum < instrumentCount else { return cell }
            cell.set(note: 60)
            cell.set(instrument: UInt8(drumBase + drum + 1))
            let delay = min(15, bytes.0 & 0x1F)
            if delay != 0 { cell.set(command: Command.S, 0xD0 | UInt8(delay)) }
            cell.set(volume: UInt8((bytes.1 + 3) / 4))
            if counted { notes += 1 }
            return cell
        }

        var packed = [[UInt8]?](repeating: nil, count: IT2ForeignModule.patternRoom)
        var rowCounts = [UInt16](repeating: 0, count: IT2ForeignModule.patternRoom)
        var tooFewChannels = false
        // (In the order the list plays them, as near as can be, for what the channels remember.)
        var order: [Int] = []
        for number in list where number < 254 && !order.contains(Int(number)) { order.append(Int(number)) }
        for number in versions.indices where !order.contains(number) { order.append(number) }
        for number in order {
            guard let pattern = patterns[versions[number].pattern] else { continue }
            let rows = pattern.rows
            var it = IT2ForeignModule.Pattern(rows: rows)
            let counted = played.contains(number)
            for row in 0 ..< rows {
                for channel in 0 ..< channels {
                    let from = pattern.cells[row * channels + channel]
                    it[row, channel] = convert(from, channel: channel, counted: counted)
                }
            }
            if let drums = versions[number].drums {
                var d = drumPatterns[drums]
                let drumRows = (d.end - d.at) / 32
                for row in 0 ..< min(rows, drumRows) {
                    for drum in 0 ..< 8 {
                        let bytes = (d.u8(), d.u8())
                        d.skip(2)
                        guard channels + drum < MAX_HOST_CHANNELS else {
                            if bytes.0 & 0x80 != 0 { tooFewChannels = true }
                            continue
                        }
                        it[row, channels + drum] = drumCell(bytes, drum: drum, counted: counted)
                    }
                }
            }
            packed[number] = it.packed()
            rowCounts[number] = UInt16(rows)
        }

        // MARK: What is not heard

        if notes > 0, (plugInNotes + elsewhereNotes) * 2 >= notes {
            if plugInNotes >= elsewhereNotes { throw TuneError.unsupported("an MT2 file that is mostly for plug-ins") }
            throw TuneError.unsupported("an MT2 file most of whose samples are in other files")
        }
        var shortfalls: [String] = []
        if !silentInstruments.isEmpty {
            shortfalls.append(Shortfall.some(silentInstruments.count, one: "instruments is a plug-in, and is not heard.", many: "instruments are plug-ins, and are not heard."))
        }
        if elsewhere > 0 {
            shortfalls.append(Shortfall.some(elsewhere, one: "samples is in a file of its own, and is not heard.", many: "samples are in files of their own, and are not heard."))
        }
        if tooMany > 0 {
            shortfalls.append(Shortfall.some(tooMany, one: "samples is beyond the most that can be played, and is not heard.",
                                             many: "samples are beyond the most that can be played, and are not heard."))
        }
        if let sentence = Shortfall.plugInsLeftOut(plugIns.map { $0.name }, of: plugIns.count) { shortfalls.append(sentence) }
        if trackEffects > 0 {
            shortfalls.append(trackEffects == 1 ? "One of its tracks has an effect of MadTracker's own on its sound, which is left out."
                : Shortfall.capitalNumber(trackEffects) + " of its tracks have effects of MadTracker's own on their sound, which are left out.")
        }
        if automated > 0 { shortfalls.append("What it has drawn over its patterns to move its tracks' settings as they play (its automation) is left out.") }
        if noRoom > 0 {
            shortfalls.append(Shortfall.some(noRoom, one: "notes has more beside it than Impulse Tracker's replayer has room for, and the place between the speakers or the slide is left out.",
                                             many: "notes have more beside them than Impulse Tracker's replayer has room for, and a place between the speakers or a slide is left out of each."))
        }
        if nearest > 0 {
            shortfalls.append(Shortfall.some(nearest, one: "slides of volume is by more than there is room for beside its command, and goes by nine.",
                                             many: "slides of volume are by more than there is room for beside their commands, and go by nine."))
        }
        if tooFewChannels { shortfalls.append("Its drums are on more tracks than there is room for, and some are left out.") }
        if let sentence = Shortfall.commandsLeftOut(leftOut.named(leftOutNames)) { shortfalls.append(sentence) }
        if samples.contains(where: { $0.exists && $0.unsmoothed }) {
            shortfalls.append("A sample that is to be played without smoothing between its points is played smoothed.")
        }
        if let sentence = cutShort.sentence { shortfalls.append(sentence) }

        // MARK: The rest

        var song = OpenMPTSong()
        song.tempoMode = modern ? .modern : .classic
        song.rowsPerBeat = rowsPerBeat
        let unit = Double(OpenMPTSong.tempoUnit)
        var sequence = OpenMPTSong.Sequence()
        sequence.first = 0
        sequence.count = list.count
        sequence.restart = header.restart < list.count ? header.restart : 0
        sequence.speed = UInt8(speed)
        sequence.tempo = Int(max(Double(OpenMPTSong.leastTempo), min(Double(OpenMPTSong.mostTempo), tempo)) * unit + 0.5)
        song.sequences = [sequence]
        song.patternRowsPerBeat = [UInt16](repeating: 0, count: IT2ForeignModule.patternRoom)
        song.patternSwing = [[UInt32]](repeating: [], count: IT2ForeignModule.patternRoom)
        song.offsetAsImpulseTracker = true
        song.loopsOutlastJumps = false
        song.unmappedNotesKeepCommands = false
        let mixVolume = max(1, min(preAmp, 128))
        song.gain = Float(max(1, min(2000, preAmp))) / Float(mixVolume) * loudness

        let module = IT2Module(title: header.title, madeWith: header.tracker.isEmpty ? "MadTracker 2" : header.tracker, orders: list,
                               flags: ITF_STEREO | ITF_INSTR_MODE | ITF_LINEAR_FRQ | ITF_COMPAT_GXX | ITF_MPT_EXT_FILTER_RANGE, globalVolume: 128, mixVolume: UInt8(mixVolume),
                               speed: UInt8(speed), tempo: UInt8(max(31, min(255, Int(tempo)))), channelPans: [UInt8](repeating: 32, count: MAX_HOST_CHANNELS),
                               samples: made, patterns: packed, rows: rowCounts, instruments: madeInstruments, channelVolumes: channelVolumes,
                               openMPT: song, filter: .openMPTsCurve)
        module.madTracker = true
        return try ITRenderer(module: module, format: "MT2", author: author, shortfalls: shortfalls, options: options)
    }

    /// A filter's cutoff in hertz as one of Impulse Tracker's 128 settings, on the wider range of
    /// them that ModPlug Tracker gave it: as OpenMPT reckons it.
    private static func cutoff(_ hertz: Int) -> UInt8 {
        guard hertz > 0 else { return 0 }
        let setting = (log(Double(hertz)) - 4.8737671609324025) * (20.0 / log(2.0))
        return UInt8(max(0, min(127, setting)).rounded())
    }

    /// Set by measure: see the README.
    private static let loudness: Float = 1.6
}
