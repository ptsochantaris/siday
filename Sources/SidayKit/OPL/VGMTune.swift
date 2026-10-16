// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// VGM files (Video Game Music, by Valley Bell and others, from 2001): not a tune and its player, but
// what was written to a machine's sound chips while the music played, and when. Every write is in
// the file, in order, between waits counted in 44,100ths of a second; playing it back is a matter
// of writing the same to the same chip at the same moments. The format covers some fifty chips; of
// those, the Yamaha FM chips of the PC's AdLib and Sound Blaster cards are played here, on the OPL3
// that plays the other music made for those cards: the OPL (YM3526), the OPL2 (YM3812) and the OPL3
// (YMF262), and two of any of them. VGZ is the same file packed by gzip. The format is set out in
// vgmspecs.txt, which comes with VGMPlay; libvgm, its player, is what this was set beside.

/// A VGM file for the chips played here, read.
struct VGMFile {
    enum Chip: Int, CaseIterable {
        /// The YM3526, the OPL, the first of them, which has the sine wave only.
        case opl
        /// The YM3812, the OPL2: the AdLib's and the first Sound Blasters'.
        case opl2
        /// The YMF262, the OPL3, with eighteen channels and its two sides: the Sound Blaster Pro 2's and 16's.
        case opl3

        /// Where a file gives its clock.
        var place: Int {
            switch self {
            case .opl2: 0x50
            case .opl: 0x54
            case .opl3: 0x5C
            }
        }

        /// Its number among the format's chips, as the extra header names it.
        var number: Int {
            switch self {
            case .opl2: 0x09
            case .opl: 0x0A
            case .opl3: 0x0C
            }
        }
    }

    /// One of the chips a file is for, or two of the same: the second written to by commands of its own.
    struct Part {
        let chip: Chip
        let two: Bool
        /// Its clock, in Hz.
        let clock: Double
        /// What each one's sound is multiplied by: a half each, where there are two, so that two are
        /// as loud as one, unless the file says otherwise of either.
        var volumes: [Float]
    }

    let data: [UInt8]
    /// The chips, the FM chip first where there is one.
    let parts: [Part]
    /// Where the writes begin, where they end, and where they go round from, if they do.
    let start: Int, end: Int
    let loopStart: Int?
    /// How long the music is in 44,100ths of a second, to its end or to where it goes round the
    /// first time; and how long what goes round is.
    let ticks: Int, loopTicks: Int
    /// What the sound is multiplied by, as the file asks.
    let volume: Float
    /// True for two OPL2s that were a Sound Blaster Pro's, the first heard on the left and the
    /// second on the right; otherwise each is heard from the middle.
    let sides: Bool
    var title = "", game = "", system = "", author = "", date = "", notes = ""

    /// The other chips the format has, by where a file gives each one's clock, and their names, to
    /// say which one a file is for when it is not one of those played here.
    private static let others: [(place: Int, name: String)] = [
        (0x0C, "the SN76489 (a Sega Master System's or a BBC Micro's)"), (0x10, "the YM2413 (OPLL)"),
        (0x2C, "the YM2612 (a Sega Mega Drive's)"), (0x30, "the YM2151 (OPM)"), (0x38, "Sega's PCM chip"),
        (0x40, "the RF5C68"), (0x44, "the YM2203 (OPN)"), (0x48, "the YM2608 (OPNA)"), (0x4C, "the YM2610 (OPNB)"),
        (0x58, "the Y8950 (MSX-AUDIO)"), (0x60, "the YMF278B (OPL4)"), (0x64, "the YMF271 (OPX)"), (0x68, "the YMZ280B"),
        (0x6C, "the RF5C164"), (0x70, "the 32X's PWM"), (0x74, "the AY-3-8910"), (0x80, "the Game Boy's"),
        (0x84, "the NES's"), (0x88, "the MultiPCM"), (0x8C, "the uPD7759"), (0x90, "the OKIM6258"),
        (0x98, "the OKIM6295"), (0x9C, "Konami's SCC"), (0xA0, "the K054539"), (0xA4, "the PC Engine's HuC6280"),
        (0xA8, "the C140"), (0xAC, "the K053260"), (0xB0, "the Atari's POKEY"), (0xB4, "Capcom's QSound"),
        (0xB8, "the Saturn's SCSP"), (0xC0, "the WonderSwan's"), (0xC4, "the Virtual Boy's VSU"),
        (0xC8, "the SAA1099"), (0xCC, "the ES5503"), (0xD0, "the ES5506"), (0xD8, "the X1-010"),
        (0xDC, "the C352"), (0xE0, "the GA20"),
    ]

