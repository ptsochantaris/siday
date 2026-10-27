// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the DTM loaders of libxmp, Copyright (C) 1996-2026 Claudio Matsuoka and Hipolito
// Carraro Jr, used under the MIT licence, and of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project
// Developers and Contributors and (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause
// licence (see THIRD-PARTY.md). What each version of the tracker did with a command is from libxmp's
// loader, whose authors tried the versions.

import SidayFoundation

/// A module made with Digital Tracker on the Atari Falcon: a file that begins "D.T.".
///
/// The file is a row of chunks, each with four letters for a name and a length. Its patterns are
/// kept in one of three ways, by the version of the tracker that saved it: as a MOD file keeps
/// them, with periods; with numbered notes and a volume beside each; or, from the tracker's
/// successor Digital Home Studio, as a list of events for each channel, which is not read here.
/// Its samples have eight bits or sixteen, a rate of their own each, and may be in stereo.
///
/// The tracker changed what its commands did from one version to the next, and a file does not
/// always say which version wrote it. What can be known is taken from the file, as libxmp's loader
/// works it out, and the commands are read as that version had them.
///
/// This player has no replayer of Digital Tracker's own. The file is read into what FastTracker 2
/// plays (see `ForeignModule`), and where the two trackers differ it is FastTracker that is heard.
enum DTMFile {
    /// Which tracker wrote the file, as near as the file lets it be known, in the order they came out.
    private enum Version: Int, Comparable {
        /// Digital Tracker 2.015 and 2.02; 2.03; 2.04 and the commercial versions up to 1.9, which
        /// came after it and cannot be told from it; and 1.9 once it said which it was.
        case v2015, v203, v204, v19

        static func < (a: Version, b: Version) -> Bool { a.rawValue < b.rawValue }
    }

    private enum Packing {
        /// A MOD file's four bytes, with a period.
        case periods
        /// Four bytes, with a numbered note and a volume.
        case notes
    }

    private struct Chunk {
        var name: UInt32
        var start: Int
        var length: Int
    }

    private static func name(_ text: StaticString) -> UInt32 {
        text.withUTF8Buffer { UInt32($0[0]) << 24 | UInt32($0[1]) << 16 | UInt32($0[2]) << 8 | UInt32($0[3]) }
    }

