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
    /// Where the next command is; how far into the music the commands have come, in 44,100ths of a
    /// second, to the end of the last wait; how far the chips have been taken, in the same with a
    /// fraction, since a stream writes between them; and how many of each chip's steps have been
    /// given to it.
    private var at: Int
    private var waitEnd = 0
    private var now = 0.0
    private var given: [Int]
    /// Where the music ended, once it has, and its last notes are dying away until a second after.
    private var tailFrom: Int?
    /// The file's streams of samples, and which of them each of its numbers is; and where in the
    /// first bank the YM2612's own commands for its DAC read from.
    private var streams: [VGMStream] = []
    private var streamIndex = [Int](repeating: -1, count: 256)
    private var bankAt = 0
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
    /// The same for an SN76489's, by the middle of the 18 there are (2026-10-16): 5.1 dB under libvgm's
    /// level, which is this chip's at 0.5. (King's Quest II's ask to be 11.5 dB quieter than that, and
    /// the Tandy 1000's up to 7 dB louder, so that they are either side of it.)
    static let snGain: Float = 0.28
    /// The same for a DAC: as loud beside the FM chip as libvgm has it, by measure of each alone in
    /// both (2026-10-16, four files of three games; their FM at 2.8 dB over libvgm's, as for every
    /// FM chip, and so their DAC too).
    static let dacGain: Float = 0.173

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
                case .dac:
                    chips.append(VGMDAC())
                    gains.append(Self.dacGain * file.volume * volume)
                case .sn:
                    chips.append(VGMSN(file.snVariant, clock: part.clock))
                    gains.append(Self.snGain * file.volume * volume)
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
        if file.unread { info.shortfalls.append("Some of its samples are packed in a way that is not read, and are not heard.") }
        self.info = info
    }

    deinit {
        for block in made { block.deallocate() }
    }

    func select(subsong _: Int) {
        for chip in chips { chip.reset() }
        at = file.start
        waitEnd = 0
        now = 0
        streams = []
        for index in streamIndex.indices { streamIndex[index] = -1 }
        bankAt = 0
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

    /// How many of a chip's steps there are from the start to `moment`.
    @inline(__always) private func steps(_ chip: Int, to moment: Double) -> Int {
        Int((moment * chips[chip].rate / 44100).rounded(.up))
    }

    /// Gives the chips the next of the music, once they have made all they were given: the writes
    /// up to the next wait, and then that wait, or as much of it as they are given at once, or up to
    /// the next write a stream makes.
    private func advance() {
        // (The file's commands come before a stream's write at the same moment, as libvgm has them.)
        let commandsDue = now >= Double(waitEnd)
        runStreams(includingNow: !commandsDue)
        if commandsDue {
            if tailFrom != nil {
                hasEnded = true
                return
            }
            waitEnd += runCommands()
            runStreams(includingNow: true)
        }
        var until = min(Double(waitEnd), now + Double(Self.sliceTicks))
        for stream in streams where stream.running && stream.next < until { until = stream.next }
        now = until
        for index in chips.indices {
            let due = steps(index, to: now)
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
            case 0x50, 0x30:
                write(.sn, second: command == 0x30, 0, byte(1))
                at += 2
            case 0x4F, 0x3F:
                write(.sn, second: command == 0x3F, 1, byte(1))
                at += 2
            case 0x52:
                write(.dac, second: false, Int(byte(1)), byte(2))
                at += 3
            case 0x53:
                write(.dac, second: false, 0x100 | Int(byte(1)), byte(2))
                at += 3
            case 0x80 ... 0x8F:
                // The next of the first bank's bytes to the YM2612's DAC, and a wait.
                let bank = file.banks[0]
                if bankAt < bank.count { write(.dac, second: false, 0x2A, bank[bankAt]) }
                bankAt += 1
                waited = Int(command & 15)
                at += 1
            case 0xE0:
                bankAt = Int(byte(1)) | Int(byte(2)) << 8 | Int(byte(3)) << 16 | Int(byte(4) & 0x7F) << 24
                at += 5
            case 0x90 ... 0x95:
                streamCommand(command)
                at += VGMFile.length(of: command)
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
            case 0x66:
                // The end: round again from where the file goes round, if it does.
                guard let loopStart = file.loopStart else { return finish() }
                loopCount += 1
                at = loopStart
                // (A file that goes round with no time in between would go round for ever.)
                if loopCount > 10000 { return finish() }
            case 0x67:
                // A block of data, read when the file was.
                let size = Int(byte(3)) | Int(byte(4)) << 8 | Int(byte(5)) << 16 | Int(byte(6) & 0x7F) << 24
                at += 7 + size
            default:
                at += VGMFile.length(of: command)
            }
            if waited > 0 { return waited }
        }
    }

    /// The music is over: the last notes are left to die away. - Returns: for how long.
    private func finish() -> Int {
        tailFrom = waitEnd
        return Int(Self.tailSeconds * 44100)
    }

    // MARK: Streams

    /// One of the file's commands for its streams.
    private func streamCommand(_ command: UInt8) {
        let data = file.data, end = file.end
        func byte(_ offset: Int) -> Int { at + offset < end ? Int(data[at + offset]) : 0 }
        // (In 32 bits, as an Int is in the browser.)
        func bits(_ offset: Int) -> UInt32 {
            UInt32(byte(offset)) | UInt32(byte(offset + 1)) << 8 | UInt32(byte(offset + 2)) << 16 | UInt32(byte(offset + 3)) << 24
        }
        func long(_ offset: Int) -> Int { Int(bits(offset) & 0x7FFF_FFFF) }
        let number = byte(1)
        if command == 0x90 {
            // Which chip it writes to, and to what.
            if streamIndex[number] < 0, number != 0xFF {
                streamIndex[number] = streams.count
                streams.append(VGMStream())
            }
            guard streamIndex[number] >= 0 else { return }
            let type = byte(2) & 0x7F, second = byte(2) & 0x80 != 0
            let chip = VGMFile.Chip.allCases.first { $0.number == type }
            streams[streamIndex[number]].chip = chip.map { slots[$0.rawValue * 2 + (second ? 1 : 0)] } ?? -1
            streams[streamIndex[number]].kind = chip
            streams[streamIndex[number]].register = byte(3) << 8 | byte(4)
            // (A period for an SN76489 is two bytes of the bank; everything else, one.)
            streams[streamIndex[number]].size = chip == .sn && byte(4) & 0x10 == 0 ? 2 : 1
            return
        }
        if command == 0x94, number == 0xFF {
            for index in streams.indices { streams[index].running = false }
            return
        }
        guard streamIndex[number] >= 0 else { return }
        let index = streamIndex[number]
        switch command {
        case 0x91:
            streams[index].bank = byte(2) & 0x3F
            streams[index].stepSize = max(1, byte(3))
            streams[index].stepBase = byte(4)
        case 0x92:
            // (From the next write, which is when it would have been.)
            if streams[index].running {
                streams[index].began = streams[index].next
                streams[index].sent = 0
            }
            streams[index].frequency = long(2)
        case 0x93:
            start(index, at: bits(2) == 0xFFFF_FFFF ? nil : long(2), mode: byte(6), length: long(7))
        case 0x94:
            streams[index].running = false
        case 0x95:
            let bank = streams[index].bank, block = byte(2) | byte(3) << 8
            guard bank >= 0, block < file.blocks[bank].count else { return }
            let flags = byte(4)
            start(index, at: file.blocks[bank][block].start, mode: 0x0F | flags & 0x10 | (flags & 0x01) << 7, length: file.blocks[bank][block].count)
        default:
            break
        }
    }

    /// Sets a stream going, from `from` in its bank (or where it was), for `length` in the way
    /// `mode` says: so many writes (1), so many thousandths of a second (2), to the end of the bank
    /// (3), or so many bytes (0x0F); backwards with 0x10, and round again with 0x80.
    private func start(_ index: Int, at from: Int?, mode: Int, length: Int) {
        var stream = streams[index]
        guard stream.bank >= 0 else { return }
        let bank = file.banks[stream.bank].count
        let base = stream.size * stream.stepBase
        if let from { stream.start = min(bank, from + base) }
        switch mode & 0x0F {
        case 0: break
        case 1: stream.count = length
        case 2: stream.count = stream.frequency > 0 ? length * stream.frequency / 1000 : 0
        case 3: stream.count = max(0, bank - (stream.start - base)) / stream.step
        case 0x0F: stream.count = length / stream.step
        default: stream.count = 0
        }
        stream.reverse = mode & 0x10 != 0
        stream.loops = mode & 0x80 != 0
        stream.left = stream.count
        stream.position = stream.reverse ? (stream.count - 1) * stream.step : 0
        stream.running = stream.count > 0
        stream.began = now
        stream.sent = 0
        streams[index] = stream
        if stream.running, stream.chip >= 0 { chips[stream.chip].soundStarted() }
    }

    /// Makes the writes the streams have due by now, or due before it.
    private func runStreams(includingNow: Bool) {
        for index in streams.indices where streams[index].running {
            while streams[index].running, streams[index].frequency > 0,
                  streams[index].next < now || includingNow && streams[index].next == now {
                var stream = streams[index]
                let bank = file.banks[stream.bank]
                let place = stream.start + stream.position
                if stream.chip >= 0, place >= 0, place < bank.count, let kind = stream.kind {
                    let value = bank[place]
                    switch kind {
                    case .dac, .opl3:
                        chips[stream.chip].write((stream.register >> 8 != 0 ? 0x100 : 0) | stream.register & 0xFF, value)
                    case .opl, .opl2, .ay:
                        chips[stream.chip].write(stream.register & 0xFF, value)
                    case .sn:
                        // A volume, of four bits; or a period, of ten in two bytes, in two writes.
                        let latch = UInt8(stream.register & 0xF0)
                        chips[stream.chip].write(0, latch | value & 0x0F)
                        if latch & 0x10 == 0 {
                            let high = place + 1 < bank.count ? bank[place + 1] : 0
                            chips[stream.chip].write(0, (high & 0x03) << 4 | value >> 4)
                        }
                    }
                }
                stream.position += stream.reverse ? -stream.step : stream.step
                stream.sent += 1
                stream.left -= 1
                if stream.left <= 0 {
                    if stream.loops {
                        stream.left = stream.count
                        stream.position = stream.reverse ? (stream.count - 1) * stream.step : 0
                    } else {
                        stream.running = false
                    }
                }
                streams[index] = stream
            }
        }
    }

    /// Has every chip make all it was given, for hearing.
    private func makeAll() {
        for (index, chip) in chips.enumerated() {
            var fade = 0, after = 0
            if let tailFrom {
                fade = Int(Self.fadeSeconds * chip.rate)
                after = steps(index, to: Double(tailFrom) + Self.tailSeconds * 44100) - given[index]
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

    func takeChannelsSampled(into sampled: UnsafeMutablePointer<Bool>) {
        eachChip { chip, from in
            for voice in 0 ..< chip.voices { sampled[from + voice] = chip.sampled }
        }
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

/// One of a file's streams: a sample's bytes, from one of the file's banks of them, written to a
/// chip one at a time, so many a second, as libvgm's "DAC stream control" writes them.
private struct VGMStream {
    /// Which of the player's chips it writes to, of what kind, and to what (the register, and for
    /// a chip with two sets of them, which set, above it).
    var chip = -1
    var kind: VGMFile.Chip?
    var register = 0
    var bank = -1
    /// How far apart its writes are in the bank, in writes, and which of those it begins with; and
    /// how many bytes each write takes.
    var stepSize = 1, stepBase = 0
    var size = 1
    /// How far apart its writes are in the bank, in bytes.
    var step: Int { stepSize * size }
    var frequency = 0
    /// Where its sound begins in the bank, how many writes it makes of it, how many are still to
    /// make, and how far into it it has come.
    var start = 0, count = 0, left = 0, position = 0
    var reverse = false, loops = false, running = false
    /// When it was set going, or its rate last changed, and how many writes it has made since.
    var began = 0.0
    var sent = 0

    /// When its next write is due, in 44,100ths of a second.
    var next: Double { began + Double(sent) * 44100 / Double(max(1, frequency)) }
}