    init(_ data: [UInt8]) throws(TuneError) {
        guard data.count >= 0x40, data.starts(with: [0x56, 0x67, 0x6D, 0x20]) else { throw .malformed("not a VGM file") } // "Vgm "
        self.data = data
        func bits(_ at: Int) -> UInt32 {
            guard at >= 0, at + 4 <= data.count else { return 0 }
            return UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24
        }
        // (A place or a length, which is never 2 GB: an Int is only 32 bits in the browser.)
        func word(_ at: Int) -> Int { Int(bits(at) & 0x7FFF_FFFF) }
        // (Offsets are counted from where they are written.)
        let version = word(0x08)
        let given = version >= 0x150 ? word(0x34) : 0
        let header = given > 0 ? 0x34 + given : 0x40
        guard header >= 0x40, header < data.count else { throw .malformed("a VGM file whose writes begin outside it") }
        // (The header ends where its extra part begins, if that is sooner.)
        let extra = header >= 0xC0 && word(0xBC) > 0 ? 0xBC + word(0xBC) : 0
        let headerEnd = extra > 0 ? min(header, extra) : header
        func clock(_ at: Int) -> UInt32 { at + 4 <= headerEnd ? bits(at) : 0 }

        for other in Self.others where clock(other.place) & 0x3FFF_FFFF != 0 {
            throw .unsupported("a VGM file for \(other.name), which is not played: only the AdLib's and Sound Blaster's FM chips are")
        }
        let used = Chip.allCases.map { ($0, clock($0.place)) }.filter { $0.1 & 0x3FFF_FFFF != 0 }
        guard !used.isEmpty else { throw .unsupported("a VGM file for no chip that is played") }
        guard used.count == 1 else { throw .unsupported("a VGM file for two kinds of FM chip at once, which is not played") }
        var parts: [Part] = []
        for (chip, clocked) in used {
            let two = clocked & 0x4000_0000 != 0
            let hertz = Double(clocked & 0x3FFF_FFFF)
            let rate = (hertz / (chip == .opl3 ? 288 : 72)).rounded(.down)
            guard rate >= 10000, rate <= 1_000_000 else { throw .malformed("a VGM file whose chip's clock is \(clocked & 0x3FFF_FFFF) Hz") }
            parts.append(Part(chip: chip, two: two, clock: hertz, volumes: Array(repeating: two ? 0.5 : 1, count: two ? 2 : 1)))
        }
        let opl2 = used.first { $0.0 == .opl2 }?.1 ?? 0
        sides = opl2 & 0x4000_0000 != 0 && opl2 & 0x8000_0000 != 0

        start = header
        let stated = word(0x04)
        end = stated > 0 ? min(data.count, 0x04 + stated) : data.count
        ticks = word(0x18)
        let loopOffset = word(0x1C), loopTicks = word(0x20)
        if loopOffset > 0, loopTicks > 0, 0x1C + loopOffset >= start, 0x1C + loopOffset < end {
            loopStart = 0x1C + loopOffset
            self.loopTicks = loopTicks
        } else {
            loopStart = nil
            self.loopTicks = 0
        }

        // How loud: a power of two in 32nds, from 0 to 192 and below nought above that, as VGMPlay has it.
        var gain = 0
        if header > 0x7C {
            let byte = Int(data[0x7C])
            gain = byte <= 0xC0 ? byte : byte == 0xC1 ? -0x40 : byte - 0x100
        }
        volume = Float(pow(2, Double(gain) / 32))

        // How loud each chip is, which the extra header may say, in 256ths: as it is, or of what it
        // would have been. A half each for two, as VGMPlay has it.
        if extra > 0, word(extra) >= 12, word(extra + 8) > 0 {
            let list = extra + 8 + word(extra + 8)
            let count = list < data.count ? Int(data[list]) : 0
            for entry in 0 ..< count {
                let at = list + 1 + entry * 4
                guard at + 4 <= data.count else { break }
                let which = Int(data[at + 1] & 1), value = Int(data[at + 2]) | Int(data[at + 3]) << 8
                guard let part = parts.firstIndex(where: { $0.chip.number == Int(data[at]) }), which < parts[part].volumes.count else { continue }
                let was = parts[part].volumes[which]
                parts[part].volumes[which] = value & 0x8000 != 0 ? was * Float(value & 0x7FFF) / 256 : Float(value) / 256
            }
        }
        self.parts = parts

        readTags(at: word(0x14) > 0 ? 0x14 + word(0x14) : 0)
    }