    static func read(_ data: [UInt8]) throws -> ForeignModule {
        let file = ByteReader(data)
        let headerLength = file.size32be(4)
        guard data.count >= 22, UInt32(file.u16be(0)) << 16 | UInt32(file.u16be(2)) == name("D.T."), headerLength >= 14, headerLength <= 256 else {
            throw TuneError.malformed("not a DTM file")
        }
        guard file.u16be(8) == 0 else { throw TuneError.unsupported("a DTM file that is not a module") }
        let panoramic = data[10] == 0xFF
        let depthOfAll = Int(data[11]), rateOfAll = file.size32be(18)

        var chunks: [Chunk] = []
        var at = 8 + headerLength
        // (True if the file ends in the middle of a chunk, and so has lost what came after it; and
        // which chunk that is.)
        var endsEarly = false, endsIn: UInt32 = 0
        while at <= data.count - 8 {
            if file.size32be(at + 4) > data.count - at - 8 {
                endsEarly = true
                endsIn = UInt32(file.u16be(at)) << 16 | UInt32(file.u16be(at + 2))
            }
            let length = min(file.size32be(at + 4), data.count - at - 8)
            chunks.append(Chunk(name: UInt32(file.u16be(at)) << 16 | UInt32(file.u16be(at + 2)), start: at + 8, length: length))
            at += 8 + length
        }
        func first(_ text: StaticString) -> Chunk? {
            let wanted = name(text)
            return chunks.first { $0.name == wanted }
        }

        guard let layout = first("PATT"), layout.length >= 8 else { throw TuneError.malformed("a DTM file with no patterns") }
        let channels = file.u16be(layout.start)
        guard channels >= 1, channels <= 32 else { throw TuneError.unsupported("a DTM file of \(channels) channels") }
        let packing: Packing
        switch UInt32(file.u16be(layout.start + 4)) << 16 | UInt32(file.u16be(layout.start + 6)) {
        case 0: packing = .periods
        case name("2.04"): packing = .notes
        case name("2.06"): throw TuneError.unsupported("a DTM file from Digital Home Studio, whose patterns are kept in a way this player does not read")
        default: throw TuneError.unsupported("a DTM file with its patterns kept in a way this player does not know")
        }
        // A later tracker says which it is. An earlier one is known by how it kept its patterns,
        // and the earliest by leaving out how many bits its samples have.
        let said = first("VERS").flatMap { $0.length >= 4 ? file.size32be($0.start) : nil } ?? 0
        let version: Version = said != 0 ? .v19 : packing == .notes ? .v204 : depthOfAll != 0 ? .v203 : .v2015

        var module = ForeignModule(format: "DTM")
        // Digital Tracker's vibrato is shallow: OpenMPT, which has a rule for these files alone,
        // plays it a quarter as deep as the same command in a MOD file, and libxmp as deep as in
        // one. OpenMPT's is followed. (It was ProTracker's depth here at first; then a tune whose
        // composer had written the shallowest vibrato there is, on a held note, was heard both
        // ways, and at ProTracker's depth the note came near to going out of tune.) OpenMPT's
        // other rule for these files, a slide on every tick of a row and not on all but the first,
        // was heard beside ProTracker's too, and is not followed: a tune's sweeps of a fifth, which
        // stay in key ProTracker's way, went out of key.
        module.vibratoIsAQuarterAsDeep = true
        module.tracker = said >= 20 ? "Digital Home Studio \(said / 10).\(said % 10)" : said != 0 ? "Digital Tracker \(said / 10).\(said % 10)"
            : version == .v204 ? "Digital Tracker 2.04" : version == .v203 ? "Digital Tracker 2.03" : "Digital Tracker 2.015"
        module.title = file.ascii(at: 22, length: headerLength - 14)
        module.channels = channels
        // (The loudness is left as FastTracker's mixer has it: by measure the middle one of 92 files
        // is within a tenth of a decibel of the middle one of 200 XM files.)
        // Files have been saved with a speed or a tempo of nothing, and play at the usual ones.
        if file.u16be(14) != 0 { module.speed = file.u16be(14) }
        if file.u16be(16) != 0 { module.tempo = file.u16be(16) }

        guard let sequence = first("S.Q."), sequence.length > 8 else { throw TuneError.malformed("a DTM file with no order to play its patterns in") }
        let orders = min(file.u16be(sequence.start), sequence.length - 8, 256)
        module.orders = (0 ..< orders).map { file[sequence.start + 8 + $0] }
        module.restart = file.u16be(sequence.start + 2)

        // The tracker has two ways with stereo. In the old one the channels are to one side or the
        // other as an Amiga's are, left, right, right and left, and nothing moves them. (Hard over,
        // on the Falcon. The file itself says nothing of how far, and they are put a quarter of the
        // way across and three quarters, as OpenMPT puts them.) In the one it calls panoramic they
        // start in the middle and a command places them.
        module.panning = (0 ..< channels).map { panoramic && version >= .v204 ? 128 : $0 & 3 == 0 || $0 & 3 == 3 ? ForeignModule.leftward : ForeignModule.rightward }
        var found = Found()
        if said >= 19, let settings = first("SV19"), settings.length >= 70 {
            // A tempo has a fraction, which FastTracker's has not: the nearest whole one.
            if file.u16be(settings.start + 2) >= 0x8000 { module.tempo += 1 }
            found.tempoHasFraction = file.u16be(settings.start + 2) != 0
            // Where each channel starts: from 0 on the left, by way of 90, to 180 on the right.
            if panoramic {
                for channel in 0 ..< channels {
                    let place = file.u16be(settings.start + 6 + channel * 2)
                    if place <= 180 { module.panning[channel] = UInt8(min(255, place * 256 / 180)) }
                }
            }
        }

        // The patterns: each in a chunk of its own that says which it is and how many rows it has.
        let patterns = Int(module.orders.max() ?? 0) + 1
        module.patterns = [ForeignModule.Pattern](repeating: ForeignModule.Pattern(), count: patterns)
        for chunk in chunks where chunk.name == name("DAPT") && chunk.length >= 8 {
            let number = file.u16be(chunk.start + 4)
            let rows = min(file.u16be(chunk.start + 6), 256, (chunk.length - 8) / (channels * 4))
            guard number < 256, rows >= 1 else { continue }
            while module.patterns.count <= number { module.patterns.append(ForeignModule.Pattern()) }
            var notes = [FT2Note](repeating: FT2Note(), count: rows * channels)
            for i in 0 ..< notes.count {
                let from = chunk.start + 8 + i * 4
                notes[i] = note(data[from], data[from + 1], data[from + 2], data[from + 3], packing, version, panoramic, channels, &found)
            }
            module.patterns[number] = ForeignModule.Pattern(rows: rows, notes: notes)
        }

        // The samples: what is said of each, all together, and then each one's sound in a chunk of
        // its own, which says whose it is.
        var sounds = [Chunk?](repeating: nil, count: 128)
        for chunk in chunks where chunk.name == name("DAIT") && chunk.length >= 2 {
            let number = file.u16be(chunk.start)
            if number < sounds.count, sounds[number] == nil { sounds[number] = Chunk(name: chunk.name, start: chunk.start + 2, length: chunk.length - 2) }
        }
        if let said = first("INST"), said.length >= 2 {
            // (A later file numbers its samples itself, two bytes before each.)
            let numbered = file.u16be(said.start) & 0x8000 != 0
            let recordLength = numbered ? 52 : 50
            let count = min(file.u16be(said.start) & 0x7FFF, (said.length - 2) / recordLength)
            for index in 0 ..< count {
                let record = said.start + 2 + index * recordLength + (numbered ? 2 : 0)
                let number = numbered ? file.u16be(record - 2) : index
                guard number < 128 else { continue }
                while module.samples.count <= number { module.samples.append(nil) }
                module.samples[number] = sample(file, record, sounds[number], version, depthOfAll, rateOfAll, &found)
                // (A sample whose sound is in a chunk that the file ends before is missing.)
                if sounds[number] == nil, endsEarly { found.cutShort.add(length: file.size32be(record + 4), there: 0) }
            }
        }
        // (And what else it has lost, patterns among them, is not there: they are empty. The end of
        // a sample's sound is counted with the samples.)
        found.partsLost = endsEarly && (endsIn == name("DAPT") || module.orders.contains { module.patterns[Int($0)].notes.isEmpty })
        module.shortfalls = found.sentences
        return module
    }

