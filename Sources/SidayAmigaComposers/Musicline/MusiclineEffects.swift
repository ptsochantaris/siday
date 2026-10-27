// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the Musicline Editor's replay routine, as UADE carries it
// (amigasrc/players/other/musicline_editor/mlineplayer102.asm): the effects it plays at every tick, and
// the waveforms its instruments make. The names given are that source's labels.

import SidayChips
import SidayFoundation

extension MusiclinePlayer {
    /// The player's tables of bytes, laid out as its data section has them, for the routines that read
    /// past one table into the next: the offsets into and the tables of `Phase`'s resizing (`SizerOffset256`
    /// to `SizerTable16`, made here as the player's makers make them), the volume tables of its eight
    /// voices (`VolumeTables`), the waves and the periods.
    struct DataSection {
        let bytes: [UInt8]
        let sizerOffsets: [Int: Int]
        let sizerTables: [Int: Int]
        let waves: Int

        init() {
            var bytes: [UInt8] = []
            var offsets: [Int: Int] = [:]
            var tables: [Int: Int] = [:]
            let sizes = [256, 128, 64, 32, 16]
            // (`SizerTableMaker.s`: for each size of a part of the waveform, from one byte up, the place in
            // the whole of each of its bytes; and the offsets of each size's in its table.)
            for size in sizes {
                offsets[size] = bytes.count
                var sum = 0
                for count in 0 ..< size - 1 {
                    sum += count
                    bytes += [UInt8(truncatingIfNeeded: sum >> 8), UInt8(truncatingIfNeeded: sum)]
                }
            }
            for size in sizes {
                tables[size] = bytes.count
                for count in 1 ..< size {
                    for k in 1 ... count { bytes.append(UInt8(truncatingIfNeeded: k * size / count - 1)) }
                }
            }
            // (`VolListMaker.s`: for each volume, each byte's value times it over 64 and halved.)
            for volume in 0 ... 64 {
                for k in 0 ..< 256 {
                    let value = k < 128 ? k : k - 256
                    bytes.append(UInt8(truncatingIfNeeded: value * volume / 64 / 2))
                }
            }
            waves = bytes.count
            bytes += MusiclineTables.waves.map { UInt8(bitPattern: $0) }
            for period in MusiclineTables.pitches { bytes += [UInt8(period >> 8), UInt8(period & 0xFF)] }
            self.bytes = bytes
            sizerOffsets = offsets
            sizerTables = tables
        }

