// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the PLM loader of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and
// Contributors and Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

import SidayFoundation

/// A PLM file, the module of Disorder Tracker 2, a tracker for DOS: a file that begins "PLM" and an
/// end-of-file mark.
///
/// Its song is not a list of patterns played one after another but one long stretch of rows, and
/// its patterns are laid on it like cards on a table: each where its row and its first channel say,
/// as long as it is and as wide, over any it is laid across. Up to 32 channels, samples of eight bits
/// or sixteen with a rate of their own, and commands numbered by Disorder Tracker itself, which are
/// Scream Tracker's under other numbers, with a start into a sample by so many 256ths of its length.
///
/// It is played here by Impulse Tracker's replayer, as OpenMPT plays it (`IT2Module.playsAsDisorderTracker`,
/// and `IT2DisorderTracker.swift`); Disorder Tracker's own replayer is not to be had. As OpenMPT does,
/// the long stretch is cut into patterns of 64 rows, one after another in the list, and a jump to a
/// place in it is a jump to the pattern it falls in and a break to the row: for which the patterns
/// have a channel more than the file, of breaks alone. See `IT2ForeignModule`.
enum PLMFile {
    private typealias Command = IT2ForeignModule.Command

    private static let rowsPerPattern = 64
    /// The file's commands from 0x0D, the start into a sample, and 0x16, the start by 256ths.
    private static let offset: UInt8 = 0x0D, offsetBy256ths: UInt8 = 0x16

