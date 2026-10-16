// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// The player of VGM files: see VGMFile.swift for what they are.

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
    /// Every chip, the first of two before the second, the FM chip's before the AY's, and how loud
    /// each is.
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
    /// The same for the AY-3-8910's, by the middle of the 28 there are (2026-10-16): PC speaker music,
    /// one channel playing, which is why this is half again an AY tune's (`ayOutputGain`). Some ask
    /// to be three times as loud and some do not ask at all, so that they are either side of it.
    static let ayGain: Float = 0.37

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
                switch part.chip {
                case .ay:
                    chips.append(VGMAY(type: file.ayType, flags: file.ayFlags, clock: part.clock))
                    gains.append(Self.ayGain * file.volume * volume)
                default:
                    chips.append(VGMOPL(part.chip, clock: part.clock))
                    gains.append(Self.gain * file.volume * volume)
                }
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
            case 0xA0:
                // (The top bit of the register's number chooses the second.)
                write(.ay, second: byte(1) & 0x80 != 0, Int(byte(1) & 0x7F), byte(2))
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
    /// OPL3, and three for an AY-3-8910. Where a tune has the drums on, they are the last three of
    /// an FM chip's first nine.
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
    /// side), to the end or `frames` of them. For comparing with a reference player. A file with
    /// no FM chip gives nothing.
    func renderRaw(frames: Int) -> [Int16] {
        let cards = chips.compactMap { $0.card }
        guard !cards.isEmpty else { return [] }
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
            // (What the other chips were given is not made.)
            for chip in chips where chip.card == nil { chip.samplesLeft = 0 }
        }
        select(subsong: 0)
        return output
    }
}
