// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// how it reads a module of Symphonie's and what it makes of one (`soundlib/Load_symmod.cpp`, by Devin
// Acker and the OpenMPT developers).

import SidayFoundation

extension SymMODFile {
    // MARK: Reading the file

    /// The parts of the file, in whatever order it has them, as OpenMPT reads them: each a number
    /// that says what it is, and a value or a part that may be packed. Of each list the first is
    /// taken; samples come one by one, in the order of the instruments, and a sample of two sides is
    /// two, the right and then the left.
    struct Parts {
        var trackLength = 0
        /// OpenMPT's tempo, in ten-thousandths: 1.24 times the file's.
        var tempo = 125 * OpenMPTSong.tempoUnit
        var sampleBoost = 2500
        var isPro = false, externalSamples = false, unknownParts = false, detune = false
        var positions: [Position] = [], sequences: [Sequence] = [], events: [Event] = [], instruments: [Instrument] = []
        var samples = Samples()
        /// Samples of a kind of sound file that is not read here.
        var unreadSamples = 0
        /// True if the file ends in the middle of a part that is part of the music.
        var cutShort = false
    }

    static func parts(_ data: [UInt8]) throws -> Parts {
        var parts = Parts()
        var r = SymMODBytes(data)
        r.skip(16)
        func array<T>(_ size: Int, _ make: ([UInt8], Int) -> T) -> [T] {
            let bytes = decoded(&r)
            return (0 ..< bytes.count / size).map { make(bytes, $0 * size) }
        }
        let mostSamples = 3999
        while r.canRead(4) {
            let type = Int32(bitPattern: r.u32be())
            // (A part the file ends in the middle of, which is not the tune's text nor one passed over,
            // is music that the file has lost, and what follows it is lost too.)
            defer { if r.overran, !parts.cutShort, type != -16, !(-21 ... -19).contains(type) { parts.cutShort = true } }
            switch type {
            case -1: // the number of channels, which the heading has given
                r.skip(4)
            case -2: // the length of a track
                parts.trackLength = SymMODBytes.length(r.u32be())
                if parts.trackLength > 1024 { throw TuneError.malformed("a Symphonie module whose tracks are longer than 1024 lines") }
            case -5: // the size of an event
                if r.u32be() & 0xFFFF != 4 { throw TuneError.unsupported("a Symphonie module whose events are not of four bytes") }
            case -6:
                parts.tempo = Int((1.24 * Double(min(r.u32be(), 800)) * Double(OpenMPTSong.tempoUnit)).rounded(.toNearestOrAwayFromZero))
            case -4, -3: // the number of instruments, which their list gives, and the size of a track
                r.skip(4)
            case 10: // Symphonie Pro's: how loud every sample is made
                parts.sampleBoost = Int(min(r.u32be(), 10000))
                parts.isPro = true
            case 11, 12: // and its stereo detune and phase
                parts.isPro = true
                if r.u32be() != 0 { parts.detune = true }
            case -7:
                r.skip(4)
                if parts.samples.count == 0 { parts.externalSamples = true }
            case -10:
                if parts.positions.isEmpty { parts.positions = array(32) { Position($0, $1) } } else { r.skip(SymMODBytes.length(r.u32be())) }
            case -11, -17, -18:
                // A sample's sound: as it is, or packed in eight bits or sixteen.
                if parts.samples.count >= parts.instruments.count { break }
                guard !parts.externalSamples, parts.samples.count < mostSamples else {
                    r.skip(SymMODBytes.length(r.u32be()))
                    break
                }
                parts.samples.count += 1
                let index = parts.samples.count
                let file: SymMODBytes
                if type == -11 {
                    file = r.chunk(SymMODBytes.length(r.u32be()))
                } else {
                    file = SymMODBytes(type == -17 ? decodedSample8(&r) : decodedSample16(&r))
                }
                let sound = SymMODSound.iff(file) ?? SymMODSound.wav(file) ?? SymMODSound.aiff(file) ?? SymMODSound.raw(file) ?? SymMODSound()
                if sound.unread { parts.unreadSamples += 1 }
                if sound.stereo, parts.samples.count < mostSamples {
                    // Symphonie keeps a stereo instrument as two of one side each, played together:
                    // the sample is split between this one and the next, as OpenMPT splits it.
                    parts.samples.count += 1
                    if sound.hasData {
                        let (left, right) = sound.split()
                        parts.samples[index] = right
                        parts.samples[index + 1] = left
                    } else {
                        parts.samples[index] = sound
                    }
                } else {
                    parts.samples[index] = sound
                    // (A mono sample followed by the second of a pair leaves that one's place empty.)
                    if index < parts.instruments.count, parts.instruments[index].channel == Side.stereoR, parts.samples.count < mostSamples {
                        parts.samples.count += 1
                    }
                }
            case -12: // an instrument with no sample
                if parts.samples.count < mostSamples { parts.samples.count += 1 }
            case -13:
                if parts.events.isEmpty { parts.events = array(4) { Event($0, $1) } } else { r.skip(SymMODBytes.length(r.u32be())) }
            case -14:
                if parts.instruments.isEmpty { parts.instruments = array(256) { Instrument($0, at: $1) } } else { r.skip(SymMODBytes.length(r.u32be())) }
            case -15:
                if parts.sequences.isEmpty { parts.sequences = array(16) { Sequence($0, $1) } } else { r.skip(SymMODBytes.length(r.u32be())) }
            case -16: // the tune's text
                _ = decoded(&r)
            case -19, -20, -21:
                r.skip(SymMODBytes.length(r.u32be()))
            default:
                // (Some files have more after them, that is no part.)
                parts.unknownParts = true
            }
        }
        return parts
    }

