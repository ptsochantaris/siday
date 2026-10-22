// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the IMF loader of OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and
// Contributors and Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see
// THIRD-PARTY.md), which Storlek wrote first for Schism Tracker and OpenMPT took up
// (`soundlib/Load_imf.cpp`), with how OpenMPT turns an XM-like envelope into an IT one
// (`soundlib/ModInstrument.cpp`).

import SidayFoundation

/// An IMF file, the module of Imago Orpheus.
///
/// Imago Orpheus was a tracker for DOS by Lutz Roeder, of the nineties: up to 32 channels, each anywhere of
/// 256 places between the speakers; instruments that are a sample for each range of notes, each
/// with envelopes for its volume, its place and its filter, and a fade; samples of eight bits or
/// sixteen that loop forwards or back and forth; and two commands to a note, from a list of its own
/// that has most of Scream Tracker's and FastTracker's and some more, among them a resonant filter
/// such as the sound cards of the day that had one had.
///
/// It is played here by Impulse Tracker's replayer, and not by Imago Orpheus's own, which has never
/// been published. OpenMPT does the same, reading these files into the shape of an IT file and
/// playing them with its own player's ways of playing IT files, as far as it tells them apart from
/// IT files at all; and that is followed here (see `IT2Module.imagoOrpheus`). See `IT2ForeignModule`.
///
/// What does not go over as it stands:
///  - Two commands to a note. Impulse Tracker has room for one, and a volume column: they are put
///    there as OpenMPT puts them, which leaves one out where neither can go in the volume column, the
///    one that matters less by OpenMPT's reckoning. The file says how many were.
///  - Its places between the speakers, of 256, which are Impulse Tracker's of 64.
/// Not played, as OpenMPT does not play them: the chorus and the reverb (Yxx and Zxx and each
/// channel's own), a slide of the filter (Nxy, whose resonance is played), the sample offset that
/// is finer (Pxx), XFx, which changes how a sample loops, and X1x, which sets the filter.
enum IMFFile {
    private typealias Effect = OpenMPTCell.Effect