    /// What is met in a file that FastTracker cannot do, for `ForeignModule.shortfalls`.
    private struct Found {
        var tempoHasFraction = false
        /// Samples said to be louder than FastTracker's loudest.
        var loudSamples = 0
        /// True if a channel has been turned down on both its sides at once.
        var turnsChannelsDown = false
        /// Which of `commandsLeftOut` are in the patterns.
        var leftOut = Shortfall.Kinds()
        var cutShort = Shortfall.CutShort()
        /// True if the file ends before patterns that its song plays, or in one.
        var partsLost = false

        /// The commands of ProTracker's that Digital Tracker does not have and a tune would be
        /// heard to lack, in the order `note` counts them in.
        static let commandsLeftOut = ["the shape of a tremolo", "striking a note again"]

        var sentences: [String] {
            var sentences: [String] = []
            if loudSamples > 0 {
                sentences.append(Shortfall.some(loudSamples, one: "samples is louder than FastTracker's loudest, and is played at that.",
                                                many: "samples are louder than FastTracker's loudest, and are played at that."))
            }
            if turnsChannelsDown { sentences.append("Where it sets how loud a channel is on each side, the channel's place between them is kept and its loudness is not.") }
            if tempoHasFraction { sentences.append("Its tempo has a fraction, and is played at the nearest whole one.") }
            if let sentence = Shortfall.commandsLeftOut(leftOut.named(Self.commandsLeftOut), why: "which Digital Tracker did not have") { sentences.append(sentence) }
            if let sentence = cutShort.sentence { sentences.append(sentence) }
            if partsLost { sentences.append(Shortfall.patternsLost(samplesToo: cutShort.sentence != nil)) }
            return sentences
        }
    }