    /// True for a file that says it is one of these: its mark, the version OpenMPT knows (0x10), and
    /// from one to 32 channels.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 96 && data[0 ..< 4].elementsEqual([0x50, 0x4C, 0x4D, 0x1A]) && data[4] >= 96 && data[5] == 0x10 && data[54] >= 1 && data[54] <= 32
    }

    /// A command of the file's as Impulse Tracker has it, and its value; nil for one that is none.
    /// (The jumps, the starts into a sample, and those whose value is changed as well, are seen to
    /// apart.)
    private static func translated(_ command: UInt8, _ value: UInt8) -> (command: UInt8, value: UInt8)? {
        switch command {
        case 0x01: return (Command.F, value)
        case 0x02: return (Command.E, value)
        case 0x03: return (Command.G, value)
        case 0x04: return (Command.D, volumeSlide(value))
        case 0x05: return (Command.R, value)
        case 0x06: return (Command.H, value)
        case 0x07: return (Command.S, 0x40 | (value & 3))
        case 0x08: return (Command.S, 0x30 | (value & 3))
        case 0x09: return (Command.T, value)
        case 0x0A: return (Command.A, value)
        // A place between the speakers, one of the Ultrasound's sixteen.
        case 0x0E: return (Command.S, 0x80 | (value & 15))
        case 0x0F: return (Command.Q, value)
        case 0x10: return (Command.S, 0xD0 | min(value, 15))
        case 0x11: return (Command.S, 0xC0 | min(value, 15))
        case 0x12: return (Command.S, 0xE0 | min(value, 15))
        case 0x13: return (Command.U, value)
        case 0x14: return (Command.K, volumeSlide(value))
        case 0x15: return (Command.L, volumeSlide(value))
        default: return nil
        }
    }

    /// A slide of volume with both halves of its value set (but for a fine one down, F in the upper)
    /// is a fine one up, by the upper. That is Disorder Tracker's reading, as OpenMPT has it.
    private static func volumeSlide(_ value: UInt8) -> UInt8 {
        value & 0xF0 != 0 && value & 0x0F != 0 && value & 0xF0 != 0xF0 ? value | 0x0F : value
    }

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> ITRenderer {
        guard isOne(data) else { throw TuneError.malformed("not a PLM file") }
        let f = ByteReader(data)
        let headerLength = Int(data[4]), channelCount = Int(data[54])
        let sampleCount = Int(data[92]), patternCount = Int(data[93]), orderCount = f.u16le(94)
        guard data.count >= headerLength + 4 * (orderCount + patternCount + sampleCount) else {
            throw TuneError.malformed("a PLM file that ends before its lists do")
        }
        let patternsAt = headerLength + 4 * orderCount, samplesAt = patternsAt + 4 * patternCount

        // MARK: Samples

        var made: [IT2Sample] = []
        var cutShort = Shortfall.CutShort()
        for index in 0 ..< IT2ForeignModule.sampleRoom {
            let at = index < sampleCount ? f.size32le(samplesAt + index * 4) : 0
            // (A sample that is nowhere, or whose header is not one, is an empty one.)
            guard at > 0, at + 71 <= data.count, data[at ..< at + 4].elementsEqual([0x50, 0x4C, 0x53, 0x1A]) else {
                made.append(IT2Sample())
                continue
            }
            let flags = f[at + 52], sixteenBit = flags & 1 != 0
            var length = f.size32le(at + 67), loopStart = f.size32le(at + 59), loopEnd = f.size32le(at + 63)
            if sixteenBit {
                length /= 2
                loopStart /= 2
                loopEnd /= 2
            }
            // The sound, without a sign, is after the header.
            let from = at + Int(f[at + 4])
            let bytes = sixteenBit ? length * 2 : length
            cutShort.add(length: bytes, there: data.count - from)
            let sound = f.sample(at: from, length: bytes)
            var sound8: [Int8] = [], sound16: [Int16] = []
            if sixteenBit {
                sound16 = (0 ..< sound.count / 2).map { Int16(bitPattern: (UInt16(sound[$0 * 2]) | UInt16(sound[$0 * 2 + 1]) << 8) ^ 0x8000) }
            } else {
                sound8 = sound.map { Int8(bitPattern: $0 ^ 0x80) }
            }
            // How loud it is, which OpenMPT takes for the sample's share of the whole, and where it
            // puts its channel, one of sixteen places (or none, for more than fifteen). A rate of
            // nothing is 8,363, as OpenMPT has it.
            let rate = f.u16le(at + 53)
            let s = IT2ForeignModule.sample(sound8: sound8, sound16: sound16, volume: 64, rate: IT2ForeignModule.rate(rate == 0 ? 8363 : rate),
                                            loops: loopEnd > loopStart, backAndForth: flags & 2 != 0, loopStart: loopStart, loopEnd: loopEnd,
                                            pan: f[at + 50] <= 15 ? IT2ForeignModule.pan(ofSixteen: f[at + 50]) : nil)
            s.GlobVol = min(f[at + 51], 64)
            made.append(s)
        }

        // MARK: The song

        // Each of the list's items puts a pattern somewhere on the song's stretch of rows.
        struct Item {
            var x: Int, y: Int, pattern: Int
        }
        let items = (0 ..< orderCount).map { Item(x: f.u16le(headerLength + $0 * 4), y: Int(f[headerLength + $0 * 4 + 2]), pattern: Int(f[headerLength + $0 * 4 + 3])) }
        let breaks = channelCount // the channel of breaks alone
        var chunks: [IT2ForeignModule.Pattern] = []
        var end = 0
        var percentOffsets: [Int: UInt8] = [:]
        var cutOff = false
        func chunk(_ number: Int) -> Int? {
            guard number < IT2ForeignModule.patternRoom, number < IT2Module.MAX_ORDERS - 1 else {
                cutOff = true
                return nil
            }
            while chunks.count <= number { chunks.append(IT2ForeignModule.Pattern(rows: rowsPerPattern)) }
            return number
        }
        for item in items {
            guard item.pattern < patternCount, item.y <= channelCount else { continue }
            let at = f.size32le(patternsAt + item.pattern * 4)
            guard at > 0, at + 32 <= data.count else { continue }
            let rows = Int(f[at + 4]), width = Int(f[at + 5])
            guard rows > 0 else { continue }
            let channels = min(width, channelCount - item.y)
            let itemEnd = item.x + rows
            end = max(end, itemEnd)
            // The last note of each channel of the item, for a start into a sample without one.
            var lastNotes = [UInt8?](repeating: nil, count: 32)
            var cell = at + 32
            for row in 0 ..< rows {
                let place = item.x + row
                guard let number = chunk(place / rowsPerPattern) else { break }
                let line = place % rowsPerPattern
                for channel in 0 ..< channels {
                    let note = f[cell], instrument = f[cell + 1], volume = f[cell + 2], command = f[cell + 3], value = f[cell + 4]
                    cell += 5
                    var out = IT2ForeignModule.Cell()
                    let before = chunks[number][line, item.y + channel]
                    let here = OpenMPTSong.place(pattern: number, row: line, channel: item.y + channel)
                    percentOffsets[here] = nil
                    if note > 0, note < 0x90 {
                        let itNote = (note >> 4) * 12 + (note & 15) + 12
                        if itNote < 120 {
                            out.set(note: itNote)
                            lastNotes[channel] = itNote
                        }
                    }
                    if instrument != 0 { out.set(instrument: instrument) }
                    // (A volume over 64 is played as 64.)
                    if volume != 0xFF { out.set(volume: min(volume, 64)) }
                    switch command {
                    case 0x00:
                        break
                    case 0x0B, 0x0C:
                        // A jump to the place in the song where an item of the list starts, or to
                        // where this one ends: to its pattern, and a break to its row beside.
                        var target = command == 0x0C ? itemEnd : Int(value)
                        if command == 0x0B, Int(value) < items.count { target = items[Int(value)].x } else if command == 0x0B { target = Int(value) * rowsPerPattern }
                        out.set(command: Command.B, UInt8(min(255, target / rowsPerPattern)))
                        if command == 0x0C || Int(value) < items.count {
                            var stop = IT2ForeignModule.Cell()
                            stop.set(command: Command.C, UInt8(target % rowsPerPattern))
                            chunks[number][line, breaks] = stop
                        }
                    case offset, offsetBy256ths:
                        // A start into a sample with no note beside it is one into the channel's
                        // last note in the item, if it has had one.
                        if !out.hasNote, let last = lastNotes[channel] { out.set(note: last) }
                        if command == offset {
                            out.set(command: Command.O, value)
                        } else {
                            out.set(command: Command.O, 0)
                            percentOffsets[here] = value
                        }
                    default:
                        if let (it, itValue) = translated(command, value) {
                            out.set(command: it, itValue)
                        } else if command >= 0x17, before.hasCommand {
                            // (A command the file has no number for leaves what was there.)
                            out.set(command: before.command, before.value)
                        }
                    }
                    chunks[number][line, item.y + channel] = out
                }
                cell += 5 * max(0, width - channels)
            }
        }
        guard !chunks.isEmpty else { throw TuneError.malformed("a PLM file with nothing in its song") }

        // The song ends with the last row of the last item; the patterns no item reached are silence.
        var patterns = [[UInt8]?](repeating: IT2ForeignModule.Pattern().packed(), count: IT2ForeignModule.patternRoom)
        var rows = [UInt16](repeating: 64, count: IT2ForeignModule.patternRoom)
        for (number, pattern) in chunks.enumerated() {
            let last = end % rowsPerPattern
            if number == end / rowsPerPattern, last > 0 {
                var short = IT2ForeignModule.Pattern(rows: last)
                for row in 0 ..< last {
                    for channel in 0 ... channelCount { short[row, channel] = pattern[row, channel] }
                }
                patterns[number] = short.packed()
                rows[number] = UInt16(last)
            } else {
                patterns[number] = pattern.packed()
            }
        }

        var pans = [UInt8](repeating: 32 | 128, count: MAX_HOST_CHANNELS)
        for channel in 0 ..< channelCount { pans[channel] = IT2ForeignModule.pan(ofSixteen: f[60 + channel]) }
        pans[breaks] = 32

        var shortfalls: [String] = []
        if cutOff { shortfalls.append("Its song is longer than Impulse Tracker's replayer has room for, and the end of it is left out.") }
        if let sentence = cutShort.sentence { shortfalls.append(sentence) }

        let module = IT2Module(title: f.dos(at: 6, length: 48), madeWith: "Disorder Tracker 2", orders: (0 ..< chunks.count).map { UInt8($0) },
                               flags: ITF_STEREO | ITF_OLD_EFFECTS, globalVolume: 128, mixVolume: mixVolume, speed: data[59] == 0 ? 6 : data[59],
                               tempo: data[58], channelPans: pans, samples: made, patterns: patterns, rows: rows)
        module.playsAsDisorderTracker = true
        module.disorderTrackerOffsets = percentOffsets
        return ITRenderer(module: module, format: "PLM", shortfalls: shortfalls, options: options)
    }

    /// How loud the whole is made, of Impulse Tracker's 128: set by measure, so that these files are
    /// about as loud as other modules are.
    private static let mixVolume: UInt8 = 48
}