    /// What the chips are called, for saying what a file is played on.
    var chipNames: String {
        parts.map { part in
            let name = switch part.chip {
            case .opl: "YM3526 (OPL)"
            case .opl2: "YM3812 (OPL2)"
            case .opl3: "YMF262 (OPL3)"
            }
            return (part.two ? "2 × " : "") + name + (part.chip == .opl2 && sides ? ", left and right" : "")
        }.joined(separator: " and ")
    }

    /// What the file says of itself, in its GD3 tags: eleven pieces of text, each in English and
    /// then in Japanese where it has both, in UTF-16.
    private mutating func readTags(at place: Int) {
        guard place > 0, place + 12 <= data.count, data[place ..< place + 4].elementsEqual([0x47, 0x64, 0x33, 0x20]) else { return } // "Gd3 "
        let length = Int(data[place + 8]) | Int(data[place + 9]) << 8 | Int(data[place + 10]) << 16 | Int(data[place + 11] & 0x7F) << 24
        var at = place + 12
        let end = min(data.count, at + length)
        var texts: [String] = []
        while texts.count < 11, at + 1 < end {
            var units: [UInt16] = []
            while at + 1 < end {
                let unit = UInt16(data[at]) | UInt16(data[at + 1]) << 8
                at += 2
                if unit == 0 { break }
                units.append(unit)
            }
            texts.append(Self.text(units))
        }
        func piece(_ english: Int, _ japanese: Int? = nil) -> String {
            let first = english < texts.count ? texts[english] : ""
            guard first.isEmpty, let japanese, japanese < texts.count else { return first }
            return texts[japanese]
        }
        title = piece(0, 1)
        game = piece(2, 3)
        system = piece(4, 5)
        author = piece(6, 7)
        date = piece(8)
        notes = piece(10)
    }

    /// Text in UTF-16, with its pairs of halves put together. A half on its own is left out.
    private static func text(_ units: [UInt16]) -> String {
        var scalars = String.UnicodeScalarView()
        var i = 0
        while i < units.count {
            let unit = UInt32(units[i])
            i += 1
            if unit >= 0xD800, unit < 0xDC00, i < units.count, units[i] >= 0xDC00, units[i] < 0xE000 {
                let low = UInt32(units[i])
                i += 1
                if let scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) { scalars.append(scalar) }
            } else if let scalar = Unicode.Scalar(unit) {
                scalars.append(scalar)
            }
        }
        return String(scalars).trimmingSpaces
    }
}