    private static func sample(_ file: ByteReader, _ record: Int, _ sound: Chunk?, _ version: Version, _ depthOfAll: Int, _ rateOfAll: Int,
                               _ found: inout Found) -> ForeignModule.Sample? {
        guard let sound else { return nil }
        // The length is in bytes, as are the two ends of the part that repeats.
        let length = file.size32be(record + 4)
        var sample = ForeignModule.Sample()
        // (A sound that the end of the file cuts short is one thing, and is given its length in
        // silence; one that is simply shorter than the sample says it is, is another.)
        let cutShort = sound.start + sound.length >= file.count
        var bytes = file.sample(at: sound.start, length: cutShort ? length : min(length, sound.length))
        if cutShort { found.cutShort.add(length: length, there: file.count - sound.start) }
        if !bytes.isEmpty, file[record + 9] > 64 { found.loudSamples += 1 }
        var repeatStart = file.size32be(record + 10), repeatLength = file.size32be(record + 14)
        if repeatStart >= bytes.count {
            repeatStart = 0
            repeatLength = 0
        }
        repeatLength = min(repeatLength, bytes.count - repeatStart)

        // Before version 2.04 a file's samples all had as many bits as the file said, and all
        // played at the rate the file said, whatever was written beside each.
        let bits = version <= .v203 ? (depthOfAll == 16 ? 16 : 8) : Int(file[record + 41])
        sample.sixteenBit = bits > 8
        let width = sample.sixteenBit ? 2 : 1
        if file[record + 40] & 1 != 0 {
            // In stereo, left and right in turn: the two sides are taken apart, and played apart.
            let frames = bytes.count / (width * 2)
            var left = [UInt8](repeating: 0, count: frames * width), right = left
            for frame in 0 ..< frames {
                for byte in 0 ..< width {
                    left[frame * width + byte] = bytes[frame * width * 2 + byte]
                    right[frame * width + byte] = bytes[frame * width * 2 + width + byte]
                }
            }
            bytes = left
            sample.right = right
            repeatStart /= 2
            repeatLength /= 2
        }
        if sample.sixteenBit {
            // The Falcon has the high byte first.
            for i in stride(from: 0, to: bytes.count - 1, by: 2) { bytes.swapAt(i, i + 1) }
            if var right = sample.right {
                for i in stride(from: 0, to: right.count - 1, by: 2) { right.swapAt(i, i + 1) }
                sample.right = right
            }
        }
        sample.data = bytes
        // A repeat of a single sample is how the tracker writes none.
        if repeatLength / width > 1 {
            sample.repeatStart = repeatStart
            sample.repeatLength = repeatLength
        }
        sample.fineTune = Int8(bitPattern: file[record + 8] << 4)
        sample.volume = min(64, file[record + 9])
        if version <= .v203 {
            sample.rate = rateOfAll == 49170 || rateOfAll == 24585 || rateOfAll == 12292 ? rateOfAll : 8400
        } else {
            let rate = file.size32be(record + 46)
            sample.rate = rate > 0 ? rate : 8363
        }
        // From 1.9 on, the note a sample was recorded at moves the notes it plays.
        let recordedAt = file.u16be(record + 42)
        if version >= .v19, recordedAt < 95 { sample.relativeNote = Int8(48 - max(24, recordedAt)) }
        return bytes.isEmpty ? nil : sample
    }