    // MARK: Making the module

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> ITRenderer {
        guard isOne(data) else { throw TuneError.malformed("not a Symphonie module") }
        var header = SymMODBytes(data)
        header.skip(12)
        let fileChannels = SymMODBytes.length(header.u32be())
        // (OpenMPT plays 192 at the most, and Impulse Tracker's replayer 64.)
        let channels = min(192, fileChannels)
        var p = try parts(data)
        guard p.trackLength > 0, !p.instruments.isEmpty else { throw TuneError.malformed("a Symphonie module with no tracks or no instruments") }
        guard !p.positions.isEmpty, !p.events.isEmpty, !p.sequences.isEmpty else { throw TuneError.malformed("a Symphonie module with nothing to play") }
        if p.externalSamples { throw TuneError.unsupported("a Symphonie module whose samples are in other files") }
        if p.instruments.count >= 256 { p.instruments.removeLast(p.instruments.count - 255) }
        let instrumentCount = p.instruments.count
        p.samples.count = max(p.samples.count, instrumentCount)

        // MARK: Instruments

        // The usual ones first, and then the virtual ones, which are made of the others' samples as
        // those are once made. Each instrument plays the sample of its own number, unless it is a
        // virtual one that could not be made, which plays the first of its parts' samples.
        struct Made {
            var sample = 0
            var volume = 64, plugIn = 0, cutoff = 0, resonance = 0
        }
        var made = [Made?](repeating: nil, count: instrumentCount + 1)
        for pass in 0 ..< 2 {
            for ins in 1 ... instrumentCount {
                var symInst = p.instruments[ins - 1]
                if symInst.isEmpty || symInst.isVirtual != (pass == 1) { continue }
                var sample = ins
                if symInst.headerIsVirtual {
                    let firstSource = Int(symInst.event(0).inst)
                    if let (sound, ok) = rendered(symInst, asQueue: symInst.sampleFlags & SampleFlag.asQueue != 0, from: p.samples, boost: p.sampleBoost) {
                        p.samples[sample] = sound
                        if ok {
                            if firstSource < instrumentCount { symInst.add(downsample: p.instruments[firstSource].downsample) }
                        } else {
                            sample = firstSource + 1
                        }
                    } else {
                        sample = firstSource + 1
                    }
                } else if symInst.headerIsTranswave {
                    let first = symInst.transwave(0), second = symInst.transwave(1)
                    if first.source < p.samples.count {
                        let source2 = second.source < p.samples.count ? p.samples[second.source + 1] : SymMODSound()
                        if let sound = transwave(symInst, p.samples[first.source + 1], source2) {
                            p.samples[sample] = sound
                            // (Played an octave down and read four times as finely, which is an octave up.)
                            symInst.add(transpose: 12)
                        } else {
                            p.samples[sample] = SymMODSound()
                        }
                    }
                }
                p.instruments[ins - 1] = symInst
                var result = Made(sample: sample)
                if sample <= p.samples.count {
                    var sound = p.samples[sample]
                    let converted = convert(symInst, &sound)
                    p.samples[sample] = sound
                    result.volume = converted.volume
                    result.plugIn = converted.plugIn
                    result.cutoff = converted.cutoff
                    result.resonance = converted.resonance
                }
                made[ins] = result
            }
        }

        // MARK: Patterns

        let converted = convert(fileChannels: fileChannels, channels: channels, trackLength: p.trackLength, positions: &p.positions,
                                sequences: p.sequences, events: p.events, instruments: p.instruments)
        guard converted.patterns.count <= IT2ForeignModule.patternRoom else {
            throw TuneError.unsupported("a Symphonie module with more than \(IT2ForeignModule.patternRoom) patterns")
        }

        // What an IT file's cells have no room for is kept beside them for the replayer.
        typealias Cell = IT2ForeignModule.Cell
        var cells: [Int: IT2SymphonieCell] = [:]
        var packed = [[UInt8]?](repeating: nil, count: IT2ForeignModule.patternRoom)
        var rowCounts = [UInt16](repeating: 0, count: IT2ForeignModule.patternRoom)
        var tooHigh = 0, tooMany = 0, tooLong = 0
        let heard = min(MAX_HOST_CHANNELS, channels)
        var droppedChannels = false
        for (index, pattern) in converted.patterns.enumerated() {
            let rows = converted.rows[index]
            if rows > 1024 { tooLong += 1 }
            var it = IT2ForeignModule.Pattern(rows: min(rows, 1024))
            for row in 0 ..< min(rows, 1024) {
                for channel in 0 ..< channels {
                    let m = pattern[row * channels + channel]
                    if m.note == 0, m.instr == 0, m.volcmd == 0, m.command == 0 { continue }
                    guard channel < heard else {
                        droppedChannels = true
                        continue
                    }
                    var cell = Cell()
                    var extra = IT2SymphonieCell()
                    if m.note >= 1, m.note <= 120 {
                        cell.set(note: m.note - 1)
                    } else if m.note == 255 || m.note == 254 {
                        cell.set(note: m.note)
                    } else if m.note != 0 {
                        tooHigh += 1
                    }
                    if m.instr != 0 {
                        if Int(m.instr) <= IT2Module.mostInstruments { cell.set(instrument: m.instr) } else { tooMany += 1 }
                    }
                    switch m.volcmd {
                    case MPT.volTonePorta: cell.set(volume: 193 + min(m.vol, 9))
                    case MPT.volPortaUp: cell.set(volume: 115 + min(m.vol, 9))
                    case MPT.volPortaDown: cell.set(volume: 105 + min(m.vol, 9))
                    case MPT.volOffset: cell.set(volume: 223 + min(m.vol, 9))
                    case MPT.volPlayControl: extra.playControl = m.vol
                    default: break
                    }
                    typealias Letter = IT2ForeignModule.Command
                    switch m.command {
                    case MPT.speed: cell.set(command: Letter.A, m.param)
                    case MPT.portaUp: cell.set(command: Letter.F, m.param)
                    case MPT.portaDown: cell.set(command: Letter.E, m.param)
                    case MPT.tonePorta: cell.set(command: Letter.G, m.param)
                    case MPT.vibrato: cell.set(command: Letter.H, m.param)
                    case MPT.tremolo: cell.set(command: Letter.R, m.param)
                    case MPT.retrig: cell.set(command: Letter.Q, m.param)
                    case MPT.channelVolume: cell.set(command: 13, m.param) // M
                    case MPT.channelVolSlide: cell.set(command: 14, m.param) // N
                    case MPT.midi: cell.set(command: 26, m.param) // Z
                    case MPT.offsetPercentage: extra.offset = m.param
                    case MPT.tonePortaDuration:
                        // A slide to the note that is there at once: a slide with what it has, that
                        // the replayer then brings to its end.
                        cell.set(command: Letter.G, 0)
                        extra.atOnce = true
                    default: break
                    }
                    if extra.playControl != nil || extra.offset != nil || extra.atOnce {
                        cells[OpenMPTSong.place(pattern: index, row: row, channel: channel)] = extra
                    }
                    if cell.mask != 0 { it[row, channel] = cell }
                }
            }
            packed[index] = it.packed()
            rowCounts[index] = UInt16(min(rows, 1024))
        }

        var orders: [UInt8] = converted.orders.map { $0 == Converted.skip ? 254 : UInt8($0) }
        if orders.isEmpty { orders = [255] }

        // MARK: Samples and instruments as the replayer has them

        let sampleCount = min(p.samples.count, IT2Module.mostSamples)
        var samples: [IT2Sample] = []
        var unplayable = 0
        for index in 1 ... max(1, sampleCount) {
            let sound = p.samples[index]
            let s: IT2Sample
            if sound.hasData {
                s = IT2ForeignModule.sample(sound8: sound.sixteen ? [] : sound.bytes, sound16: sound.sixteen ? sound.words : [], volume: UInt8(min(64, sound.volume / 4)),
                                            rate: sound.rate, loops: sound.loops, loopStart: sound.loopStart, loopEnd: sound.loopEnd)
            } else {
                s = IT2Sample()
                s.Vol = UInt8(min(64, sound.volume / 4))
                s.C5Speed = sound.rate
            }
            s.GlobVol = UInt8(min(64, sound.globalVolume))
            // (A key let go goes on from where the sound has gone round its loop as often as it is to.)
            s.cues = [UInt32(truncatingIfNeeded: min(sound.cue ?? SymMODSound.mostFrames, SymMODSound.mostFrames))] + [UInt32](repeating: UInt32(SymMODSound.mostFrames), count: 8)
            if sound.vibratoDepth != 0, sound.vibratoRate != 0 {
                // (OpenMPT's numbers for the waves, as Impulse Tracker's.)
                s.AutoVibratoWaveform = [0, 2, 4, 1, 3][min(4, sound.vibratoType)]
                s.AutoVibratoSpeed = UInt8(min(64, sound.vibratoRate))
                s.AutoVibratoDepth = UInt8(min(32, sound.vibratoDepth))
                s.AutoVibratoRate = UInt8(min(255, sound.vibratoSweep))
            }
            samples.append(s)
        }
        while samples.count < IT2Module.MAX_SAMPLES { samples.append(IT2Sample()) }

        var instruments: [IT2Instrument] = []
        for ins in 1 ... min(instrumentCount, IT2Module.mostInstruments) {
            let it = IT2Instrument()
            if let result = made[ins] {
                if result.sample > IT2Module.mostSamples, result.sample <= p.samples.count { unplayable += 1 }
                let sample = result.sample <= sampleCount ? UInt16(result.sample) : 0
                for note in 0 ..< 120 { it.SmpNoteTable[note] = UInt16(note) | sample << 8 }
                it.GlobVol = UInt8(result.volume * 2)
                it.FadeOut = 256 >> 5
                it.FilterCutoff = UInt8(result.cutoff)
                it.FilterResonance = UInt8(result.resonance)
                it.MixPlug = UInt8(result.plugIn)
            } else {
                // (An empty instrument plays nothing.)
                it.GlobVol = 0
            }
            instruments.append(it)
        }
        // (Of Symphonie Pro's 255, the last can be named by no note here.)
        for ins in stride(from: IT2Module.mostInstruments + 1, through: instrumentCount, by: 1) where made[ins] != nil { unplayable += 1 }
        while instruments.count < IT2Module.MAX_INSTRUMENTS { instruments.append(IT2Instrument()) }

        // MARK: What is not heard

        var shortfalls: [String] = []
        let left = converted.leftOut
        var names: [String] = []
        if left.addVolume > 0 { names.append("adding to a note's volume") }
        if left.addPitch > 0 { names.append("adding to its pitch") }
        if left.emphasis > 0 { names.append("its emphasis") }
        if left.delay > 0 { names.append("the DSP's delay") }
        if left.filters > 0 { names.append("filters of kinds OpenMPT has not got") }
        if left.cv > 0 { names.append("CV of its other kinds") }
        if let sentence = Shortfall.commandsLeftOut(names, why: names.count == 1 ? "as OpenMPT leaves it out" : "as OpenMPT leaves them out") { shortfalls.append(sentence) }
        if p.detune { shortfalls.append("Its stereo detune and phase are left out, as OpenMPT leaves them out.") }
        if p.unreadSamples > 0 {
            shortfalls.append(Shortfall.some(p.unreadSamples, one: "samples is kept in a kind of sound file that is not read, and is not heard.",
                                             many: "samples are kept in kinds of sound file that are not read, and are not heard."))
        }
        if droppedChannels { shortfalls.append("It has more than \(MAX_HOST_CHANNELS) channels, and those after them are left out.") }
        if tooHigh > 0 { shortfalls.append(Shortfall.some(tooHigh, one: "notes is above the highest that can be played, and is left out.", many: "notes are above the highest that can be played, and are left out.")) }
        if tooMany + unplayable > 0 { shortfalls.append("Its instruments or samples beyond the most there is room for are not heard.") }
        if tooLong > 0 { shortfalls.append("Its places of more than 1024 lines are played as far as that.") }
        if p.cutShort { shortfalls.append(Shortfall.cutShort("Some of what it has is not there.")) }

        // MARK: The rest

        // The whole tune played as OpenMPT plays these files: by Impulse Tracker's ways, but for
        // one, that a note is struck again even once its sample has ended.
        var song = OpenMPTSong()
        var sequence = OpenMPTSong.Sequence()
        sequence.first = 0
        sequence.count = orders.count
        sequence.restart = 0
        sequence.speed = 6
        sequence.tempo = max(OpenMPTSong.leastTempo * OpenMPTSong.tempoUnit, min(OpenMPTSong.mostTempo * OpenMPTSong.tempoUnit, p.tempo))
        song.sequences = [sequence]
        song.patternRowsPerBeat = [UInt16](repeating: 0, count: IT2ForeignModule.patternRoom)
        song.patternSwing = [[UInt32]](repeating: [], count: IT2ForeignModule.patternRoom)
        song.tempoCeiling = 255
        song.offsetAsImpulseTracker = true
        song.loopsOutlastJumps = false
        song.unmappedNotesKeepCommands = false
        song.itVibrato = true
        song.ways.retriggersEndedNotes = true
        // How loud: OpenMPT's pre-amp is the more the fewer the channels, and is the mixing volume.
        let preAmp = max(16, min(128, 512 / max(1, channels)))
        song.gain = loudness

        // The echo, if a track has it, which every channel goes through, but for an instrument that
        // says it is not to; and the macros that set it and the filter.
        var sound: ModPlugSound?
        if converted.useDSP {
            var echo = ModPlugPlugIn()
            echo.first = 0x4D6D_7953 // "SymM"
            echo.second = 0x6F68_6345 // "Echo"
            echo.routingFlags = ModPlugPlugIn.autoSuspend
            echo.gain = 10
            echo.name = "Echo"
            echo.libraryName = "SymMOD Echo"
            var plugIns = ModPlugSound()
            plugIns.plugIns = [echo, ModPlugPlugIn()]
            plugIns.channelPlugIns = [Int](repeating: 1, count: MAX_HOST_CHANNELS)
            sound = plugIns
        }
        var midi = IT2Module.defaultMIDIData()
        for (param, macro) in converted.macros where param < 128 {
            // (After the nine of the whole file and the sixteen of SFx, the 128 of Z80 to ZFF.)
            let at = (25 + param) * 32
            for i in 0 ..< 32 { midi[at + i] = i < macro.count ? macro[i] : 0 }
        }

        var pans = [UInt8](repeating: 32, count: MAX_HOST_CHANNELS)
        for channel in 0 ..< MAX_HOST_CHANNELS { pans[channel] = channel & 1 != 0 ? 64 : 0 }
        let module = IT2Module(title: "", madeWith: !p.isPro ? "Symphonie" : instrumentCount <= 128 ? "Symphonie Pro" : "Symphonie Pro 256", orders: orders,
                               flags: ITF_STEREO | ITF_INSTR_MODE | ITF_LINEAR_FRQ | ITF_MPT_EXT_FILTER_RANGE, globalVolume: 128, mixVolume: UInt8(preAmp),
                               speed: 6, tempo: UInt8(max(31, min(255, sequence.tempo / OpenMPTSong.tempoUnit))), channelPans: pans,
                               samples: samples, patterns: packed, rows: rowCounts, sound: sound, instruments: instruments, openMPT: song,
                               filter: .openMPTsCurve, midiData: midi, longList: true)
        module.playsAsSymphonie = true
        module.symphonieCells = cells
        return try ITRenderer(module: module, format: "SymMOD", shortfalls: shortfalls, options: options)
    }

    /// Set by measure, so that these files are about as loud as other modules: played as loud as
    /// OpenMPT plays them, the middle one of them is 2.3 dB quieter than the middle module.
    private static let loudness: Float = 1.3
}