private extension String {
    var trimmingSpaces: String {
        var text = Substring(self)
        while text.first == " " || text.first == "\n" || text.first == "\r" { text = text.dropFirst() }
        while text.last == " " || text.last == "\n" || text.last == "\r" { text = text.dropLast() }
        return String(text)
    }
}

/// One of the chips a VGM file is played on, as the player drives it: it is told how many of its
/// own steps there are until the next write, and makes sound at the player's rate until it has
/// taken them.
private protocol VGMSoundChip: AnyObject {
    /// How many steps it takes a second: what its writes are timed in.
    var rate: Double { get }
    var samplesLeft: Int { get set }
    func reset()
    func write(_ register: Int, _ value: UInt8)
    /// Makes sound, left and right, until `frames` are made or `samplesLeft` is taken; turned down
    /// over the last `fade` steps, if that is not nought, of which `after` come after `samplesLeft`.
    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int, gain: Float, fade: Int, after: Int) -> Int
    var voices: Int { get }
    func takeLevels(into levels: UnsafeMutablePointer<Float>)
    func takeNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>)
    func takeSides(into sides: UnsafeMutablePointer<Float>)
    func setMuted(_ muted: [Bool])
    /// The card, for an FM chip: for comparing what it makes with a reference player.
    var card: OPLCard? { get }
}

/// An FM chip, on the card that played it.
private final class VGMOPL: VGMSoundChip {
    private let opl: OPLCard
    var card: OPLCard? { opl }
    let rate: Double
    let voices: Int
    private let isOPL: Bool

    init(_ chip: VGMFile.Chip, clock: Double) {
        // (In whole samples a second, as libvgm has it: a difference of a sample in fifty thousand.)
        rate = (clock / (chip == .opl3 ? 288 : 72)).rounded(.down)
        opl = OPLCard(rate: rate)
        voices = chip == .opl3 ? 18 : 9
        isOPL = chip == .opl
    }

    var samplesLeft: Int {
        get { opl.samplesLeft }
        set { opl.samplesLeft = newValue }
    }

    func reset() { opl.reset() }

    func write(_ register: Int, _ value: UInt8) {
        // (The OPL has no choice of waves, and what an OPL2 would take as one it does not have.)
        if isOPL, register >= 0xE0 { return }
        opl.writeEither(register, value)
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int, gain: Float, fade: Int, after: Int) -> Int {
        opl.renderStereo(into: buffer, frames: frames, gain: gain, fade: fade, after: after)
    }

    func takeLevels(into levels: UnsafeMutablePointer<Float>) { opl.takeLevels(into: levels, voices: voices) }
    func takeNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        opl.takeNotes(pitches: pitches, struck: struck, voices: voices)
    }

    func takeSides(into sides: UnsafeMutablePointer<Float>) {
        for voice in 0 ..< voices { sides[voice] = 0 }
    }

    func setMuted(_ muted: [Bool]) { opl.setMuted(muted) }
}

/// Plays a VGM file: writes what the file says to each chip when it says, and brings what they make
/// to the player's rate.
///
/// The writes that come at the same moment are made before the first of a chip's samples that is
/// at that moment or after it, as libvgm makes them; and on an FM chip each lands a little after the
/// one before, as on the chip itself. Each chip keeps its own count of its samples, so that every
/// one is timed as it would be if it were the only one, and the chips go on together: the next
/// writes are made only when every chip has made all it was given before them. A file that goes
/// round is played round and round, its turns counted, for the player to fade; one that does not
/// ends, and its last notes are given a second to die away.
final class VGMRenderer: Renderer, ReferenceComparable {
    let info: TuneInfo
    let knownLength: Double?
    let endsByLooping: Bool
    private(set) var loopCount = 0
    private(set) var hasEnded = false