    private static func note(_ first: UInt8, _ second: UInt8, _ third: UInt8, _ value: UInt8, _ packing: Packing, _ version: Version, _ panoramic: Bool,
                             _ channels: Int, _ found: inout Found) -> FT2Note
    {
        var note = FT2Note()
        switch packing {
        case .periods:
            let period = UInt16(first & 0x0F) << 8 | UInt16(second)
            for k in 0 ..< 96 where period >= ft2AmigaPeriod[k] {
                note.ton = UInt8(k + 1)
                break
            }
            note.instr = (first & 0xF0) | (third >> 4)
        case .notes:
            // An octave and a note of it, counted from 1: the note in the middle of the keyboard is 41.
            let number = Int(first >> 4) * 12 + Int(first & 15)
            if first > 0, first <= 0x7C, number >= 1, number <= 96 { note.ton = UInt8(number) }
            // A volume from 1, for none, to 63.
            if second >> 2 != 0 { note.vol = 0x10 + (second >> 2) - 1 }
            note.instr = (second & 3) << 4 | third >> 4
        }

        let command = third & 15
        switch command {
        case 0x0:
            // An arpeggio does nothing before 2.04.
            if version >= .v204 { note.eff = value }
        case 0x8:
            // The channel's place, which only the panoramic way has, from 2.04 on.
            guard version >= .v204, panoramic else { break }
            note.effTyp = 8
            if version >= .v19 {
                // From nothing on the right to FF on the left.
                note.eff = value ^ 0xFF
            } else {
                // How loud the channel is on the left, from 0 to F, and on the right. FastTracker
                // has a place and no loudness for a channel, so the place is kept and the loudness
                // is not: a channel turned down on both sides is as loud as one that is not.
                let left = Int(value >> 4), right = Int(value & 15)
                if max(left, right) < 15 { found.turnsChannelsDown = true }
                note.eff = UInt8(max(0, min(255, 0x80 * (right - left) / (left + right + 2) + 0x80)))
            }
        case 0xB:
            // From 2.04 until 1.9 said which it was, the tracker jumped to the place before the one asked for.
            note.effTyp = command
            note.eff = version == .v204 && value > 0 ? value - 1 : value
        case 0xD:
            // And before 2.04 a break went to the top of the next pattern whatever row it asked for.
            note.effTyp = command
            note.eff = version <= .v203 ? 0 : value
        case 0xE:
            switch value >> 4 {
            case 0x1, 0x2, 0x3, 0x6, 0xA, 0xB, 0xC, 0xD, 0xE:
                note.effTyp = command
                note.eff = value
            case 0x4:
                // The shape of a vibrato: a sine, a ramp, and two that are both square.
                note.effTyp = command
                note.eff = 0x40 | min(2, value & 3)
            case 0x5:
                // A fine tuning for the note, where there is one.
                if note.ton != 0 {
                    note.effTyp = command
                    note.eff = value
                }
            // The rest the tracker does not have.
            default:
                if value & 15 != 0, let kind = [0x7, 0x9].firstIndex(of: value >> 4) { found.leftOut.note(kind) }
            }
        case 0xF:
            if version <= .v203, value == 0 || value == 0x20 {
                // Before 2.04 these two are a speed of one.
                note.effTyp = command
                note.eff = 1
            } else if value != 0 {
                // (A speed of nothing stops FastTracker, and does nothing here.)
                note.effTyp = command
                note.eff = value
            }
        default:
            (note.effTyp, note.eff) = ForeignModule.tidied(command, value)
        }
        return note
    }
}