        func byte(_ at: Int) -> UInt8 { at >= 0 && at < bytes.count ? bytes[at] : 0 }
        func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at + 1)) }
    }

    static let data = DataSection()

    // MARK: The effects at every tick

    /// `PlayEffects`: each voice's loop put back as its note left it, and unless it starts a note in this
    /// tick its slides, arpeggio, vibrato and tremolo; then its envelope, its loop through its sample and
    /// the waveforms it makes; and a voice whose loop moves through its sample told the loop's place and
    /// length.
    mutating func playEffects<Output: TFMXOutput>(_ output: inout Output) {
        for c in 0 ..< 4 {
            voices[c].wsRepPointer = voices[c].wsRepPtrOrg
            if voices[c].play & 1 == 0 {
                slideVolume(c)
                slideChannelVolume(c)
                slideMasterVolume(c)
                slideArpVolume(c)
                slideNote(c)
                slideArpNote(c)
                arpeggioPlay(c, &output)
                vibratoPlay(c)
                tremoloPlay(c)
            }
            adsrPlay(c)
            moveLoop(c, &output)
            transformPlay(c)
            phasePlay(c)
            mixPlay(c)
            resonancePlay(c)
            filterPlay(c)
            // The waveform made, copied to the voice's buffer of chip memory, from which Paula plays it: the
            // player does so when the machine has memory other than chip memory, where its voices' own
            // buffers may be, which Paula cannot read (UADE's has; an A500 of half a megabyte has not, and
            // Paula plays the same waveform from the voice's own buffers).
            let made = voices[c].wsRepPointer
            if made >= Self.buffer(c, 0), made <= Self.buffer(c, 4) {
                let copy = Self.waveBuffersAt + 256 * c
                voices[c].wsRepPointer = copy
                if voices[c].waveOrSample != 0 || voices[c].effects1 & Self.loop != 0 { voices[c].wsPointer = copy }
                let count = (Int((voices[c].wsRepLength >> 3) &- 1) + 1) * 16
                for k in 0 ..< min(count, 256) { setByte(copy + k, byte(made + k)) }
            }
            if voices[c].play & 1 == 0, voices[c].effects1 & Self.loop != 0 {
                let base = UInt16(0xA0 + 16 * c)
                paula32(base, UInt32(voices[c].wsRepPointer), &output)
                paula(base + 4, voices[c].looLength, &output)
                voices[c].wsRepLength = voices[c].looLength
            }
            if voices[c].arpWait == 0 { voices[c].partNote = 0 }
            voices[c].play &= 1
        }
    }

    /// `SlideVol`: the volume slid to a volume, up or down to the loudest or nought (the ProTracker
    /// slides not on the tick of their row).
    private mutating func slideVolume(_ c: Int) {
        let kind = voices[c].volSld
        var d2: UInt16
        if kind == Self.fxVolumeSlideToVol {
            guard voices[c].volSldToVolOff == 0 else { return }
            let to = voices[c].volSldToVol
            if voices[c].volSldType != 0 {
                d2 = voices[c].volume1 &- voices[c].volSldSpd
                if Int16(bitPattern: d2) < Int16(bitPattern: to) {
                    d2 = to
                    voices[c].volSldToVolOff = 1
                }
            } else {
                d2 = voices[c].volume1 &+ voices[c].volSldSpd
                if Int16(bitPattern: d2) > Int16(bitPattern: to) {
                    d2 = to
                    voices[c].volSldToVolOff = 1
                }
            }
        } else if kind == Self.fxVolumeSlideUp || (kind == Self.fxPTVolSlideUp && voices[c].play & 2 == 0) {
            d2 = voices[c].volume1 &+ voices[c].volSldSpd
            if Int16(bitPattern: d2) > 64 * 16 { d2 = 64 * 16 }
        } else if kind == Self.fxVolumeSlideDown || (kind == Self.fxPTVolSlideDown && voices[c].play & 2 == 0) {
            d2 = voices[c].volume1 &- voices[c].volSldSpd
            if d2 & 0x8000 != 0 { d2 = 0 }
        } else {
            return
        }
        voices[c].volume1 = d2
        voices[c].volume2 = d2
        voices[c].volume3 = d2
    }

    /// `SlideChannelVol`: the voice's channel volume slid.
    private mutating func slideChannelVolume(_ c: Int) {
        let kind = voices[c].cVolSld
        var d2: UInt16
        if kind == Self.fxChannelVolSlideToVol {
            guard voices[c].cVolSldToVolOff == 0 else { return }
            let to = voices[c].cVolSldToVol
            if voices[c].cVolSldType != 0 {
                d2 = voices[c].cVolume &- voices[c].cVolSldSpd
                if Int16(bitPattern: d2) < Int16(bitPattern: to) {
                    d2 = to
                    voices[c].cVolSldToVolOff = 1
                }
            } else {
                d2 = voices[c].cVolume &+ voices[c].cVolSldSpd
                if Int16(bitPattern: d2) > Int16(bitPattern: to) {
                    d2 = to
                    voices[c].cVolSldToVolOff = 1
                }
            }
        } else if kind == Self.fxChannelVolSlideUp {
            d2 = voices[c].cVolume &+ voices[c].cVolSldSpd
            if Int16(bitPattern: d2) > 64 * 16 { d2 = 64 * 16 }
        } else if kind == Self.fxChannelVolSlideDown {
            d2 = voices[c].cVolume &- voices[c].cVolSldSpd
            if d2 & 0x8000 != 0 { d2 = 0 }
        } else {
            return
        }
        voices[c].cVolume = d2
    }

    /// `SlideMasterVol`: the player's own volume slid, by the voice's slide.
    private mutating func slideMasterVolume(_ c: Int) {
        let kind = voices[c].mVolSld
        var d2: UInt16
        if kind == Self.fxMasterVolSlideToVol {
            guard voices[c].mVolSldToVolOff == 0 else { return }
            let to = voices[c].mVolSldToVol
            if voices[c].mVolSldType != 0 {
                d2 = masterVolume &- voices[c].mVolSldSpd
                if Int16(bitPattern: d2) < Int16(bitPattern: to) {
                    d2 = to
                    voices[c].mVolSldToVolOff = 1
                }
            } else {
                d2 = masterVolume &+ voices[c].mVolSldSpd
                if Int16(bitPattern: d2) > Int16(bitPattern: to) {
                    d2 = to
                    voices[c].mVolSldToVolOff = 1
                }
            }
        } else if kind == Self.fxMasterVolSlideUp {
            d2 = masterVolume &+ voices[c].mVolSldSpd
            if Int16(bitPattern: d2) > 64 * 16 { d2 = 64 * 16 }
        } else if kind == Self.fxMasterVolSlideDown {
            d2 = masterVolume &- voices[c].mVolSldSpd
            if d2 & 0x8000 != 0 { d2 = 0 }
        } else {
            return
        }
        masterVolume = d2
    }

    /// `SlideArpVol`: the volume slid by the arpeggio's row.
    private mutating func slideArpVolume(_ c: Int) {
        var d2: UInt16
        switch voices[c].arpVolSld {
        case 4:
            d2 = voices[c].volume1 &+ voices[c].arpVolSldSpd
            if Int16(bitPattern: d2) > 64 * 16 { d2 = 64 * 16 }
        case 5:
            d2 = voices[c].volume1 &- voices[c].arpVolSldSpd
            if d2 & 0x8000 != 0 { d2 = 0 }
        default:
            return
        }
        voices[c].volume1 = d2
        voices[c].volume2 = d2
        voices[c].volume3 = d2
    }

    /// `SlideNote`: the note slid towards the note it slides to, and stopped there; or the ProTracker
    /// slide (`PTSlideNote`), of the period, not on the tick of its row.
    private mutating func slideNote(_ c: Int) {
        let pt = voices[c].ptPchSld
        if pt != 0 {
            guard voices[c].play & 2 == 0, voices[c].ptPchSldToNote & 0x8000 == 0 else { return }
            let speed = pt == Self.fxPTPortamento ? voices[c].ptPchSldSpd2 : voices[c].ptPchSldSpd
            if voices[c].ptPchSldType != 0 {
                voices[c].ptPchSldNote &+= speed
                let now = periodOfNote(c, voices[c].note) &+ voices[c].ptPchSldNote
                if Int16(bitPattern: now) < Int16(bitPattern: voices[c].ptPchSldToNote) { return }
                voices[c].ptPchSldNote &-= now &- voices[c].ptPchSldToNote
            } else {
                voices[c].ptPchSldNote &-= speed
                let now = periodOfNote(c, voices[c].note) &+ voices[c].ptPchSldNote
                if Int16(bitPattern: now) > Int16(bitPattern: voices[c].ptPchSldToNote) { return }
                voices[c].ptPchSldNote &-= now &- voices[c].ptPchSldToNote
            }
            voices[c].ptPchSldToNote = 0xFFFF
            return
        }
        guard voices[c].pchSld != 0 || voices[c].instPchSld != 0, voices[c].pchSldToNote & 0x8000 == 0 else { return }
        let speed = voices[c].pchSldSpd
        if voices[c].pchSldType != 0 {
            voices[c].pchSldNote &-= speed
            let now = voices[c].note &+ voices[c].pchSldNote
            if Int16(bitPattern: now) > Int16(bitPattern: voices[c].pchSldToNote) { return }
            voices[c].pchSldNote &-= now &- voices[c].pchSldToNote
        } else {
            voices[c].pchSldNote &+= speed
            let now = voices[c].note &+ voices[c].pchSldNote
            if Int16(bitPattern: now) < Int16(bitPattern: voices[c].pchSldToNote) { return }
            voices[c].pchSldNote &-= now &- voices[c].pchSldToNote
        }
        voices[c].pchSldToNote = 0xFFFF
    }

    /// `SlideArpNote`: the arpeggio's slide.
    private mutating func slideArpNote(_ c: Int) {
        guard voices[c].arpPchSld != 0, voices[c].arpPchSldToNote & 0x8000 == 0 else { return }
        let speed = voices[c].arpPchSldSpd
        if voices[c].arpPchSldType != 0 {
            voices[c].arpPchSldNote &-= speed
            let now = voices[c].arpNote &+ voices[c].arpPchSldNote
            if Int16(bitPattern: now) > Int16(bitPattern: voices[c].arpPchSldToNote) { return }
            voices[c].arpPchSldNote &-= now &- voices[c].arpPchSldToNote
        } else {
            voices[c].arpPchSldNote &+= speed
            let now = voices[c].arpNote &+ voices[c].arpPchSldNote
            if Int16(bitPattern: now) < Int16(bitPattern: voices[c].arpPchSldToNote) { return }
            voices[c].arpPchSldNote &-= now &- voices[c].arpPchSldToNote
        }
        voices[c].arpPchSldToNote = 0xFFFF
    }

    /// `ArpeggioPlay`: every so many ticks (the instrument's arpeggio speed, and its groove every other
    /// time), the arpeggio's next row: its note, its sample, its effects, and a note started where it
    /// says to restart or play a sample.
    private mutating func arpeggioPlay<Output: TFMXOutput>(_ c: Int, _ output: inout Output) {
        guard voices[c].arp & 4 != 0 || voices[c].arp & 1 != 0 else { return }
        voices[c].arpSpdCnt &-= 1
        guard voices[c].arpSpdCnt == 0 else { return }
        guard let instrument = instruments[voices[c].instrument] else { return }
        var d0 = instrument.byte(Instrument.arpSpeed)
        voices[c].arpgGrv = ~voices[c].arpgGrv
        if voices[c].arpgGrv != 0, instrument.byte(Instrument.arpGroove) != 0 { d0 = instrument.byte(Instrument.arpGroove) }
        voices[c].arpSpdCnt = d0
        guard let rows = arpeggioRowsForPlay(c) else { return }
        // (Rows that jump round among themselves would hold the player for ever: siday's bound.)
        for _ in 0 ..< 256 {
            let place = voices[c].arpPos
            voices[c].arpPos = (voices[c].arpPos &+ 1) & 0x7F
            let row = 6 * Int(place)
            if voices[c].arpWait != 0, rows[row] == 0 { return }
            var note = rows[row]
            if note == 61 {
                voices[c].arp = 0
                voices[c].note = voices[c].arpNote
                return
            }
            if note == 62 {
                let target = rows[row + 1]
                if target != place { voices[c].arpPos = target }
                continue
            }
            let d1 = rows[row + 1]
            voices[c].wsNumber = d1 != 0 ? d1 : instrument.byte(Instrument.smplNumber)
            voices[c].restart = 0
            voices[c].arpPchSld = 0
            voices[c].arpVolSld = 0
            for k in 0 ..< 2 {
                let fx = rows[row + 2 + 2 * k]
                if fx <= 6 { arpEffect(c, fx, rows[row + 3 + 2 * k]) }
            }
            voices[c].arp &= ~0x20
            if note == 0 { return }
            if note & 0x80 != 0 {
                note = note &+ 61 &+ voices[c].arpgNote
            } else {
                voices[c].arp |= 0x20
            }
            let value = UInt16(bitPattern: Int16(Int8(bitPattern: note)) << 5)
            voices[c].arpNote = value
            voices[c].note = value
            voices[c].arpPchSldNote = 0
            if voices[c].arpWait & 1 != 0 {
                voices[c].arpWait &= ~1
                arpWaitStart(c, d1)
                playInst(c, &output)
                return
            }
            if voices[c].restart & 2 != 0 {
                voices[c].arp |= 2
                if d1 != 0 {
                    guard Int(d1) < samples.count, samples[Int(d1)] != nil else { return }
                    voices[c].wsSample = Int(d1)
                    voices[c].arp |= 8
                }
                playInst(c, &output)
                return
            }
            if d1 == 0 {
                voices[c].semiTone = instrument.word(Instrument.semiTone) << 5
                if voices[c].play & 4 == 0 { voices[c].fineTune = instrument.word(Instrument.fineTune) }
                return
            }
            // A sample of the arpeggio's row, started as it is.
            voices[c].play |= 1
            guard Int(d1) < samples.count, samples[Int(d1)] != nil else { return }
            let sample = sound(sample: Int(d1))
            voices[c].semiTone = sample.semiTone << 5
            if voices[c].play & 4 == 0 { voices[c].fineTune = sample.fineTune }
            voices[c].waveOrSample = sample.type
            var length: UInt16
            if sample.type != 0 {
                var size = instrument.byte(Instrument.smplType)
                if size == 0 { size = 3 }
                voices[c].waveOrSample = size
                fixWaveLength(c, sample.pointer, size, instrument)
                length = voices[c].wsRepLength
            } else {
                voices[c].wsPointer = sample.pointer
                voices[c].wsLength = sample.length
                var loop = sample.repPointer
                var loopLength = sample.repLength
                if loopLength == 0 {
                    loop = Self.zeroSample
                    loopLength = 1
                }
                voices[c].wsRepPointer = loop
                voices[c].wsRepPtrOrg = loop
                voices[c].wsRepLength = loopLength
                length = loopLength
            }
            voices[c].effects2 = sexitKeeps(length) ? instrument.byte(Instrument.effects2) : 0
            return
        }
    }

    /// The arpeggio `ArpeggioPlay` plays: as `PlayArpg`'s.
    private func arpeggioRowsForPlay(_ c: Int) -> [UInt8]? {
        guard let instrument = instruments[voices[c].instrument] else { return nil }
        var d0 = instrument.word(Instrument.arpTable)
        if voices[c].arp & 4 != 0 { d0 = d0 & 0xFF00 | UInt16(voices[c].arpTab) }
        let index = Int(Int16(bitPattern: d0 << 2)) >> 2
        guard index >= 0, index < arpeggios.count else { return nil }
        return arpeggios[index]
    }

    /// A byte of one of the waves of vibrato and tremolo (128 bytes each, from the sine), by the wave's
    /// number and the place: a number past the four reads the player's tables after them.
    private func waveByte(_ number: UInt8, _ place: UInt16) -> Int16 {
        Int16(Int8(bitPattern: Self.data.byte(Self.data.waves + Int(number) * 128 + Int(place))))
    }

    /// `VibratoPlay`: the row's vibrato, or the instrument's after its delay: its depth grown to its full
    /// over its attack, and the wave's value at the place it has come to, times the depth, as the note's
    /// change; or ProTracker's (`PTVibratoPlay`).
    private mutating func vibratoPlay(_ c: Int) {
        if voices[c].vib == Self.fxPTVibrato {
            guard voices[c].play & 2 == 0 else { return }
            let d2 = ptWave(voices[c].ptVibPos, voices[c].ptVibWave, voices[c].ptVibCmd, shift: 7)
            voices[c].ptVibNote = d2
            voices[c].ptVibPos &+= (voices[c].ptVibCmd >> 2) & 0x3C
            return
        }
        if voices[c].vib == 0 {
            guard voices[c].effects1 & Self.vibrato != 0 else { return }
            if voices[c].vibCmdDelay != 0 {
                voices[c].vibCmdDelay -= 1
                return
            }
        }
        if voices[c].vibAtkLength != 0 {
            voices[c].vibCmdDepth &+= voices[c].vibAtkSpeed
            voices[c].vibAtkLength &-= 1
            if voices[c].vibAtkLength == 0 { voices[c].vibCmdDepth = voices[c].vibDepth }
        } else {
            voices[c].vibCmdDepth = voices[c].vibDepth
        }
        let depth = Int32(voices[c].vibCmdDepth >> 8)
        var d3 = waveByte(voices[c].vibWaveNum, voices[c].vibCount >> 2)
        if voices[c].vibDir == 0 { d3 = 0 &- d3 }
        let product = (Int32(d3) * depth) >> 4
        var value = UInt16(truncatingIfNeeded: product)
        if product < 0 { value &+= 1 }
        voices[c].vibNote = value
        voices[c].vibCount = (voices[c].vibCount &+ voices[c].vibCmdSpeed) & 0x1FF
    }

    /// `TremoloPlay`: as the vibrato, of the volume; or ProTracker's (`PTTremoloPlay`).
    private mutating func tremoloPlay(_ c: Int) {
        var change: UInt16
        if voices[c].tre == Self.fxPTTremolo {
            guard voices[c].play & 2 == 0 else { return }
            change = ptWave(voices[c].ptTrePos, voices[c].ptTreWave, voices[c].ptTreCmd, shift: 2)
            voices[c].ptTrePos &+= (voices[c].ptTreCmd >> 2) & 0x3C
        } else {
            if voices[c].tre == 0 {
                guard voices[c].effects1 & Self.tremolo != 0 else { return }
                if voices[c].treCmdDelay != 0 {
                    voices[c].treCmdDelay -= 1
                    return
                }
            }
            if voices[c].treAtkLength != 0 {
                voices[c].treCmdDepth &+= voices[c].treAtkSpeed
                voices[c].treAtkLength &-= 1
                if voices[c].treAtkLength == 0 { voices[c].treCmdDepth = voices[c].treDepth }
            } else {
                voices[c].treCmdDepth = voices[c].treDepth
            }
            let depth = Int32(voices[c].treCmdDepth >> 8)
            var d3 = waveByte(voices[c].treWaveNum, voices[c].treCount >> 2)
            if voices[c].treDir == 0 { d3 = 0 &- d3 }
            let product = (Int32(d3) * depth) >> 1
            change = UInt16(truncatingIfNeeded: product)
            if product < 0 { change &+= 16 }
            voices[c].treCount = (voices[c].treCount &+ voices[c].treCmdSpeed) & 0x1FF
        }
        var d4 = voices[c].volume1
        if d4 != 0 {
            d4 &+= change
            if d4 & 0x8000 != 0 { d4 = 0 }
            if Int16(bitPattern: d4) > 64 * 16 { d4 = 64 * 16 }
        }
        voices[c].volume2 = d4
        voices[c].volume3 = d4
    }

    /// ProTracker's vibrato and tremolo (`PTVibratoPlay`, `PTTremoloPlay`): the sine's, ramp's or square's
    /// value at the place (its sign the place's), times the depth, shifted down.
    private func ptWave(_ position: UInt8, _ wave: UInt8, _ command: UInt8, shift: UInt16) -> UInt16 {
        let d0 = UInt8((position >> 2) & 0x1F)
        var d2: UInt16
        switch wave & 3 {
        case 0:
            d2 = UInt16(Self.ptVibratoTable[Int(d0)])
        case 1:
            let shifted = d0 << 3
            d2 = UInt16(position & 0x80 == 0 ? shifted : 255 &- shifted)
        default:
            d2 = 255
        }
        d2 = (d2 * UInt16(command & 15)) >> shift
        let negative = d2 & 0x8000 != 0
        if position & 0x80 == 0 {
            if negative { d2 = 0 &- d2 }
        } else if !negative {
            d2 = 0 &- d2
        }
        return d2
    }

    static let ptVibratoTable: [UInt8] = [0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
                                          255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24]

    /// `ADSRPlay`: the envelope: its attack, decay and sustain, each for its length, the volume moved by
    /// its speed, a 256th at a time, and at its end set to its volume; then its release, unless the
    /// sustain is held; and the voice's volume made that part of itself.
    private mutating func adsrPlay(_ c: Int) {
        guard voices[c].effects1 & Self.adsr != 0 else { return }
        var phase = -1
        var d1: UInt16 = 0
        for k in 0 ..< 3 where voices[c].adsrData[k] != 0 {
            phase = k
            break
        }
        if phase < 0 {
            if voices[c].effectsPar1 & Self.adsrHoldSustain != 0 {
                d1 = voices[c].adsrData[10]
            } else if voices[c].adsrData[3] != 0 {
                phase = 3
            } else {
                d1 = voices[c].adsrData[11]
            }
        }
        if phase >= 0 {
            voices[c].adsrVolume &+= voices[c].adsrData[4 + phase]
            d1 = voices[c].adsrVolume >> 8
            voices[c].adsrData[phase] &-= 1
            if voices[c].adsrData[phase] == 0 { d1 = voices[c].adsrData[8 + phase] }
        }
        voices[c].volume3 = UInt16(truncatingIfNeeded: (UInt32(d1) * UInt32(voices[c].volume2)) >> 6)
    }

    // MARK: The loop through the sample

    /// `MoveLoop`: a loop that moves through its sample, after its delay and every so many ticks: by its
    /// counter, going between its two places so many times, or at each note by its step; the loop's place
    /// set; and once its turns are done, for an instrument that says so, the loop stopped and the voice
    /// told to go on to silence.
    private mutating func moveLoop<Output: TFMXOutput>(_ c: Int, _ output: inout Output) {
        guard voices[c].effects1 & Self.loop != 0 else { return }
        let stepping = voices[c].effectsPar2 & Self.loopStep != 0
        var save = true
        var count = true
        if !stepping {
            voices[c].looDelay &-= 1
            if voices[c].looDelay & 0x8000 == 0 {
                // (`.exit2`)
                let at = voices[c].looWsPointer + 2 * Int(voices[c].looCounterSave)
                voices[c].wsRepPointer = at
                voices[c].wsRepPtrOrg = at
                return
            }
            voices[c].looDelay = 0
            if voices[c].looWait != 0 {
                voices[c].looWaitCounter &-= 1
                if voices[c].looWaitCounter & 0x8000 == 0 { return }
                voices[c].looWaitCounter = voices[c].looWait
            }
        } else if voices[c].effectsPar2 & Self.loopInit != 0 {
            save = voices[c].partNote != 0
        } else if voices[c].partNote == 0 {
            save = false
            count = false
        }
        if save { voices[c].looCounterSave = voices[c].looCounter }
        if count { loopCounter(c) }
        let d0 = voices[c].looCounterSave
        if stepping {
            voices[c].looDelay &-= 1
            if voices[c].looDelay & 0x8000 != 0 {
                voices[c].looDelay = 0
                var ready = true
                if voices[c].looWait != 0 {
                    voices[c].looWaitCounter &-= 1
                    if voices[c].looWaitCounter & 0x8000 == 0 {
                        ready = false
                    } else {
                        voices[c].looWaitCounter = voices[c].looWait
                    }
                }
                if ready {
                    var d3 = Int16(bitPattern: UInt16(truncatingIfNeeded: voices[c].looStep))
                    if d3 < 0 { d3 = 0 &- d3 }
                    let d1 = Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: voices[c].looSpd)))
                    let moved = Int32(bitPattern: UInt32(voices[c].looCounterSave) &+ UInt32(bitPattern: d1 * Int32(d3)))
                    if d1 < 0 {
                        voices[c].looCounterSave = moved >= 0 ? UInt16(truncatingIfNeeded: moved) : 0
                    } else {
                        let most = UInt32(voices[c].looWsCounterMax)
                        voices[c].looCounterSave = most > UInt32(bitPattern: moved) ? UInt16(truncatingIfNeeded: moved) : UInt16(most)
                    }
                }
            }
        }
        // (`.nostep`)
        let at = voices[c].looWsPointer + 2 * Int(d0)
        voices[c].wsRepPointer = at
        voices[c].wsRepPtrOrg = at
        if voices[c].looTurns & 0x8000 != 0, voices[c].effects1 & Self.loopStop != 0 {
            voices[c].effects1 &= ~Self.loop
            let base = UInt16(0xA0 + 16 * c)
            paula32(base, UInt32(Self.zeroSample), &output)
            paula(base + 4, 1, &output)
        }
    }

    /// `LoopCounter`: the loop's place moved by its step, between its two places, turned back at each, so
    /// many times.
    private mutating func loopCounter(_ c: Int) {
        guard voices[c].looTurns & 0x8000 == 0 else { return }
        var d0 = Int32(voices[c].looCounter)
        let step = Int32(bitPattern: voices[c].looStep)
        let repeatStart = Int32(voices[c].looRepeat), repeatEnd = Int32(voices[c].looRepEnd)
        d0 = d0 &+ step
        let ok: Bool = if voices[c].looRepeat < voices[c].looRepEnd {
            step < 0 ? d0 >= repeatStart : d0 <= repeatEnd
        } else {
            step < 0 ? d0 >= repeatEnd : d0 <= repeatStart
        }
        if !ok {
            if voices[c].looTurns != 0 {
                voices[c].looTurns -= 1
                if voices[c].looTurns == 0 { voices[c].looTurns = 0xFFFF }
            }
            d0 = d0 &- step
            voices[c].looStep = 0 &- voices[c].looStep
        }
        voices[c].looCounter = UInt16(truncatingIfNeeded: d0)
    }

    // MARK: Counters

    /// `Counter`: the counter moved by its speed between its two places, turned back at each, so many
    /// times; held while its delay lasts (unless it moves only at notes).
    private func counted(_ counter: inout Counter) {
        var d0 = counter.counter
        if counter.step == 0, counter.delay != 0 {
            counter.delay -= 1
            return
        }
        guard counter.turns & 0x8000 == 0 else { return }
        d0 &+= counter.speed
        let value = Int16(bitPattern: d0)
        let ok: Bool = if counter.repeatStart < counter.repeatEnd {
            counter.speed & 0x8000 != 0 ? value >= Int16(bitPattern: counter.repeatStart) : value <= Int16(bitPattern: counter.repeatEnd)
        } else {
            counter.speed & 0x8000 != 0 ? value >= Int16(bitPattern: counter.repeatEnd) : value <= Int16(bitPattern: counter.repeatStart)
        }
        if !ok {
            if counter.turns != 0 {
                counter.turns -= 1
                if counter.turns == 0 { counter.turns = 0xFFFF }
            }
            d0 &-= counter.speed
            counter.speed = 0 &- counter.speed
        }
        counter.counter = d0
    }

    /// `OneWayCounter`: the counter moved by its speed, round from 511 to nought.
    private func countedOneWay(_ counter: inout Counter) {
        if counter.step == 0, counter.delay != 0 {
            counter.delay -= 1
            return
        }
        counter.counter = (counter.counter &+ counter.speed) & 0x1FF
    }

    /// The counting each of the waveforms' effects begins with: its counter moved, and kept as it is at
    /// a note (or at every tick, for one that does not move only at notes); and for one that moves only
    /// at notes, after its delay, the kept place moved by its speed, between nought and 510. Returns the
    /// place kept before that move.
    private func counterPlace(_ counter: inout Counter, stepping: Bool, initial: Bool, note: Bool, speed: UInt16,
                              oneWay: Bool = false, phaseBounds: Bool = false) -> UInt16 {
        var save = true, count = true
        if stepping {
            if initial {
                save = note
            } else if !note {
                save = false
                count = false
            }
        }
        if save { counter.saved = counter.counter }
        if count {
            if oneWay { countedOneWay(&counter) } else { counted(&counter) }
        }
        let d0 = counter.saved
        if stepping {
            if counter.delay != 0 {
                counter.delay -= 1
            } else {
                let d1 = Int16(Int8(bitPattern: UInt8(truncatingIfNeeded: speed)))
                if phaseBounds {
                    // (Phase's: moved the other way, between 2 and 512.)
                    let moved = Int32(Int16(bitPattern: counter.saved)) - Int32(d1)
                    counter.saved = UInt16(truncatingIfNeeded: moved)
                    if d1 < 0 {
                        if Int16(bitPattern: counter.saved) > 512 { counter.saved = 512 }
                    } else if !(Int16(bitPattern: counter.saved) >= 2) {
                        counter.saved = 2
                    }
                } else {
                    let moved = Int32(Int16(bitPattern: counter.saved)) + Int32(d1)
                    counter.saved = UInt16(truncatingIfNeeded: moved)
                    if d1 >= 0 {
                        if Int16(bitPattern: counter.saved) > 510 { counter.saved = 510 }
                    } else if moved < 0 {
                        counter.saved = 0
                    }
                }
            }
        }
        return d0
    }

    // MARK: The waveforms made

    /// `TransformPlay`: the waveform made between two of the instrument's six (its own and five more),
    /// by the counter: each 256 of it a step from one to the next.
    private mutating func transformPlay(_ c: Int) {
        guard voices[c].effects2 & Self.transform != 0 else { return }
        let size = Int(voices[c].wsRepLength &* 2)
        let offset = switch size {
        case 256: 0
        case 128: 256
        case 64: 256 + 128
        case 32: 256 + 128 + 64
        default: 256 + 128 + 64 + 32
        }
        var counter = voices[c].tra
        let place = counterPlace(&counter, stepping: voices[c].effectsPar1 & Self.transformStep != 0,
                                 initial: voices[c].effectsPar1 & Self.transformInit != 0, note: voices[c].partNote != 0,
                                 speed: voices[c].traSpd)
        voices[c].tra = counter
        // (`SelectTraWave`: which two waveforms, and how far from the first to the second.)
        var d0 = Int16(bitPattern: place >> 1)
        var d3 = 0
        var d2 = d0
        for _ in 0 ..< 5 {
            d2 -= 256
            if d2 <= 0 { break }
            d3 += 1
            d0 = d2
        }
        let first = voices[c].traWsPtrs[d3]
        guard first != 0 else { return }
        var a1 = sound(sample: Int(first)).repPointer + offset
        if d3 == 0 { a1 = voices[c].wsRepPointer }
        // (The sixth's next is the byte after the six, the voice's `ch_PlayError`.)
        let second = d3 + 1 < 6 ? voices[c].traWsPtrs[d3 + 1] : voices[c].playError
        guard second != 0 else { return }
        var a0 = sound(sample: Int(second)).repPointer + offset
        var a2 = Self.buffer(c, 0)
        voices[c].wsRepPointer = a2
        if voices[c].effects1 & Self.loop != 0 || voices[c].waveOrSample != 0 { voices[c].wsPointer = a2 }
        for _ in 0 ..< (size == 0 ? 0x10000 : size) {
            let d1 = Int16(Int8(bitPattern: byte(a1)))
            let d2 = Int16(Int8(bitPattern: byte(a0))) &- d1
            let product = Int32(d2) * Int32(d0)
            let moved = Int16(truncatingIfNeeded: product) >> 8
            setByte(a2, UInt8(truncatingIfNeeded: d1 &+ moved))
            a1 += 1
            a0 += 1
            a2 += 1
        }
    }

    /// `PhasePlay`: the waveform squeezed into part of its length by the counter (the rest held at its
    /// last byte, or filled with the squeezed part again), and mixed with itself in one of three
    /// measures, or not.
    private mutating func phasePlay(_ c: Int) {
        guard voices[c].effects2 & Self.phase != 0 else { return }
        let d6 = Int16(bitPattern: voices[c].wsRepLength &* 2)
        var counter = voices[c].pha
        var d0 = counterPlace(&counter, stepping: voices[c].effectsPar1 & Self.phaseStep != 0,
                              initial: voices[c].effectsPar1 & Self.phaseInit != 0, note: voices[c].partNote != 0,
                              speed: voices[c].phaSpd, phaseBounds: true)
        voices[c].pha = counter
        let size: Int
        if d6 > 128 {
            d0 = (d0 &+ 1) >> 1
            size = 256
        } else if d6 > 64 {
            d0 = (d0 &+ 3) >> 2
            size = 128
        } else if d6 > 32 {
            d0 = (d0 &+ 7) >> 3
            size = 64
        } else if d6 > 16 {
            d0 = (d0 &+ 15) >> 4
            size = 32
        } else {
            d0 = (d0 &+ 31) >> 5
            size = 16
        }
        let a1 = voices[c].wsRepPointer
        var a2 = Self.buffer(c, 1)
        voices[c].wsRepPointer = a2
        if voices[c].effects1 & Self.loop != 0 || voices[c].waveOrSample != 0 { voices[c].wsPointer = a2 }
        let count = Int16(bitPattern: d0)
        if count >= d6 || count == 0 {
            // (`Phase_Mova`: the waveform as it is.)
            var from = a1
            for _ in 0 ..< Int(UInt16(bitPattern: d6 &- 1)) + 1 {
                setByte(a2, byte(from))
                a2 += 1
                from += 1
            }
            return
        }
        let d7 = Int(count) - 1
        var d1 = Int(d6) - Int(count)
        let data = Self.data
        var a3 = data.sizerTables[size]! + Int(data.word(data.sizerOffsets[size]! + 2 * (Int(count) - 1)))
        let start = a2
        let fill = voices[c].effectsPar1 & Self.phaseFill != 0
        func source(_ index: UInt8) -> Int16 { Int16(Int8(bitPattern: byte(a1 + Int(index)))) }
        func put(_ value: Int16) {
            setByte(a2, UInt8(truncatingIfNeeded: value))
            a2 += 1
        }
        var last: UInt8 = 0
        switch voices[c].phaType {
        case 3, 1, 2:
            // (`Phase_Low`, `Phase_High` and `Phase_Med`: each byte mixed with the waveform's byte at its own
            // place, three to one, one to three or evenly.)
            let type = voices[c].phaType
            func mixed(_ indexed: Int16, _ own: Int16) -> Int16 {
                switch type {
                case 1: (own &+ indexed &* 3) >> 2
                case 2: (indexed &+ own) >> 1
                default: (indexed &+ own &* 3) >> 2
                }
            }
            let tableStart = a3
            var a0 = a1
            for _ in 0 ... d7 {
                last = data.byte(a3)
                a3 += 1
                put(mixed(source(last), Int16(Int8(bitPattern: byte(a0)))))
                a0 += 1
            }
            if fill {
                guard d1 != 0 else { return }
                // (High's and Low's go on through the table from where they were, past its end into the
                // next; Med's begin it again each time.)
                a3 = tableStart
                repeat {
                    if type == 2 { a3 = tableStart }
                    var k = d7
                    while true {
                        let index = data.byte(a3)
                        a3 += 1
                        put(mixed(source(index), Int16(Int8(bitPattern: byte(a0)))))
                        a0 += 1
                        d1 -= 1
                        if d1 == 0 || k == 0 { break }
                        k -= 1
                    }
                } while d1 != 0
            } else {
                let held = source(last)
                for _ in 0 ..< d1 {
                    put(mixed(held, Int16(Int8(bitPattern: byte(a0)))))
                    a0 += 1
                }
            }
        default:
            // (`Phase_Quick`: the bytes at the table's places, and the rest held at the last of them, or
            // filled with what has been made so far.)
            for _ in 0 ... d7 {
                last = data.byte(a3)
                a3 += 1
                put(source(last))
            }
            if fill {
                var from = start
                for _ in 0 ..< d1 {
                    put(Int16(Int8(bitPattern: byte(from))))
                    from += 1
                }
            } else {
                let held = source(last)
                for _ in 0 ..< d1 { put(held) }
            }
        }
    }

    /// `MixPlay`: the waveform mixed with another (a sample's loop, the waveform itself, or what was mixed
    /// before), the other read from a place the counter moves through it, halved or not.
    private mutating func mixPlay(_ c: Int) {
        guard voices[c].effects2 & Self.mixing != 0 else { return }
        var d7 = Int16(bitPattern: voices[c].wsRepLength &* 2)
        var counter = voices[c].mix
        var d0 = counterPlace(&counter, stepping: voices[c].effectsPar2 & Self.mixStep != 0,
                              initial: voices[c].effectsPar2 & Self.mixInit != 0, note: voices[c].partNote != 0,
                              speed: voices[c].mixSpd, oneWay: voices[c].effectsPar2 & Self.mixCounter != 0)
        voices[c].mix = counter
        let d4: Int
        if d7 > 128 {
            d0 >>= 1
            d4 = 0
        } else if d7 > 64 {
            d0 >>= 2
            d4 = 256
        } else if d7 > 32 {
            d0 >>= 3
            d4 = 256 + 128
        } else if d7 > 16 {
            d0 >>= 4
            d4 = 256 + 128 + 64
        } else {
            d0 >>= 5
            d4 = 256 + 128 + 64 + 32
        }
        var a0 = voices[c].wsRepPointer
        var a1 = Self.buffer(c, 2)
        if voices[c].effectsPar2 & Self.mixBuff == 0 {
            a1 = a0
            let number = voices[c].mixWaveNum
            if number != 0 { a1 = sound(sample: Int(number)).repPointer + d4 }
        }
        let a3 = a1
        var a2 = Self.buffer(c, 2)
        voices[c].wsRepPointer = a2
        if voices[c].waveOrSample != 0 { voices[c].wsPointer = a2 }
        a1 += Int(Int16(bitPattern: d0))
        d7 = d7 &- Int16(bitPattern: d0) &- 1
        let shift: Int16 = voices[c].mixResFilBoost & 4 != 0 ? 0 : 1
        func mixing(_ count: Int) {
            for _ in 0 ..< count {
                let value = Int16(Int8(bitPattern: byte(a0))) &+ Int16(Int8(bitPattern: byte(a1)))
                setByte(a2, UInt8(truncatingIfNeeded: value >> shift))
                a0 += 1
                a1 += 1
                a2 += 1
            }
        }
        mixing(Int(UInt16(bitPattern: d7)) + 1)
        guard d0 != 0 else { return }
        a1 = a3
        mixing(Int(d0))
    }

    /// The voice's waveform as the resonance and filters read it: their source, the last byte of it, and
    /// the bytes there are of it less one.
    private func filterSource(_ c: Int) -> (at: Int, last: Int) {
        (voices[c].wsRepPointer, Int(UInt16(bitPattern: Int16(bitPattern: voices[c].wsRepLength &* 2) &- 1)))
    }

    /// `ResonancePlay`: the waveform through a resonant filter, its frequency set by the counter and its
    /// resonance by the instrument, in the 68000's integer arithmetic.
    private mutating func resonancePlay(_ c: Int) {
        guard voices[c].effects2 & Self.resonance != 0 else { return }
        var counter = voices[c].res
        let d0 = counterPlace(&counter, stepping: voices[c].effectsPar2 & Self.resonanceStep != 0,
                              initial: voices[c].effectsPar2 & Self.resonanceInit != 0, note: voices[c].partNote != 0,
                              speed: voices[c].resSpd)
        voices[c].res = counter
        var (a0, d7) = filterSource(c)
        var a1 = Self.buffer(c, 3)
        voices[c].wsRepPointer = a1
        if voices[c].effects1 & Self.loop != 0 || voices[c].waveOrSample != 0 { voices[c].wsPointer = a1 }
        var d4 = voices[c].resLastSample
        if voices[c].resLastInit != 0 {
            voices[c].resLastInit = 0
            d4 = UInt8(bitPattern: Int8(bitPattern: byte(a0 + d7)) >> 2)
        }
        var low = Int16(Int8(bitPattern: d4)) &<< 7
        let d5 = Int16(bitPattern: MusiclineTables.resonances[Int(d0 & 0xFFFE) / 2 & 0xFF])
        let d1 = MusiclineTables.resonanceAmplitudes[Int(voices[c].resAmp)]
        let damping = Int16(truncatingIfNeeded: (UInt32(0x8000 &- d1) * 0xE666) >> 16)
        var d3: Int16 = 0
        let shift: Int16 = voices[c].mixResFilBoost & 2 != 0 ? 6 : 7
        var d6: Int16 = 0
        if d7 < 0 { d7 += 0x10000 }
        for _ in 0 ... d7 {
            var input = Int16(Int8(bitPattern: byte(a0))) &<< 5
            a0 += 1
            input = input &- low
            let dividend = Int32(input) << 7
            // (`divs`: a quotient that does not fit a word leaves the dividend as it was, its low word used.)
            let quotient = d5 == 0 ? dividend : dividend / Int32(d5)
            let step = quotient >= -32768 && quotient <= 32767 ? Int16(quotient) : Int16(truncatingIfNeeded: dividend)
            d3 = d3 &+ step
            low = low &+ d3
            d6 = low >> shift
            setByte(a1, UInt8(truncatingIfNeeded: d6))
            a1 += 1
            d3 = Int16(truncatingIfNeeded: (Int32(d3) * Int32(damping) &* 2) >> 16)
        }
        voices[c].resLastSample = UInt8(truncatingIfNeeded: d6)
    }

    /// `FilterPlay`: the waveform through a low-pass filter (or with a resonance, for a filter of a type
    /// other than nought), its frequency set by the counter.
    private mutating func filterPlay(_ c: Int) {
        guard voices[c].effects2 & Self.filter != 0 else { return }
        var counter = voices[c].fil
        let d0 = counterPlace(&counter, stepping: voices[c].effectsPar1 & Self.filterStep != 0,
                              initial: voices[c].effectsPar1 & Self.filterInit != 0, note: voices[c].partNote != 0,
                              speed: voices[c].filSpd)
        voices[c].fil = counter
        var (a0, d7) = filterSource(c)
        var a1 = Self.buffer(c, 4)
        voices[c].wsRepPointer = a1
        if voices[c].effects1 & Self.loop != 0 || voices[c].waveOrSample != 0 { voices[c].wsPointer = a1 }
        var d4 = voices[c].filLastSample
        let resonant = voices[c].filType != 0
        if voices[c].filLastInit != 0 {
            voices[c].filLastInit = 0
            d4 = byte(a0 + d7)
            if resonant { d4 = UInt8(bitPattern: Int8(bitPattern: d4) >> 1) }
        }
        var low = Int16(Int8(bitPattern: d4)) &<< 7
        let table = resonant ? MusiclineTables.resonantFilters : MusiclineTables.filters
        let frequency = table[Int(d0 & 0xFFFE) / 2 & 0xFF]
        let d1 = Int16(bitPattern: frequency >> 1)
        let damping: Int16 = if resonant {
            Int16(truncatingIfNeeded: (UInt32(0x8000 &- frequency) * 0xE666) >> 16)
        } else {
            Int16(truncatingIfNeeded: (Int32(Int16(bitPattern: 0x8000 &- frequency)) * Int32(Int16(bitPattern: 0xF000))) >> 16)
        }
        var d3: Int16 = 0
        let shift: Int16 = voices[c].mixResFilBoost & 1 != 0 ? 6 : 7
        let inputShift: Int16 = resonant ? 6 : 7
        var d6: Int16 = 0
        if d7 < 0 { d7 += 0x10000 }
        for _ in 0 ... d7 {
            var input = Int16(Int8(bitPattern: byte(a0))) &<< inputShift
            a0 += 1
            input = input &- low
            let step = Int16(truncatingIfNeeded: (Int32(input) * Int32(d1) &* 4) >> 16)
            d3 = d3 &+ step
            low = low &+ d3
            d6 = low >> shift
            setByte(a1, UInt8(truncatingIfNeeded: d6))
            a1 += 1
            d3 = Int16(truncatingIfNeeded: (Int32(d3) * Int32(damping) &* 2) >> 16)
        }
        voices[c].filLastSample = UInt8(truncatingIfNeeded: d6)
    }
}
