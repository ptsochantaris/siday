// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// how it reads a module of Symphonie's and what it makes of one (`soundlib/Load_symmod.cpp`, by Devin
// Acker and the OpenMPT developers), and where it puts a command for the whole row (`pattern.cpp`).

extension SymMODFile {
    // MARK: What OpenMPT makes of the tracks

    /// OpenMPT's own numbers for the commands, and the volume column's, that it makes these files'
    /// events into.
    enum MPT {
        static let portaUp: UInt8 = 2, portaDown: UInt8 = 3, tonePorta: UInt8 = 4, vibrato: UInt8 = 5, tremolo: UInt8 = 8, retrig: UInt8 = 15
        static let speed: UInt8 = 16, channelVolume: UInt8 = 21, channelVolSlide: UInt8 = 22, midi: UInt8 = 31, offsetPercentage: UInt8 = 44
        static let tonePortaDuration: UInt8 = 55
        static let volTonePorta: UInt8 = 11, volPortaUp: UInt8 = 12, volPortaDown: UInt8 = 13, volPlayControl: UInt8 = 14, volOffset: UInt8 = 15
        /// OpenMPT's notes run from 1 to 128; nought is none.
        static let noteMin = 1, noteMax = 128
    }

    /// One channel's part of a row as OpenMPT makes it.
    struct MPTCell {
        var note: UInt8 = 0, instr: UInt8 = 0, volcmd: UInt8 = 0, vol: UInt8 = 0, command: UInt8 = 0, param: UInt8 = 0

        mutating func effect(_ command: UInt8, _ param: UInt8) {
            self.command = command
            self.param = param
        }

        mutating func volume(_ command: UInt8, _ vol: UInt8) {
            volcmd = command
            self.vol = vol
        }
    }

    /// What OpenMPT keeps of each channel as it goes through the tracks: Symphonie's slides and
    /// vibratos are its own, and go on from row to row, and are made into Impulse Tracker's commands
    /// row by row.
    private struct ChannelState {
        var curVolSlide: Float = 0, curVolSlideAmt: Float = 0, curPitchSlide: Float = 0, curPitchSlideAmt: Float = 0
        var stopped = false
        var lastNote: UInt8 = 0, lastInst: UInt8 = 0, lastVol: UInt8 = 64, channelVol: UInt8 = 100, calculatedVol: UInt8 = 64
        var fromAdd: UInt8 = 0
        var retrigVibrato = false, curVibrato: UInt8 = 0, retrigTremolo = false, curTremolo: UInt8 = 0
        var sampleVibSpeed: UInt8 = 0, sampleVibDepth: UInt8 = 0, tonePortaAmt: UInt8 = 0
        var sampleVibPhase: UInt16 = 0, retriggerRemain: UInt16 = 0, tonePortaRemain: UInt16 = 0
    }

    /// What is in the tracks that is not played, as OpenMPT does not play it.
    struct LeftOut {
        var addVolume = 0, addPitch = 0, emphasis = 0, delay = 0, filters = 0, cv = 0
    }

    /// The tracks made into patterns, as OpenMPT makes them: one for every place in a sequence that
    /// is not the same as one before it, each played as often as the place says, the sequences one
    /// after another with a mark between them; and the macros its DSP commands are made into.
    struct Converted {
        var patterns: [[MPTCell]] = []
        var rows: [Int] = []
        /// Each pattern's number, or `skip` for the mark between sequences.
        var orders: [Int] = []
        var macros: [Int: [UInt8]] = [:]
        var useDSP = false
        var leftOut = LeftOut()
        static let skip = -1
    }

    /// OpenMPT's numbers to round as it does: half away from nought, and within a byte.
    private static func roundedByte(_ value: Float) -> UInt8 {
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        return rounded <= 0 || rounded.isNaN ? 0 : rounded >= 255 ? 255 : UInt8(rounded)
    }

    private static func roundedByte(_ value: Double) -> UInt8 {
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        return rounded <= 0 || rounded.isNaN ? 0 : rounded >= 255 ? 255 : UInt8(rounded)
    }