    private let file: VGMFile
    /// Every chip, the first of two before the second, and how loud each is.
    private let chips: [any VGMSoundChip]
    private let gains: [Float]
    /// Which of them the commands for each kind of chip go to, the first and the second of the
    /// kind; -1 for one there is not.
    private let slots: [Int]
    private let mono: Bool
    /// Where the next command is, how far into the music the chips have been taken in 44,100ths of
    /// a second, how much more of the last wait there is to give them, and how many of each chip's
    /// steps have been given to it.
    private var at: Int
    private var tick = 0
    private var waiting = 0
    private var given: [Int]
    /// Where the music ended, once it has, and its last notes are dying away until a second after.
    private var tailFrom: Int?
    /// What each chip has made that has not been heard yet, and how many frames of it there are.
    private let made: [UnsafeMutablePointer<Float>]
    private var madeFrames: [Int]
    private static let madeCapacity = 2048
    /// The most of a wait the chips are given at once, so that what they make fits in `made`.
    private static let sliceTicks = 256

    /// Set by measure, so that a VGM file is about as loud as the others it is played among: the
    /// middle of 192 of them by how loud they are heard (LUFS, 2026-10-16), at the level the kinds
    /// are brought to. These are louder than the other music for the chip, many of them because
    /// the file asks for more (see `VGMFile.volume`), and so this is half of theirs.
    static let gain: Float = 0.70

    /// How long the last notes are given to die away, and how much of that is faded, in seconds.
    private static let tailSeconds = 1.0, fadeSeconds = 0.2

    init(_ data: [UInt8], options: LoadOptions) throws(TuneError) {
        let file = try VGMFile(data)
        self.file = file
        var chips: [any VGMSoundChip] = [], gains: [Float] = []
        var slots = [Int](repeating: -1, count: VGMFile.Chip.allCases.count * 2)
        for part in file.parts {
            for (which, volume) in part.volumes.enumerated() {
                slots[part.chip.rawValue * 2 + which] = chips.count
                chips.append(VGMOPL(part.chip, clock: part.clock))
                gains.append(Self.gain * file.volume * volume)
            }
        }
        self.chips = chips
        self.gains = gains
        self.slots = slots
        given = Array(repeating: 0, count: chips.count)
        made = chips.map { _ in .allocate(capacity: Self.madeCapacity * 2) }
        madeFrames = Array(repeating: 0, count: chips.count)
        mono = options.stereo == .mono
        at = file.start
        endsByLooping = file.loopStart != nil
        let seconds = Double(file.ticks) / 44100
        knownLength = file.ticks > 0 ? seconds + (endsByLooping ? 0 : Self.tailSeconds) : nil

        var info = TuneInfo(format: "VGM")
        info.title = file.title
        info.author = file.author
        info.comment = [file.game, file.date].filter { !$0.isEmpty }.joined(separator: ", ")
        info.detail = file.chipNames + (file.system.isEmpty ? "" : ", \(file.system)")
        self.info = info
    }

    deinit {
        for block in made { block.deallocate() }
    }

    func select(subsong _: Int) {
        for chip in chips { chip.reset() }
        at = file.start
        tick = 0
        waiting = 0
        for index in given.indices {
            given[index] = 0
            madeFrames[index] = 0
        }
        tailFrom = nil
        loopCount = 0
        hasEnded = false
    }

    /// Writes one of the file's commands to a chip: the first of a kind, or the second.
    @inline(__always) private func write(_ chip: VGMFile.Chip, second: Bool, _ register: Int, _ value: UInt8) {
        let index = slots[chip.rawValue * 2 + (second ? 1 : 0)]
        if index >= 0 { chips[index].write(register, value) }
    }

    /// How many of a chip's steps there are from the start to `tick`.
    @inline(__always) private func steps(_ chip: Int, to tick: Int) -> Int {
        Int((Double(tick) * chips[chip].rate / 44100).rounded(.up))
    }