    /// True for a file that says it is one of these.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 0x40 && data[0x3C] == 0x49 && data[0x3D] == 0x4D && data[0x3E] == 0x31 && data[0x3F] == 0x30 // "IM10"
    }

    // MARK: Commands

    /// Which of the kinds of command that are left out a file has: see `leftOutNames`.
    private enum LeftOut: Int {
        case chorus = 0, reverb, filterSlide, fineOffset, loop, filter, noteSlide, keyOff, finetune, glissando
    }

    private static let leftOutNames = ["chorus (Yxx)", "reverb (Zxx)", "slides of the filter (Nxy)", "the finer sample offset (Pxx)",
                                       "changing how a sample loops (XFx)", "setting the filter (X1x)", "note slides (Gxy and Hxy)",
                                       "letting a key go after so many ticks (Qxx)", "tuning a note afresh (Fxx)", "glissando (X3x)"]

    /// OpenMPT's commands for Imago Orpheus's, by their numbers from 1 for A.
    private static let effects: [Effect] = [
        .none, .speed, .tempo, .slideToNote, .slideToNoteVolume, .vibrato, .vibratoVolume, .fineVibrato, .tremolo, .arpeggio, .pan, .panSlide,
        .volume, .volumeSlide, .volumeSlide, .finetune, .noteSlideUp, .noteSlideDown, .portaUp, .portaDown, .portaUp, .portaDown, .midi, .midi,
        .offset, .none, .keyOff, .retrig, .tremor, .jump, .breakRow, .globalVolume, .globalVolumeSlide, .s, .none, .none,
    ]

    /// A command of Imago Orpheus's as OpenMPT's (`TranslateIMFEffect`), with note taken of those that
    /// are left out.
    private static func convert(_ command: UInt8, _ value: UInt8, leftOut: inout Shortfall.Kinds) -> (Effect, UInt8) {
        var command = command, value = value
        switch command {
        case 0x0E:
            // A fine slide of volume, which Impulse Tracker's Dxy is with F for the other half.
            if value == 0xF0 {
                value = 0xEF
            } else if value == 0x0F {
                value = 0xFE
            } else if value & 0xF0 != 0 {
                value |= 0x0F
            } else if value != 0 {
                value |= 0xF0
            }
        case 0x0F:
            value ^= 0x80
            leftOut.note(LeftOut.finetune.rawValue)
        case 0x10, 0x11:
            leftOut.note(LeftOut.noteSlide.rawValue)
        case 0x14, 0x15:
            // A fine slide of pitch: by the first half, or as an extra fine one by the second.
            value = value >> 4 != 0 ? 0xF0 | value >> 4 : value | 0xE0
        case 0x16:
            // The filter's cutoff, which Zxx sets from 0 to 127, the other way up.
            value = (0xFF - value) / 2
        case 0x17:
            // Its slide is not played; its resonance is.
            if value >> 4 != 0 { leftOut.note(LeftOut.filterSlide.rawValue) }
            value = 0x80 | value & 0x0F
        case 0x19:
            if value != 0 { leftOut.note(LeftOut.fineOffset.rawValue) }
        case 0x1A:
            leftOut.note(LeftOut.keyOff.rawValue)
        case 0x1F:
            value = UInt8(min(255, Int(value) * 2))
        case 0x21:
            var high: UInt8 = 0
            switch value >> 4 {
            case 0:
                break
            case 0x3:
                // Glissando. (OpenMPT gives it as S2x, which is Scream Tracker's finetune, and
                // would put the channel out of tune; Impulse Tracker has no glissando.)
                if value & 0x0F != 0 { leftOut.note(LeftOut.glissando.rawValue) }
                command = 0
            case 0x5:
                high = 0x30
            case 0x8:
                high = 0x40
            case 0xA:
                high = 0xB0
            case 0xB:
                high = 0xE0
            case 0xC, 0xD:
                break
            case 0xE:
                // Which envelope is to be left alone: only one can be, and for all of them it is
                // the one for volume.
                switch value & 0x0F {
                case 0, 1: value = 0x77
                case 2: value = 0x79
                case 3: value = 0x7B
                default: break
                }
            default:
                if value >> 4 == 0xF { leftOut.note(LeftOut.loop.rawValue) }
                if value >> 4 == 0x1 { leftOut.note(LeftOut.filter.rawValue) }
                command = 0
            }
            if high != 0 { value = high | value & 0x0F }
        case 0x22:
            if value != 0 { leftOut.note(LeftOut.chorus.rawValue) }
        case 0x23:
            if value != 0 { leftOut.note(LeftOut.reverb.rawValue) }
        default:
            break
        }
        return (Int(command) < effects.count ? effects[Int(command)] : .none, value)
    }

    /// True for a command for the whole tune, which a channel that is switched off has no say in.
    private static func isGlobal(_ effect: Effect, _ value: UInt8) -> Bool {
        switch effect {
        case .jump, .breakRow, .speed, .tempo, .globalVolume, .globalVolumeSlide, .midi: true
        case .s: [0x60, 0x90, 0xB0, 0xE0].contains(value & 0xF0)
        default: false
        }
    }

    // MARK: Envelopes

    /// An envelope as the file has it, made into one of Impulse Tracker's as OpenMPT makes it
    /// (`IMFInstrument::ConvertEnvelope`, then `InstrumentEnvelope::Convert` from XM's way to IT's):
    /// its levels of 64 (of 256 for the place and the filter, which is upside down); a hold at its
    /// last point if it neither loops nor holds, for Impulse Tracker's envelope fades a note at its
    /// end where Imago Orpheus's does not; a hold after the loop ignored, which in Imago Orpheus's
    /// comes too late to matter; and its loop a tick shorter, which in Impulse Tracker's takes in
    /// the tick of its last point and in Imago Orpheus's does not.
    private static func envelope(_ f: ByteReader, nodes: Int, header: Int, kind: Int) -> IT2Envelope {
        let shift = kind == 0 ? 0 : 2, mirror: Int = kind == 2 ? 0xFF : 0
        let flags = f[header + 4]
        let enabled = flags & 1 != 0, loops = flags & 4 != 0
        var sustains = flags & 2 != 0
        var points: [(tick: Int, value: Int)] = []
        var least = 0
        for n in 0 ..< max(2, min(16, Int(f[header]))) {
            let tick = max(least, f.u16le(nodes + n * 4))
            points.append((tick, min(((f.u16le(nodes + n * 4 + 2) ^ mirror) & 0xFF) >> shift, 64)))
            least = tick + 1
        }
        var loopStart = Int(f[header + 2]), loopEnd = Int(f[header + 3]), sustain = Int(f[header + 1])
        if sustain > loopEnd, loops { sustains = false }
        if !loops, !sustains {
            sustains = true
            sustain = points.count - 1
        }
        if loopEnd > loopStart, loops, loopEnd < points.count {
            if points[loopEnd].tick - 1 > points[loopEnd - 1].tick {
                // A point of its own just before where the loop ended, at the level it is there.
                let tick = points[loopEnd].tick - 1
                points.insert((tick, valueAt(points, tick)), at: loopEnd)
            } else {
                loopEnd -= 1
            }
        }
        // (And then as OpenMPT makes any envelope fit to be played: its loops within its points.)
        let last = points.count - 1
        loopEnd = min(loopEnd, last)
        loopStart = min(loopStart, loopEnd)
        sustain = min(sustain, last)
        var made = IT2Envelope()
        made.Num = UInt8(points.count)
        for (n, point) in points.enumerated() {
            made.Tick[n] = UInt16(n == 0 ? 0 : min(point.tick, 0xFFFF))
            made.Magnitude[n] = Int8(kind == 0 ? point.value : point.value - 32)
        }
        if kind == 2, enabled { made.Flags |= ENVF_TYPE_FILTER }
        if enabled { made.Flags |= ENVF_ENABLED }
        if loops { made.Flags |= ENVF_LOOP }
        if sustains { made.Flags |= ENVF_SUSTAINLOOP }
        made.LoopBegin = UInt8(loopStart)
        made.LoopEnd = UInt8(loopEnd)
        made.SustainLoopBegin = UInt8(sustain)
        made.SustainLoopEnd = UInt8(sustain)
        return made
    }

    /// An envelope's level at a tick, of 64, as OpenMPT reckons it between its points.
    private static func valueAt(_ points: [(tick: Int, value: Int)], _ position: Int) -> Int {
        let unit = 1 << 16
        var at = points.count - 1
        for i in 0 ..< points.count - 1 where position <= points[i].tick {
            at = i
            break
        }
        let x2 = points[at].tick
        var value: Int
        if position >= x2 {
            value = points[at].value * unit / 64
        } else {
            var x1 = 0
            value = 0
            if at > 0 {
                value = points[at - 1].value * unit / 64
                x1 = points[at - 1].tick
            }
            if x2 > x1, position > x1 {
                let rise = points[at].value * unit / 64 - value
                value += Int((Int64(position - x1) * Int64(rise)) / Int64(x2 - x1))
            }
        }
        value = max(0, min(unit, value))
        return (value * 64 + unit / 2) / unit
    }

    // MARK: Reading

    /// Four bytes as a length, the first the least; one too large to be any is brought down to
    /// where it is still too large. (A whole number in a browser has 32 bits.)
    private static func long(_ f: ByteReader, _ i: Int) -> Int {
        let high = f.u16le(i + 2)
        return high >= 0x4000 ? 0x3FFF_FFFF : high << 16 | f.u16le(i)
    }

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> ITRenderer {
        guard isOne(data), data.count >= 576 else { throw TuneError.malformed("not an Imago Orpheus file") }
        let f = ByteReader(data)
        let orderCount = f.u16le(32), patternCount = f.u16le(34), instrumentCount = f.u16le(36), songFlags = f.u16le(38)
        let speed = f[48], tempo = f[49], master = f[50], amp = f[51]
        // The channels it has: up to the last that is not switched off. (A channel of a kind there
        // is none of makes it no file of Imago Orpheus's.)
        var channelCount = 0
        for channel in 0 ..< 32 {
            let status = f[64 + channel * 16 + 15]
            if status < 2 { channelCount = channel + 1 }
            if status > 2 { channelCount = 0; break }
        }
        guard orderCount <= 256, instrumentCount <= IT2Module.mostInstruments, tempo >= 32, master <= 64, amp >= 4, amp <= 127, channelCount > 0 else {
            throw TuneError.malformed("an Imago Orpheus file whose header makes no sense")
        }
        guard data.count >= 576 + 256 + patternCount * 4 + instrumentCount * 384 else { throw TuneError.malformed("an Imago Orpheus file that ends too soon") }

        let title = f.dos(at: 0, length: 32)
        var pans = [UInt8](repeating: 32, count: MAX_HOST_CHANNELS)
        var switchedOff = [Bool](repeating: false, count: 32)
        var muteStatus: UInt64 = 0
        for channel in 0 ..< channelCount {
            let at = 64 + channel * 16
            pans[channel] = UInt8((Int(f[at + 14]) * 256 / 255 + 2) / 4)
            let status = f[at + 15]
            muteStatus |= UInt64(status) << UInt64(channel * 2)
            if status != 0 { pans[channel] |= 128 }
            switchedOff[channel] = status == 2
        }
        // A file whose channels but the first are all silenced, which OpenMPT takes for one saved
        // wrongly, as no other file of Imago Orpheus's is known to be so.
        if channelCount == 16, muteStatus == 0x5555_5554 {
            for channel in 1 ..< channelCount { pans[channel] &= 0x7F }
        }
        // The rest are not there at all.
        for channel in channelCount ..< MAX_HOST_CHANNELS { pans[channel] = 32 | 128 }

        // MARK: Patterns

        var leftOut = Shortfall.Kinds()
        var noRoom = 0
        var patterns = [[UInt8]?](repeating: nil, count: max(IT2Module.MAX_PATTERNS, min(patternCount, IT2ForeignModule.patternRoom)))
        var rowCounts = [UInt16](repeating: 64, count: patterns.count)
        var at = 576 + 256
        for index in 0 ..< patternCount {
            let length = f.u16le(at), rowCount = f.u16le(at + 2)
            let start = at + 4, end = length < 4 ? data.count : min(data.count, start + length - 4)
            at = end
            guard rowCount > 0, rowCount <= 1024, index < IT2ForeignModule.patternRoom else { continue }
            var pattern = IT2ForeignModule.Pattern(rows: rowCount)
            var p = start, row = 0
            while row < rowCount, p < end {
                let mask = f[p]
                p += 1
                if mask == 0 {
                    row += 1
                    continue
                }
                let channel = Int(mask & 0x1F)
                var cell = OpenMPTCell()
                if mask & 0x20 != 0 {
                    let note = f[p], instrument = f[p + 1]
                    p += 2
                    cell.instrument = instrument
                    if note == 160 {
                        cell.note = 255
                    } else if note != 255 {
                        // An octave and a note in it, from C-0 as Impulse Tracker's C-1.
                        let number = Int(note >> 4) * 12 + Int(note & 0x0F) + 12
                        if number < 120 { cell.note = UInt8(number) }
                    }
                }
                if mask & 0xC0 == 0xC0 {
                    let first = convert(f[p], f[p + 1], leftOut: &leftOut), second = convert(f[p + 2], f[p + 3], leftOut: &leftOut)
                    p += 4
                    if let lost = cell.fill(first, second), lost.0 != .none, channel < channelCount { noRoom += 1 }
                } else if mask & 0xC0 != 0 {
                    let (effect, value) = convert(f[p], f[p + 1], leftOut: &leftOut)
                    p += 2
                    if effect == .volume {
                        cell.column = .volume(min(value, 64))
                    } else {
                        cell.effect = effect
                        cell.value = value
                    }
                }
                guard channel < channelCount else { continue }
                if switchedOff[channel], isGlobal(cell.effect, cell.value) { cell.effect = .none }
                let (made, lost) = cell.cell()
                if lost != nil { noRoom += 1 }
                pattern[row, channel] = made
            }
            patterns[index] = pattern.packed()
            rowCounts[index] = UInt16(rowCount)
        }

        // The list of patterns, in which 255 is a place to pass over, and a pattern the file does
        // not have is the end of the song, as it is to OpenMPT.
        var orders: [UInt8] = []
        for i in 0 ..< orderCount {
            let pattern = Int(f[576 + i])
            orders.append(pattern == 255 ? 254 : pattern < patternCount && pattern < patterns.count && patterns[pattern] != nil ? UInt8(pattern) : 255)
        }

        // MARK: Instruments and samples

        var instruments: [IT2Instrument] = []
        var samples: [IT2Sample] = []
        var cutShort = Shortfall.CutShort()
        var tooMany = 0
        for _ in 0 ..< instrumentCount {
            let ins = IT2Instrument()
            instruments.append(ins)
            let header = at
            at += 384
            ins.GlobVol = 128
            let sampleCount = f.u16le(header + 32 + 120 + 8 + 192 + 24 + 2)
            let first = samples.count + 1
            if sampleCount > 0 {
                for note in 0 ..< 108 {
                    let sample = first + Int(f[header + 32 + note])
                    ins.SmpNoteTable[note + 12] = UInt16(sample <= IT2ForeignModule.sampleRoom ? sample : 0) << 8 | UInt16(note + 12)
                }
            }
            for note in 0 ..< 12 { ins.SmpNoteTable[note] = UInt16(note) }
            let nodes = header + 32 + 120 + 8, headers = nodes + 192
            ins.VolEnv = envelope(f, nodes: nodes, header: headers, kind: 0)
            ins.PanEnv = envelope(f, nodes: nodes + 64, header: headers + 8, kind: 1)
            ins.PitchEnv = envelope(f, nodes: nodes + 128, header: headers + 16, kind: 2)
            // (The fade is kept as OpenMPT keeps it, finer than Impulse Tracker's: see `madTrackerFadeStep`.
            // A note of an instrument with neither a fade nor an envelope for its volume ends at once
            // when its key is let go.)
            var fade = f.u16le(headers + 24)
            if ins.VolEnv.Flags & ENVF_ENABLED == 0, fade == 0 { fade = 32767 }
            ins.FadeOut = UInt16(fade)

            for _ in 0 ..< sampleCount {
                let h = at
                let length = long(f, h + 16), flags = f[h + 48]
                at += 64
                let room = data.count - at
                cutShort.add(length: length, there: room)
                let there = max(0, min(length, room))
                defer { at += min(length, max(0, data.count - at)) }
                guard samples.count < IT2ForeignModule.sampleRoom else {
                    tooMany += 1
                    continue
                }
                let sixteen = flags & 4 != 0
                var loopStart = long(f, h + 20), loopEnd = long(f, h + 24)
                var frames = sixteen ? there / 2 : there
                let said = sixteen ? length / 2 : length
                if sixteen {
                    loopStart /= 2
                    loopEnd /= 2
                }
                frames = min(frames, said)
                // (A loop that runs past the end of the sample as the file says it is ends there.)
                loopEnd = min(loopEnd, said)
                let sound8: [Int8] = sixteen ? [] : (0 ..< frames).map { Int8(bitPattern: f[at + $0]) }
                let sound16: [Int16] = sixteen ? (0 ..< frames).map { Int16(truncatingIfNeeded: f.u16le(at + $0 * 2)) } : []
                var rate = long(f, h + 28)
                if rate == 0 { rate = 8363 }
                let s = IT2ForeignModule.sample(sound8: sound8, sound16: sound16, volume: f[h + 32], rate: UInt32(min(rate, 9_999_999)),
                                                loops: flags & 1 != 0, backAndForth: flags & 2 != 0, loopStart: loopStart, loopEnd: min(loopEnd, frames),
                                                pan: flags & 8 != 0 ? UInt8((Int(f[h + 33]) + 2) / 4) : nil)
                // The nine places a note can be started from with the volume column's offset, which
                // OpenMPT gives every sample of these files.
                s.cues = (1 ..< 10).map { UInt32($0 * 255 * 256 / 9) }
                samples.append(s)
            }
        }
        while samples.count < IT2Module.MAX_SAMPLES { samples.append(IT2ForeignModule.sample(volume: 0, rate: 8363)) }
        while instruments.count < IT2Module.MAX_INSTRUMENTS { instruments.append(IT2Instrument()) }

        var shortfalls: [String] = []
        if noRoom > 0 {
            shortfalls.append(Shortfall.some(noRoom, one: "notes has more commands than Impulse Tracker's replayer has room for, and one is left out.",
                                             many: "notes have more commands than Impulse Tracker's replayer has room for, and one of each is left out."))
        }
        if tooMany > 0 {
            shortfalls.append(Shortfall.some(tooMany, one: "samples is beyond the most there is room for, and is left out.",
                                             many: "samples are beyond the most there is room for, and are left out."))
        }
        if let sentence = Shortfall.commandsLeftOut(leftOut.named(leftOutNames)) { shortfalls.append(sentence) }
        if let sentence = cutShort.sentence { shortfalls.append(sentence) }

        var song = OpenMPTSong()
        var sequence = OpenMPTSong.Sequence()
        sequence.count = orders.count
        sequence.speed = max(1, speed)
        sequence.tempo = Int(tempo) * OpenMPTSong.tempoUnit
        song.sequences = [sequence]
        song.patternRowsPerBeat = [UInt16](repeating: 0, count: patterns.count)
        song.patternSwing = [[UInt32]](repeating: [], count: patterns.count)
        song.offsetAsImpulseTracker = true
        song.loopsOutlastJumps = false
        song.unmappedNotesKeepCommands = false
        song.gain = loudness

        let flags = ITF_STEREO | ITF_INSTR_MODE | (songFlags & 1 != 0 ? ITF_LINEAR_FRQ : 0)
        let module = IT2Module(title: title, madeWith: "Imago Orpheus", orders: orders, flags: flags, globalVolume: master * 2, mixVolume: amp,
                               speed: max(1, speed), tempo: tempo, channelPans: pans, samples: samples, patterns: patterns, rows: rowCounts,
                               instruments: instruments, openMPT: song, filter: .imagoOrpheus)
        module.imagoOrpheus = true
        return ITRenderer(module: module, format: "IMF", shortfalls: shortfalls, options: options)
    }

    /// Set by measure: see the README.
    private static let loudness: Float = 1.22
}