    private static func mulDivRoundedUnsigned(_ a: UInt8, _ b: UInt8, _ c: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: (Int(a) * Int(b) + c / 2) / c)
    }

    /// A DSP command as one of the macros a Zxx command sends: a filter's cutoff, resonance and kind
    /// (as near to Symphonie's as OpenMPT's filter has, and none for one of a kind it has not got), or
    /// the echo's kind, length and feedback. Nil for the DSP's delay, which OpenMPT does not play.
    private static func macro(_ event: Event) -> [UInt8]? {
        func hex(_ value: Int) -> String {
            let digits = Array("0123456789ABCDEF".utf8)
            return String(decoding: [digits[(value >> 4) & 15], digits[value & 15]], as: UTF8.self)
        }
        if event.command == Command.filter {
            let type = UInt32(bitPattern: Int32(event.note)) % 5
            let reso = min(127, Int(event.inst) * 127 / 185)
            let cutoff = cutoffSetting(Double(event.param) * 10000.0 / 240.0)
            if type == 1 { return Array("F0F000\(hex(cutoff)) F0F001\(hex(reso)) F0F00200".utf8) }
            if type == 2 { return Array("F0F000\(hex(cutoff)) F0F001\(hex(reso)) F0F00210".utf8) }
            return Array("F0F0007F F0F00100".utf8)
        } else if event.command == Command.dspEcho {
            let type = event.note < 5 ? Int(event.note) : 0
            return Array("F0F080\(hex(type)) F0F081\(hex(Int(min(event.param, 127)))) F0F082\(hex(Int(min(event.inst, 127))))".utf8)
        }
        return nil
    }

    /// A cutoff in hertz as one of the filter's 128 settings, on the wider range of them: as OpenMPT reckons it.
    private static func cutoffSetting(_ hertz: Double) -> Int {
        let setting = (log(hertz) - 4.8737671609324025) * (20.0 / 0.6931471805599453)
        let held = setting.isNaN ? 0 : max(0, min(127, setting))
        return Int(held.rounded(.toNearestOrAwayFromZero))
    }

    /// Goes through the sequences and makes their places into patterns.
    /// - Parameters:
    ///   - fileChannels: how many channels the file's tracks have; `channels`, how many OpenMPT plays.
    ///   - positions: the places, which OpenMPT changes as it goes and does not always put back.
    static func convert(fileChannels: Int, channels: Int, trackLength: Int, positions: inout [Position], sequences: [Sequence],
                        events: [Event], instruments: [Instrument]) -> Converted {
        var converted = Converted()
        let patternSize = fileChannels * trackLength
        let numPatterns = patternSize > 0 ? min(0xFFFF, events.count / patternSize) : 0
        var patternMap: [PositionKey: Int] = [:]
        // The macros the DSP commands have been made into, by what the command was: kept in order,
        // as OpenMPT keeps them, for finding the nearest when they have run out.
        var macroMap: [(event: Event, macro: UInt8)] = []
        var states = [ChannelState](repeating: ChannelState(), count: channels)
        func instrument(_ number: Int) -> Instrument? { number >= 0 && number < instruments.count ? instruments[number] : nil }

        for seq in sequences {
            if seq.info == 1 { continue }
            if seq.info == -1 { break }
            if seq.start >= positions.count || seq.length > positions.count || seq.length == 0 || positions.count - seq.length < seq.start { continue }
            if !converted.orders.isEmpty { converted.orders.append(Converted.skip) }

            placeLoop: for place in seq.start ..< seq.start + seq.length {
                // (The sequence's transposition is added before the place is looked for among those
                // made already, and taken away again after.)
                positions[place].transpose = Int(Int16(truncatingIfNeeded: positions[place].transpose + seq.transpose))
                let pos = positions[place]
                var patternIndex = 0
                let key = PositionKey(pattern: pos.pattern, start: pos.start, length: pos.length, transpose: pos.transpose, speed: pos.speed)
                if let made = patternMap[key] {
                    patternIndex = made
                } else {
                    // (A place of no lines, or of more than a pattern can have, ends the sequence.)
                    guard pos.length >= 1, pos.length <= 4096, converted.patterns.count < 4000 else { break placeLoop }
                    patternIndex = converted.patterns.count
                    var cells = [MPTCell](repeating: MPTCell(), count: pos.length * channels)
                    converted.rows.append(pos.length)
                    patternMap[key] = patternIndex
                    // (A place beyond the tracks is an empty pattern, and is not put in the list.)
                    if pos.pattern >= numPatterns || pos.start >= trackLength {
                        converted.patterns.append(cells)
                        continue placeLoop
                    }
                    convertRows(pos, into: &cells, &converted, fileChannels: fileChannels, channels: channels, trackLength: trackLength,
                                events: events, instruments: instruments, states: &states, macroMap: &macroMap, instrument: instrument)
                    writeSpeed(UInt8(truncatingIfNeeded: pos.speed), into: &cells, rows: pos.length, channels: channels)
                    converted.patterns.append(cells)
                }
                let count = min(max(pos.loopNum, 1), max(0, 4000 - converted.orders.count))
                for _ in 0 ..< count { converted.orders.append(patternIndex) }
                positions[place].transpose = Int(Int16(truncatingIfNeeded: positions[place].transpose - seq.transpose))
            }
        }
        return converted
    }

    /// One place's lines of the tracks, made into a pattern's rows.
    private static func convertRows(_ pos: Position, into cells: inout [MPTCell], _ converted: inout Converted, fileChannels: Int, channels: Int, trackLength: Int,
                                    events: [Event], instruments: [Instrument], states: inout [ChannelState], macroMap: inout [(event: Event, macro: UInt8)],
                                    instrument: (Int) -> Instrument?) {
        func setMacro(_ event: Event, _ value: UInt8) {
            if let index = macroMap.firstIndex(where: { $0.event == event }) {
                macroMap[index].macro = value
            } else {
                let at = macroMap.firstIndex { event < $0.event } ?? macroMap.count
                macroMap.insert((event, value), at: at)
            }
        }
        var patternSpeed = UInt8(truncatingIfNeeded: pos.speed)
        // (This may go on into the next track, and does on purpose.)
        var source = pos.pattern * fileChannels * trackLength + pos.start * fileChannels
        var syncPlayCommand = MPTCell()
        for row in 0 ..< pos.length {
            let base = row * channels
            var applySyncPlay = false
            for chn in 0 ..< fileChannels {
                let event = source < events.count ? events[source] : Event()
                if source < events.count { source += 1 }
                if chn >= channels { continue }
                let at = base + chn
                var m = cells[at]
                var state = states[chn]
                defer {
                    cells[at] = m
                    states[chn] = state
                }

                var note: Int8 = event.note >= 0 && event.note <= 84 ? event.note + 25 : -1
                let origInst = Int(event.inst)
                var mappedInst: UInt8 = 0
                if let ins = instrument(origInst) {
                    mappedInst = UInt8(origInst + 1)
                    if ins.instFlags & InstFlag.noTranspose == 0, note >= 0 {
                        note = max(Int8(MPT.noteMin), Int8(truncatingIfNeeded: Int(note) + pos.transpose))
                    }
                }

                // A stereo instrument's note copied to this channel, where this channel has an event of its own, is taken away again.
                if m.note != 0, event.command != Command.keyOn || event.note != -1 || event.inst != 0 || event.param != 0,
                   m.instr > 0, instrument(Int(m.instr) - 1)?.channel == Side.stereoR {
                    m = MPTCell()
                }

                if applySyncPlay {
                    applySyncPlay = false
                    m = syncPlayCommand
                    if m.command == 0, state.calculatedVol != states[chn - 1].calculatedVol {
                        state.calculatedVol = states[chn - 1].calculatedVol
                        m.effect(MPT.channelVolume, state.calculatedVol)
                    }
                    if !event.isGlobal { continue }
                }

                var applyVolume = false
                switch event.command {
                case Command.keyOn:
                    if event.param > Volume.command {
                        switch event.param {
                        case Volume.stopSample:
                            m.volume(MPT.volPlayControl, 0)
                            state.stopped = true
                        case Volume.contSample:
                            m.volume(MPT.volPlayControl, 1)
                            state.stopped = false
                        case Volume.keyOff:
                            if m.note == 0 { m.note = state.lastNote }
                            m.volume(MPT.volOffset, 1)
                        case Volume.speedDown:
                            if patternSpeed > 1 {
                                patternSpeed -= 1
                                m.effect(MPT.speed, patternSpeed)
                            }
                        case Volume.speedUp:
                            if patternSpeed < 0xFF {
                                patternSpeed += 1
                                m.effect(MPT.speed, patternSpeed)
                            }
                        case Volume.setPitch:
                            state.lastNote = UInt8(bitPattern: note)
                            if mappedInst != state.lastInst { break }
                            m.note = UInt8(bitPattern: note)
                            m.effect(MPT.tonePortaDuration, 0)
                            state.curPitchSlide = 0
                            state.tonePortaRemain = 0
                            state.retrigVibrato = true
                            state.retrigTremolo = true
                        // Fine slides of up to half a semitone.
                        case Volume.pitchUp: m.effect(MPT.portaUp, 0xF2)
                        case Volume.pitchDown: m.effect(MPT.portaDown, 0xF2)
                        case Volume.pitchUp2: m.effect(MPT.portaUp, 0xF4)
                        case Volume.pitchDown2: m.effect(MPT.portaDown, 0xF4)
                        case Volume.pitchUp3: m.effect(MPT.portaUp, 0xF8)
                        case Volume.pitchDown3: m.effect(MPT.portaDown, 0xF8)
                        default: break
                        }
                    } else if event.note >= 0 || event.param < 100 {
                        if event.note >= 0 {
                            m.note = UInt8(bitPattern: note)
                            state.lastNote = m.note
                            m.instr = mappedInst
                            state.lastInst = mappedInst
                            state.curPitchSlide = 0
                            state.tonePortaRemain = 0
                            state.retrigVibrato = true
                            state.retrigTremolo = true
                        }
                        if event.param > 0 {
                            state.lastVol = roundedByte(Double(event.param) * 0.64)
                            if state.curVolSlide != 0 { applyVolume = true }
                            state.curVolSlide = 0
                        }
                    }
                    let newVol = mulDivRoundedUnsigned(state.lastVol, state.channelVol, 100)
                    if applyVolume || state.calculatedVol != newVol {
                        state.calculatedVol = newVol
                        m.effect(MPT.channelVolume, newVol)
                    }
                    // A stereo instrument's note is played on the next channel too, as its other side.
                    if event.note > 0, chn < channels - 1, chn % 2 == 0, instrument(origInst)?.channel == Side.stereoL {
                        var next = m
                        next.instr &+= 1
                        cells[at + 1] = next
                        states[chn + 1].lastVol = state.lastVol
                        states[chn + 1].curVolSlide = state.curVolSlide
                        states[chn + 1].curVolSlideAmt = state.curVolSlideAmt
                        states[chn + 1].curPitchSlide = state.curPitchSlide
                        states[chn + 1].curPitchSlideAmt = state.curPitchSlideAmt
                        states[chn + 1].retriggerRemain = state.retriggerRemain
                    }

                // Slides of volume. Symphonie's are fine and made as it mixes, and not at ticks or
                // rows: they are kept up with here, by the pattern's speed, and given as Impulse
                // Tracker's slides of the channel's volume where they come to a whole step.
                case Command.volSlideUp:
                    state.curVolSlideAmt = 0
                    state.curVolSlide = Float(event.param) * 0.0333
                case Command.volSlideDown:
                    state.curVolSlideAmt = 0
                    state.curVolSlide = Float(event.param) * -0.0333
                case Command.addVolume:
                    m.command = 0
                    converted.leftOut.addVolume += 1
                case Command.tremolo:
                    let speed = min(15, event.inst >> 3), depth = min(15, event.param >> 3)
                    state.curTremolo = speed << 4 | depth
                    if state.curTremolo != 0 { state.retrigTremolo = true } else { m.effect(MPT.tremolo, 0) }

                // Slides of pitch, likewise.
                case Command.pitchSlideUp:
                    state.curPitchSlideAmt = 0
                    state.curPitchSlide = Float(event.param) * 0.0333
                    state.tonePortaRemain = 0
                case Command.pitchSlideDown:
                    state.curPitchSlideAmt = 0
                    state.curPitchSlide = Float(event.param) * -0.0333
                    state.tonePortaRemain = 0
                case Command.pitchSlideTo:
                    if note >= 0, event.param > 0 {
                        let distance = abs((Int(note) - Int(state.lastNote)) * 32)
                        state.curPitchSlide = 0
                        m.note = UInt8(bitPattern: note)
                        state.lastNote = m.note
                        state.tonePortaAmt = UInt8(min(255, distance / (2 * Int(event.param))))
                        m.effect(MPT.tonePorta, state.tonePortaAmt)
                        state.tonePortaRemain = UInt16(truncatingIfNeeded: distance - min(distance, Int(state.tonePortaAmt) * (Int(patternSpeed) - 1)))
                    }
                case Command.addPitch:
                    m.command = 0
                    converted.leftOut.addPitch += 1
                case Command.vibrato:
                    let speed = min(15, event.inst >> 3), depth = min(15, event.param)
                    state.curVibrato = speed << 4 | depth
                    if state.curVibrato != 0 { state.retrigVibrato = true } else { m.effect(MPT.vibrato, 0) }
                case Command.addHalfTone:
                    m.note = UInt8(max(MPT.noteMin, min(MPT.noteMax, Int(state.lastNote &+ event.param))))
                    state.lastNote = m.note
                    m.effect(MPT.tonePortaDuration, 0)
                    state.tonePortaRemain = 0

                // The DSP: its filter and its echo, as macros.
                case Command.filter, Command.dspEcho, Command.dspDelay:
                    if event.command == Command.dspDelay { converted.leftOut.delay += 1 }
                    if event.command == Command.filter, UInt32(bitPattern: Int32(event.note)) % 5 >= 3 { converted.leftOut.filters += 1 }
                    if let index = macroMap.firstIndex(where: { $0.event == event }), macroMap[index].macro != 0 {
                        m.effect(MPT.midi, macroMap[index].macro)
                    } else if macroMap.count < 128 {
                        let param = macroMap.count
                        if let made = macro(event) {
                            converted.macros[param] = made
                            m.effect(MPT.midi, 0x80 | UInt8(param))
                            setMacro(event, 0x80 | UInt8(param))
                            if event.command == Command.dspEcho || event.command == Command.dspDelay { converted.useDSP = true }
                        }
                    } else if event.command != Command.dspDelay {
                        // (The macros have run out: the nearest of the same kind is used.)
                        var best: UInt8 = 0, bestDistance = UInt32.max
                        for entry in macroMap where entry.event.command == event.command && entry.event.note == event.note {
                            let d1 = UInt32(event.param) &- UInt32(entry.event.param), d2 = UInt32(event.inst) &- UInt32(entry.event.inst)
                            let distance = d1 &* d1 &+ d2 &* d2
                            if distance >= bestDistance { continue }
                            best = entry.macro
                            bestDistance = distance
                        }
                        setMacro(event, best)
                        if best != 0 { m.effect(MPT.midi, best) }
                    }

                // Other commands.
                case Command.retrig:
                    // The note struck every inst+1 ticks, param times, on as many rows as that takes.
                    if event.param < 1 { break }
                    m.effect(MPT.retrig, UInt8(min(15, Int(event.inst) + 1)))
                    state.retriggerRemain = UInt16(truncatingIfNeeded: Int(event.param) * (Int(event.inst) + 1))
                case Command.setSpeed:
                    patternSpeed = event.param != 0 ? event.param : 4
                    m.effect(MPT.speed, patternSpeed)
                case Command.emphasis:
                    m.command = 0
                    converted.leftOut.emphasis += 1
                case Command.cv:
                    if event.note == 0 || event.note == 4 {
                        let pan = event.note == 4 ? Int(event.inst) : 128
                        let vol = Int(min(event.param, 100))
                        let volL = UInt8(vol * min(128, 256 - pan) / 128), volR = UInt8(vol * min(128, pan) / 128)
                        if volL != state.channelVol {
                            state.channelVol = volL
                            state.calculatedVol = mulDivRoundedUnsigned(state.lastVol, state.channelVol, 100)
                            m.effect(MPT.channelVolume, state.calculatedVol)
                        }
                        if event.note == 4, chn < channels - 1, states[chn + 1].channelVol != volR {
                            states[chn + 1].channelVol = volR
                            state.calculatedVol = mulDivRoundedUnsigned(state.lastVol, state.channelVol, 100)
                            cells[at + 1].effect(MPT.channelVolume, state.calculatedVol)
                        }
                    } else {
                        converted.leftOut.cv += 1
                    }
                case Command.cvAdd:
                    m.command = 0
                case Command.setFromAdd:
                    state.fromAdd = event.param
                    state.sampleVibSpeed = 0
                    state.sampleVibDepth = 0
                case Command.fromAdd:
                    state.fromAdd &+= event.param
                case Command.sampleVib:
                    state.sampleVibSpeed = event.inst
                    state.sampleVibDepth = event.param

                // Where in the sample a note starts.
                case Command.fromAndPitch, Command.replayFrom:
                    if event.command == Command.fromAndPitch {
                        state.lastNote = UInt8(bitPattern: note)
                        m.instr = mappedInst
                        state.lastInst = mappedInst
                    }
                    m.note = state.lastNote
                    if note >= 0 {
                        m.instr = mappedInst
                        state.lastInst = mappedInst
                    }
                    if event.command == Command.replayFrom { m.volume(MPT.volTonePorta, 1) }
                    // (Not always: FROM AND PITCH with no offset is often a note that leaves the slides going.)
                    if event.param != 0 || state.fromAdd != 0 || state.sampleVibDepth != 0 {
                        var sampleVib = 0.0
                        if state.sampleVibDepth != 0 {
                            sampleVib = Double(state.sampleVibDepth) * (sin(Double(state.sampleVibPhase) * (Double.pi * 2.0 / 1024.0) + 1.5 * Double.pi) - 1.0) / 4.0
                        }
                        m.effect(MPT.offsetPercentage, roundedByte(Double(event.param) + Double(state.fromAdd) + sampleVib))
                    }
                    state.tonePortaRemain = 0
                default:
                    break
                }

                // A note brings back what a stopped sample has left off.
                if m.note != 0 {
                    state.stopped = false
                } else if state.stopped {
                    continue
                }

                if state.retriggerRemain != 0 {
                    state.retriggerRemain = max(state.retriggerRemain, UInt16(patternSpeed)) - UInt16(patternSpeed)
                    if m.command == 0 { m.effect(MPT.retrig, 0) }
                }

                let lessOne = Int(patternSpeed) - 1
                // The fine slides of volume.
                if state.curVolSlide != 0 {
                    state.curVolSlideAmt += state.curVolSlide * Float(patternSpeed)
                    if m.command == 0 {
                        if patternSpeed > 1, state.curVolSlideAmt >= Float(lessOne) {
                            let amount = min(15, roundedByte(state.curVolSlideAmt / Float(lessOne)))
                            state.curVolSlideAmt -= Float(Int(amount) * lessOne)
                            m.effect(MPT.channelVolSlide, amount << 4)
                        } else if state.curVolSlideAmt >= 1.0 {
                            let amount = min(15, roundedByte(state.curVolSlideAmt))
                            state.curVolSlideAmt -= Float(amount)
                            m.effect(MPT.channelVolSlide, amount << 4 | 0x0F)
                        } else if patternSpeed > 1, state.curVolSlideAmt <= Float(-lessOne) {
                            let amount = min(15, roundedByte(-state.curVolSlideAmt / Float(lessOne)))
                            state.curVolSlideAmt += Float(Int(amount) * lessOne)
                            m.effect(MPT.channelVolSlide, amount)
                        } else if state.curVolSlideAmt <= -1.0 {
                            let amount = min(14, roundedByte(-state.curVolSlideAmt))
                            state.curVolSlideAmt += Float(amount)
                            m.effect(MPT.channelVolSlide, amount | 0xF0)
                        }
                    }
                }
                // And of pitch, in the volume column where the command's place is taken.
                if state.curPitchSlide != 0 {
                    state.curPitchSlideAmt += state.curPitchSlide * Float(patternSpeed)
                    if m.command == 0 {
                        if patternSpeed > 1, state.curPitchSlideAmt >= Float(lessOne) {
                            let amount = min(0xDF, roundedByte(state.curPitchSlideAmt / Float(lessOne)))
                            state.curPitchSlideAmt -= Float(Int(amount) * lessOne)
                            m.effect(MPT.portaUp, amount)
                        } else if state.curPitchSlideAmt >= 1.0 {
                            let amount = min(15, roundedByte(state.curPitchSlideAmt))
                            state.curPitchSlideAmt -= Float(amount)
                            m.effect(MPT.portaUp, amount | 0xF0)
                        } else if patternSpeed > 1, state.curPitchSlideAmt <= Float(-lessOne) {
                            let amount = min(0xDF, roundedByte(-state.curPitchSlideAmt / Float(lessOne)))
                            state.curPitchSlideAmt += Float(Int(amount) * lessOne)
                            m.effect(MPT.portaDown, amount)
                        } else if state.curPitchSlideAmt <= -1.0 {
                            let amount = min(14, roundedByte(-state.curPitchSlideAmt))
                            state.curPitchSlideAmt += Float(amount)
                            m.effect(MPT.portaDown, amount | 0xF0)
                        }
                    } else if m.volcmd == 0 {
                        if patternSpeed > 1, state.curPitchSlideAmt / 4 >= Float(lessOne) {
                            let amount = min(9, roundedByte(state.curPitchSlideAmt / Float(lessOne)) / 4)
                            state.curPitchSlideAmt -= Float(Int(amount) * lessOne * 4)
                            m.volume(MPT.volPortaUp, amount)
                        } else if patternSpeed > 1, state.curPitchSlideAmt / 4 <= Float(-lessOne) {
                            let amount = min(9, roundedByte(-state.curPitchSlideAmt / Float(lessOne)) / 4)
                            state.curPitchSlideAmt += Float(Int(amount) * lessOne * 4)
                            m.volume(MPT.volPortaDown, amount)
                        }
                    }
                }
                // A vibrato and a tremolo, given again where a note has started them afresh.
                if m.command == 0, state.curVibrato != 0, state.retrigVibrato {
                    m.effect(MPT.vibrato, state.curVibrato)
                    state.retrigVibrato = false
                }
                if m.command == 0, state.curTremolo != 0, state.retrigTremolo {
                    m.effect(MPT.tremolo, state.curTremolo)
                    state.retrigTremolo = false
                }
                // A slide to a note, carried on until it gets there.
                if m.command != MPT.tonePorta, state.tonePortaRemain != 0 {
                    if m.command == 0 { m.command = MPT.tonePorta } else { m.volcmd = MPT.volTonePorta }
                    state.tonePortaRemain -= min(state.tonePortaRemain, UInt16(truncatingIfNeeded: Int(state.tonePortaAmt) * lessOne))
                }

                state.sampleVibPhase = UInt16((Int(state.sampleVibPhase) + Int(state.sampleVibSpeed) * Int(patternSpeed)) & 1023)

                // An instrument that is played on two channels at once has this channel's cell copied to the next.
                if chn % 2 == 0, state.lastInst != 0, let ins = instrument(Int(state.lastInst) - 1), ins.instFlags & InstFlag.syncPlay != 0 {
                    syncPlayCommand = m
                    applySyncPlay = true
                    if syncPlayCommand.instr != 0, ins.channel == Side.stereoL { syncPlayCommand.instr &+= 1 }
                }
            }
        }
    }

    /// The place's speed, put on the pattern's first row where there is room for it, or else on the
    /// first row after that has room; unless the row has a speed already.
    private static func writeSpeed(_ speed: UInt8, into cells: inout [MPTCell], rows: Int, channels: Int) {
        for row in 0 ..< rows {
            let base = row * channels
            if (0 ..< channels).contains(where: { cells[base + $0].command == MPT.speed }) { return }
            if let free = (0 ..< channels).first(where: { cells[base + $0].command == 0 }) {
                cells[base + free].effect(MPT.speed, speed)
                return
            }
        }
    }
}