    /// Gives the chips the next of the music, once they have made all they were given: the writes up
    /// to the next wait, and then that wait, or as much of it as they are given at once.
    private func advance() {
        if waiting == 0 {
            if tailFrom != nil {
                hasEnded = true
                return
            }
            waiting = runCommands()
        }
        let slice = min(waiting, Self.sliceTicks)
        waiting -= slice
        tick += slice
        for index in chips.indices {
            let due = steps(index, to: tick)
            if due > given[index] {
                chips[index].samplesLeft += due - given[index]
                given[index] = due
            }
        }
    }

    /// Makes the writes up to the next wait. - Returns: how long the wait is, in 44,100ths of a second.
    private func runCommands() -> Int {
        let data = file.data, end = file.end
        while true {
            guard at < end else { return finish() }
            let command = data[at]
            func byte(_ offset: Int) -> UInt8 { at + offset < end ? data[at + offset] : 0 }
            var waited = 0
            switch command {
            case 0x5A:
                write(.opl2, second: false, Int(byte(1)), byte(2))
                at += 3
            case 0x5B:
                write(.opl, second: false, Int(byte(1)), byte(2))
                at += 3
            case 0x5E:
                write(.opl3, second: false, Int(byte(1)), byte(2))
                at += 3
            case 0x5F:
                write(.opl3, second: false, 0x100 | Int(byte(1)), byte(2))
                at += 3
            case 0xAA:
                write(.opl2, second: true, Int(byte(1)), byte(2))
                at += 3
            case 0xAB:
                write(.opl, second: true, Int(byte(1)), byte(2))
                at += 3
            case 0xAE:
                write(.opl3, second: true, Int(byte(1)), byte(2))
                at += 3
            case 0xAF:
                write(.opl3, second: true, 0x100 | Int(byte(1)), byte(2))
                at += 3
            case 0x61:
                waited = Int(byte(1)) | Int(byte(2)) << 8
                at += 3
            case 0x62:
                waited = 735
                at += 1
            case 0x63:
                waited = 882
                at += 1
            case 0x70 ... 0x7F:
                waited = Int(command & 15) + 1
                at += 1
            case 0x80 ... 0x8F:
                waited = Int(command & 15)
                at += 1
            case 0x66:
                // The end: round again from where the file goes round, if it does.
                guard let loopStart = file.loopStart else { return finish() }
                loopCount += 1
                at = loopStart
                // (A file that goes round with no time in between would go round for ever.)
                if loopCount > 10000 { return finish() }
            case 0x67:
                // A block of data, for the samples of a chip that is not played here.
                let size = Int(byte(3)) | Int(byte(4)) << 8 | Int(byte(5)) << 16 | Int(byte(6) & 0x7F) << 24
                at += 7 + size
            default:
                at += Self.length(of: command)
            }
            if waited > 0 { return waited }
        }
    }

    /// How long a command that is not played here is, with what goes with it, as the format has it.
    private static func length(of command: UInt8) -> Int {
        switch command {
        case 0x30 ... 0x3F, 0x4F, 0x50: 2
        case 0x40 ... 0x4E, 0x51 ... 0x5F, 0xA0 ... 0xBF: 3
        case 0xC0 ... 0xDF: 4
        case 0xE0 ... 0xFF: 5
        case 0x68: 12
        case 0x90, 0x91, 0x95: 5
        case 0x92: 6
        case 0x93: 11
        case 0x94: 2
        default: 1
        }
    }

    /// The music is over: the last notes are left to die away. - Returns: for how long.
    private func finish() -> Int {
        tailFrom = tick
        return Int(Self.tailSeconds * 44100)
    }

    /// Has every chip make all it was given, for hearing.
    private func makeAll() {
        for (index, chip) in chips.enumerated() {
            var fade = 0, after = 0
            if let tailFrom {
                fade = Int(Self.fadeSeconds * chip.rate)
                after = steps(index, to: tailFrom + Int(Self.tailSeconds * 44100)) - given[index]
            }
            let block = made[index]
            while chip.samplesLeft > 0, madeFrames[index] < Self.madeCapacity {
                madeFrames[index] += chip.render(into: block + madeFrames[index] * 2, frames: Self.madeCapacity - madeFrames[index],
                                                 gain: gains[index], fade: fade, after: after)
            }
        }
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            // The chips make nearly the same number of frames from the same music, and what one
            // made beyond another is kept for the next.
            let ready = madeFrames.min() ?? 0
            if ready == 0 {
                if hasEnded { break }
                advance()
                if hasEnded { break }
                makeAll()
                continue
            }
            let count = min(ready, frames - done)
            let out = buffer + done * 2
            if file.sides {
                // (A Sound Blaster Pro's two, each on its own side, twice as loud there as it would
                // be in the middle.)
                for i in 0 ..< count {
                    out[i * 2] = made[0][i * 2] * 2
                    out[i * 2 + 1] = made[1][i * 2 + 1] * 2
                }
            } else {
                out.update(from: made[0], count: count * 2)
            }
            for block in made.dropFirst(file.sides ? 2 : 1) {
                for i in 0 ..< count * 2 { out[i] += block[i] }
            }
            if mono {
                for i in 0 ..< count {
                    let both = (out[i * 2] + out[i * 2 + 1]) * 0.5
                    out[i * 2] = both
                    out[i * 2 + 1] = both
                }
            }
            for index in made.indices {
                let left = madeFrames[index] - count
                if left > 0 { made[index].update(from: made[index] + count * 2, count: left * 2) }
                madeFrames[index] = left
            }
            done += count
        }
        (buffer + done * 2).update(repeating: 0, count: (frames - done) * 2)
    }

    // MARK: Voices

    /// Each chip's channels, one after the other: nine for an OPL or an OPL2 and eighteen for an
    /// OPL3. Where a tune has the drums on, they are the last three of a chip's first nine.
    var channelCount: Int { chips.reduce(0) { $0 + $1.voices } }
    /// An OPL3's second nine are there only in its own mode, which many of its tunes never use.
    var channelsAlwaysShown: Int { chips.count == 1 && chips[0].voices == 18 ? 9 : channelCount }

    private func eachChip(_ body: (any VGMSoundChip, Int) -> Void) {
        var from = 0
        for chip in chips {
            body(chip, from)
            from += chip.voices
        }
    }

    func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        eachChip { chip, from in chip.takeLevels(into: levels + from) }
    }

    func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        eachChip { chip, from in chip.takeNotes(pitches: pitches + from, struck: struck + from) }
    }

    func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        eachChip { chip, from in chip.takeSides(into: sides + from) }
    }

    func setMuted(_ muted: [Bool]) {
        eachChip { chip, from in
            chip.setMuted(from < muted.count ? Array(muted[from ..< min(muted.count, from + chip.voices)]) : [])
        }
    }

    /// The music from its start as the FM chips make it: their own samples at their own rate, left
    /// and right in turn, two chips added together (or a Sound Blaster Pro's, each on its own
    /// side), to the end or `frames` of them. For comparing with a reference player.
    func renderRaw(frames: Int) -> [Int16] {
        let cards = chips.compactMap { $0.card }
        select(subsong: 0)
        var output: [Int16] = []
        output.reserveCapacity(min(frames, 1 << 24) * 2)
        while output.count < frames * 2 {
            advance()
            if hasEnded || tailFrom != nil { break }
            while cards[0].samplesLeft > 0, output.count < frames * 2 {
                var left = 0, right = 0
                for (index, card) in cards.enumerated() {
                    let both = card.rawStereo()
                    // (A Sound Blaster Pro's two, each on its own side.)
                    if !file.sides || index == 0 { left += Int(both.left) }
                    if !file.sides || index == 1 { right += Int(both.right) }
                }
                output.append(Int16(clamping: left))
                output.append(Int16(clamping: right))
            }
        }
        select(subsong: 0)
        return output
    }
}
