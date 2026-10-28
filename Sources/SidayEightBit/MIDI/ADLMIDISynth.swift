// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A Swift port of the General MIDI synthesiser of libADLMIDI 1.6.2.1 (src/adlmidi_midiplay.cpp and
// src/adlmidi_opl3.cpp), Copyright (c) 2010-2014 Joel Yliluoma (ADLMIDI) and (c) 2015-2026 Vitaly
// Novichkov, which is free software under the GNU General Public License, version 3 or any later
// version; and of its Windows 9x frequency and volume model and its brightness table
// (src/models/model_win9x.c and model_generic.c), (c) Vitaly Novichkov, under the MIT licence. This
// file is therefore under the GNU General Public License, version 3 or any later version, and so is
// siday as a whole when it is built with it (see THIRD-PARTY.md).
//
// Only what libADLMIDI does with the settings siday plays it with is ported: one OPL3, the bank's own
// four-operator and rhythm settings (none, for the bank siday has), no automatic arpeggio, binary
// panning, and the Windows 9x model. The names are the original's where they help a reader of both.

import SidayFoundation
import SidayMIDI

/// The two operators of a voice, as the chip's registers have them.
struct OPLTimbre: Equatable {
    /// Waveform, sustain and release, attack and decay, and the tremolo, vibrato, sustain, scaling and
    /// multiple bits: the registers E0, 80, 60 and 20, from the highest byte to the lowest.
    var modulatorE862: UInt32, carrierE862: UInt32
    /// Scaling by key and level: register 40.
    var modulator40: UInt8, carrier40: UInt8
    /// Feedback and connection: register C0.
    var feedconn: UInt8
    /// Semitones the voice is played above or below the note.
    var noteOffset: Int8
}

/// An instrument of a bank, as libADLMIDI keeps it.
struct OPLInstrument {
    static let pseudo4op: UInt8 = 0x01, noSound: UInt8 = 0x02, real4op: UInt8 = 0x04, fixedTone: UInt8 = 0x40
    static let rhythmMask: UInt8 = 0x38
    /// Its one timbre, or two (see `flags`), by their numbers in the bank (`OPLBank.timbres`).
    var timbres: (Int, Int)
    var drumTone: UInt8
    var flags: UInt8
    /// How many milliseconds it sounds while the key is down (40,000 for as long as it is), and after.
    var soundKeyOnMs: UInt16, soundKeyOffMs: UInt16
    var midiVelocityOffset: Int8
    var voice2FineTune: Double
}

/// A bank of instruments: 128 melodic ones by program, and 128 percussion ones by note.
struct OPLBank {
    /// Every timbre: first the one the chip's channels hold until they are given another, then the
    /// silent pair of the empty instrument, then the bank's.
    var timbres: [OPLTimbre]
    var melodic: [OPLInstrument]
    var percussion: [OPLInstrument]
    var deepTremolo: Bool, deepVibrato: Bool

    static let defaultTimbre = 0
    /// The instrument of no sound, whose timbres are the second and third.
    static let empty = OPLInstrument(timbres: (1, 2), drumTone: 0, flags: OPLInstrument.noSound, soundKeyOnMs: 0, soundKeyOffMs: 0,
                                     midiVelocityOffset: 0, voice2FineTune: 0)
}

/// libADLMIDI's synthesiser of General MIDI on the OPL3: it takes the messages of a song and plays
/// each note on one of the chip's channels, chosen as libADLMIDI chooses, with an instrument of its
/// bank, its pitch and loudness worked out by the driver it models.
final class ADLMIDISynth: MIDIReceiver {
    // MARK: The chip

    private static let channelsPerChip = 23, rhythmBase = 18
    private static let catRegular: UInt8 = 0, catRhythmSecondary: UInt8 = 8
    private static let panLeft: UInt8 = 0x10, panRight: UInt8 = 0x20, panBoth: UInt8 = 0x30

    /// Each channel's two operators' offsets: the nine of the first set, the nine of the second, and
    /// the five drums of the rhythm mode (0xFFF for none).
    private static let operatorsMap: [UInt16] = [
        0x000, 0x003, 0x001, 0x004, 0x002, 0x005,
        0x008, 0x00B, 0x009, 0x00C, 0x00A, 0x00D,
        0x010, 0x013, 0x011, 0x014, 0x012, 0x015,
        0x100, 0x103, 0x101, 0x104, 0x102, 0x105,
        0x108, 0x10B, 0x109, 0x10C, 0x10A, 0x10D,
        0x110, 0x113, 0x111, 0x114, 0x112, 0x115,
        0x010, 0x013, 0xFFF, 0x014, 0x012, 0xFFF, 0xFFF, 0x015, 0x011, 0xFFF,
    ]
    /// Each channel's offset for its pitch and key registers (A0, B0).
    private static let channelsMap: [UInt16] = [
        0x000, 0x001, 0x002, 0x003, 0x004, 0x005, 0x006, 0x007, 0x008,
        0x100, 0x101, 0x102, 0x103, 0x104, 0x105, 0x106, 0x107, 0x108,
        0x006, 0x007, 0x008, 0x008, 0x008,
    ]
    /// The same, for its panning (C0).
    private static let channelsMapPan: [UInt16] = [
        0x000, 0x001, 0x002, 0x003, 0x004, 0x005, 0x006, 0x007, 0x008,
        0x100, 0x101, 0x102, 0x103, 0x104, 0x105, 0x106, 0x107, 0x108,
        0x006, 0x007, 0x008, 0xFFF, 0xFFF,
    ]
    /// The same, for its feedback and connection (C0).
    private static let channelsMapFBConn: [UInt16] = [
        0x000, 0x001, 0x002, 0x003, 0x004, 0x005, 0x006, 0x007, 0x008,
        0x100, 0x101, 0x102, 0x103, 0x104, 0x105, 0x106, 0x107, 0x108,
        0x006, 0xFFF, 0xFFF, 0xFFF, 0xFFF,
    ]

    private let bank: OPLBank
    /// Where the registers are written: the card, or nowhere.
    private let card: OPLCard?
    /// Told of every register written, with the sample the card has reached: for comparing with
    /// libADLMIDI.
    private let registerLog: ((UInt16, UInt8) -> Void)?

    private let numChannels = channelsPerChip
    private var insCache: [Int]
    private var insCacheModified: [Bool]
    private var channelCategory: [UInt8]
    private var keyBlockFNumCache: [UInt8]
    private var regBD: UInt8 = 0
    private var regC0: [UInt8]
    private var masterVolume: UInt8 = 127
    private let deepTremolo: Bool, deepVibrato: Bool

    init(bank: OPLBank, card: OPLCard?, log: ((UInt16, UInt8) -> Void)? = nil) {
        self.bank = bank
        self.card = card
        registerLog = log
        deepTremolo = bank.deepTremolo
        deepVibrato = bank.deepVibrato
        insCache = Array(repeating: OPLBank.defaultTimbre, count: numChannels)
        insCacheModified = Array(repeating: false, count: numChannels)
        channelCategory = Array(repeating: 0, count: numChannels)
        keyBlockFNumCache = Array(repeating: 0, count: numChannels)
        regC0 = Array(repeating: Self.panBoth, count: numChannels)
        chipChannels = Array(repeating: ChipChannel(), count: numChannels)
        midiChannels = Array(repeating: MIDIChannel(), count: 16)
        // Loading a file resets the chip twice: once as the setup is applied, and again after the
        // file is read.
        chipReset()
        chipReset()
    }

    @inline(__always) private func writeReg(_ address: UInt16, _ value: UInt8) {
        registerLog?(address, value)
        card?.writeEither(Int(address), value)
    }

    private func chipReset() {
        silenceAll()
        insCache = Array(repeating: OPLBank.defaultTimbre, count: numChannels)
        insCacheModified = Array(repeating: false, count: numChannels)
        channelCategory = Array(repeating: 0, count: numChannels)
        keyBlockFNumCache = Array(repeating: 0, count: numChannels)
        regBD = 0
        regC0 = Array(repeating: Self.panBoth, count: numChannels)
        initChip()
        updateChannelCategories()
        silenceAll()
    }

    private func initChip() {
        // Every channel's junk cleared.
        for a in 0 ..< Self.rhythmBase {
            writeReg(0x20 + Self.operatorsMap[a * 2], 0x00)
            writeReg(0x20 + Self.operatorsMap[a * 2 + 1], 0x00)
            writeReg(0xA0 + Self.channelsMap[a], 0x00)
            writeReg(0xB0 + Self.channelsMap[a], 0x00)
        }
        // The timer pulsed, the OPL3 enabled, the waveforms and the OPL3's extensions on.
        let setup: [(UInt16, UInt8)] = [(0x004, 96), (0x004, 128), (0x105, 0), (0x105, 1), (0x105, 0), (0x001, 32), (0x105, 1), (0x008, 0)]
        for (register, value) in setup { writeReg(register, value) }
    }

    private func updateChannelCategories() {
        regBD = (deepTremolo ? 0x80 : 0) + (deepVibrato ? 0x40 : 0)
        writeReg(0x0BD, regBD)
        // No four-operator channels.
        writeReg(0x104, 0)
        for c in 0 ..< numChannels { channelCategory[c] = c < Self.rhythmBase ? Self.catRegular : Self.catRhythmSecondary }
    }

    private func silenceAll() {
        regBD = (deepTremolo ? 0x80 : 0) + (deepVibrato ? 0x40 : 0)
        writeReg(0x0BD, regBD)
        for c in 0 ..< numChannels {
            let o1 = Self.operatorsMap[c * 2], o2 = Self.operatorsMap[c * 2 + 1]
            chipNoteOff(c)
            if o1 != 0xFFF {
                writeReg(0x40 + o1, 0x3F)
                writeReg(0x80 + o1, 0xFF)
            }
            if o2 != 0xFFF {
                writeReg(0x40 + o2, 0x3F)
                // (As libADLMIDI: the first operator's register again.)
                writeReg(0x80 &+ o1, 0xFF)
            }
            insCacheModified[c] = true
        }
    }

    private func chipNoteOff(_ c: Int) {
        // (The rhythm mode is off: its channels have no key.)
        guard c < Self.rhythmBase else { return }
        writeReg(0xB0 + Self.channelsMap[c], keyBlockFNumCache[c] & 0xDF)
    }

    private func chipNoteOn(_ c1: Int, _ c2: Int, tone: Double) {
        let chan2 = c2 < numChannels ? c2 : 0
        let chn = Self.channelsMap[c1]
        let patch1 = bank.timbres[insCache[c1]], patch2 = bank.timbres[insCache[chan2]]
        let cacheModded = (insCacheModified[c1], insCacheModified[chan2])
        var (ftone, mulOffset) = Self.frequency(max(0, tone))
        if c1 < Self.rhythmBase {
            ftone |= 0x2000
            // Two operators: the channel is never the first of four here.
            let opAddr = [Self.operatorsMap[c1 * 2], Self.operatorsMap[c1 * 2 + 1]]
            let ops = [patch1.modulatorE862 & 0xFF, patch1.carrierE862 & 0xFF]
            _ = patch2
            for op in 0 ..< 2 {
                if opAddr[op] == 0xFFF { continue }
                if mulOffset > 0 {
                    let dt = ops[op] & 0xF0
                    var mul = ops[op] & 0x0F
                    if mul + mulOffset > 0x0F {
                        mulOffset = 0
                        mul = 0x0F
                    }
                    writeReg(0x20 + opAddr[op], UInt8(truncatingIfNeeded: dt | (mul + mulOffset)))
                    insCacheModified[c1] = true
                } else if cacheModded.0 {
                    writeReg(0x20 + opAddr[op], UInt8(truncatingIfNeeded: ops[op]))
                    insCacheModified[c1] = false
                }
            }
        }
        if chn != 0xFFF {
            writeReg(0xA0 + chn, UInt8(ftone & 0xFF))
            writeReg(0xB0 + chn, UInt8((ftone >> 8) & 0xFF))
            keyBlockFNumCache[c1] = UInt8((ftone >> 8) & 0xFF)
        }
    }

    /// The Windows 9x drivers' frequency: the note's block and F-number, with a multiple to add for a
    /// note too high for the highest block.
    static func frequency(_ tone: Double) -> (UInt32, UInt32) {
        let table: [UInt32] = [0xAB7, 0xB5A, 0xC07, 0xCBE, 0xD80, 0xE4D, 0xF27, 0x100E, 0x1102, 0x1205, 0x1318, 0x143A]
        var mulOffset: UInt32 = 0
        var note = UInt32(tone >= 12 ? tone - 12 : tone)
        var bendDec = tone - Double(Int32(tone))
        if bendDec > 0.5 {
            note += 1
            bendDec -= 1.0
        }
        var bend = Int32(bendDec * 4096) + 8192
        let bendMsb = (bend >> 7) & 0x7F, bendLsb = bend & 0x7F
        bend = (bendMsb << 9) | (bendLsb << 2)
        bend = Int32(Int16(truncatingIfNeeded: UInt16(truncatingIfNeeded: bend + 0x8000)))
        let octave = note / 12
        var freq = table[Int(note % 12)]
        if octave < 5 {
            freq >>= (5 - octave)
        } else if octave > 5 {
            freq <<= (octave - 5)
        }
        // The pitch bent, 31/256 of a step up and 27/256 down for each 2^15th.
        if bend > 0 {
            let diff = UInt32(bitPattern: (bend &* 31) >> 8)
            freq &+= (diff &* freq) >> 15
        } else if bend < 0 {
            let diff = UInt32(bitPattern: (-bend &* 27) >> 8)
            freq &-= (diff &* freq) >> 15
        }
        var pitched = freq &* 2
        var block: UInt32 = 1
        while pitched > 0x3FF {
            pitched /= 2
            block += 1
        }
        while block > 7 {
            mulOffset += 1
            block -= 1
        }
        return (pitched | (block << 10), mulOffset)
    }

    /// The Windows 9x Sound Blaster 16 driver's attenuation for a level of 0 to 127, by fours.
    private static let sb16Volume: [UInt32] = [
        80, 63, 40, 36, 32, 28, 23, 21,
        19, 17, 15, 14, 13, 12, 11, 10,
        9, 8, 7, 6, 5, 5, 4, 4,
        3, 3, 2, 2, 1, 1, 0, 0,
    ]

    /// The XG brightness (controller 74) as the modulator's level.
    private static let xgBrightness: [UInt8] = [
        0, 5, 8, 10, 11, 12, 14, 15, 16, 17,
        18, 18, 19, 20, 21, 22, 22, 23, 24, 24,
        25, 26, 26, 27, 27, 28, 28, 29, 30, 30,
        31, 31, 32, 32, 33, 33, 34, 34, 34, 35,
        35, 36, 36, 37, 37, 38, 38, 38, 39, 39,
        40, 40, 40, 41, 41, 42, 42, 42, 43, 43,
        43, 44, 44, 44, 45, 45, 46, 46, 46, 47,
        47, 47, 48, 48, 48, 49, 49, 49, 50, 50,
        50, 50, 51, 51, 51, 52, 52, 52, 53, 53,
        53, 54, 54, 54, 54, 55, 55, 55, 56, 56,
        56, 56, 57, 57, 57, 57, 58, 58, 58, 59,
        59, 59, 59, 60, 60, 60, 60, 61, 61, 61,
        61, 62, 62, 62, 62, 63, 63, 63,
    ]

    private func touchNote(_ c: Int, velocity: UInt32, channelVolume: UInt32, channelExpression: UInt32, brightness: UInt32 = 127, isDrum: Bool = false) {
        let adli = bank.timbres[insCache[c]]
        let o1 = Self.operatorsMap[c * 2], o2 = Self.operatorsMap[c * 2 + 1]
        let kslMod = adli.modulator40 & 0xC0, kslCar = adli.carrier40 & 0xC0
        var tlMod = UInt32(adli.modulator40 & 0x3F), tlCar = UInt32(adli.carrier40 & 0x3F)
        var voiceMode = 1
        if channelCategory[c] == Self.catRegular { voiceMode = Int(adli.feedconn & 1) }
        // (2-op FM: only the carrier is scaled; 2-op AM: both.)
        let doMod = voiceMode == 1, doCar = true

        // The Windows 9x Sound Blaster 16 driver's volume.
        let vel = velocity & 0x7F
        var volume = ((channelVolume & 0x7F) * (channelExpression & 0x7F) * UInt32(masterVolume & 0x7F)) / 16129
        volume = Self.sb16Volume[Int(volume >> 2)]
        if doCar { tlCar = min(0x3F, tlCar + volume + Self.sb16Volume[Int(vel >> 2)]) }
        if doMod { tlMod = min(0x3F, tlMod + volume + Self.sb16Volume[Int(vel >> 2)]) }

        if brightness != 127, !isDrum {
            let level = UInt32(Self.xgBrightness[Int(brightness & 0xFF)])
            if !doMod { tlMod = 63 - level + (level * tlMod) / 63 }
        }
        let modulator = kslMod | UInt8(tlMod & 63)
        let carrier = kslCar | UInt8(tlCar & 63)
        if o1 != 0xFFF { writeReg(0x40 + o1, modulator) }
        if o2 != 0xFFF { writeReg(0x40 + o2, carrier) }
    }

    private func setPatch(_ c: Int, _ timbre: Int) {
        if insCache[c] == timbre { return }
        insCache[c] = timbre
        insCacheModified[c] = false
        let o1 = Self.operatorsMap[c * 2], o2 = Self.operatorsMap[c * 2 + 1]
        let instrument = bank.timbres[timbre]
        var x = instrument.modulatorE862, y = instrument.carrierE862
        let data: [UInt16] = [0x20, 0x60, 0x80, 0xE0]
        for a in 0 ..< 4 {
            if o1 != 0xFFF { writeReg(data[a] + o1, UInt8(x & 0xFF)) }
            if o2 != 0xFFF { writeReg(data[a] + o2, UInt8(y & 0xFF)) }
            x >>= 8
            y >>= 8
        }
        var fbconn: UInt8 = 0
        var fbconnReg: UInt16 = 0
        if Self.channelsMapFBConn[c] != 0xFFF {
            fbconn |= instrument.feedconn
            fbconnReg = 0xC0 + Self.channelsMapFBConn[c]
        }
        if Self.channelsMapPan[c] != 0xFFF {
            fbconn |= regC0[c] & Self.panBoth
            if fbconnReg == 0 { fbconnReg = 0xC0 + Self.channelsMapPan[c] }
        }
        if fbconnReg != 0 { writeReg(fbconnReg, fbconn) }
    }

    private func setPan(_ c: Int, _ value: UInt8) {
        guard Self.channelsMapPan[c] != 0xFFF else { return }
        var panning: UInt8 = 0
        if value < 64 + 16 { panning |= Self.panLeft }
        if value >= 64 - 16 { panning |= Self.panRight }
        regC0[c] = panning
        writeReg(0xC0 + Self.channelsMapPan[c], bank.timbres[insCache[c]].feedconn | panning)
    }

    // MARK: The MIDI side

    /// One of the chip's voices of a note: the channel it is played on, and its timbre (a number of
    /// `OPLBank.timbres`, or -1 for none).
    struct Phys: Equatable {
        var chipChannel = 0
        var timbre = -1
        var pseudo4op = false

        static func == (a: Phys, b: Phys) -> Bool { a.timbre == b.timbre && a.pseudo4op == b.pseudo4op }
    }

    struct NoteInfo {
        var note: UInt8
        var vol: UInt8 = 0
        var vibrato: UInt8 = 0
        var noteTone: Int16 = 0
        var currentTone = 0.0
        var glideRate = Double.infinity
        var midiins = 0
        var isPercussion = false
        var isBlank = false
        var isOnExtendedLifeTime = false
        var ttl = 0.0
        var ains = OPLBank.empty
        var hasAins = false
        var chipChannels: [Phys] = []

        init(note: UInt8) { self.note = note }

        func physIndex(_ chipChannel: Int) -> Int? { chipChannels.firstIndex { $0.chipChannel == chipChannel } }
    }

    struct MIDIChannel {
        var defVolume: UInt8 = 100
        var defBendsenseLsb = 0, defBendsenseMsb = 2
        var bankLsb: UInt8 = 0, bankMsb: UInt8 = 0
        var patch: UInt8 = 0
        var volume: UInt8 = 100, expression: UInt8 = 127
        var panning: UInt8 = 64, vibrato: UInt8 = 0, aftertouch: UInt8 = 0
        var portamento: UInt16 = 0
        var sustain = false, softPedal = false, portamentoEnable = false
        var portamentoSource: Int8 = -1
        var portamentoRate = Double.infinity
        var noteAftertouch = [UInt8](repeating: 0, count: 128)
        var noteAfterTouchInUse = false
        var bend = 0
        var bendsense = 0.0
        var bendsenseLsb = 0, bendsenseMsb = 2
        var vibpos = 0.0, vibspeed = 0.0, vibdepth = 0.0
        var vibdelayUs: Int64 = 0
        var lastlrpn: UInt8 = 0, lastmrpn: UInt8 = 0
        var nrpn = false
        var brightness: UInt8 = 127
        var isXgPercussion = false
        var glidingNoteCount = 0, extendedNoteCount = 0
        var activenotes: [NoteInfo] = []

        init() { reset() }

        mutating func reset() {
            resetAllControllers()
            patch = 0
            vibpos = 0
            bankLsb = 0
            bankMsb = 0
            lastlrpn = 0
            lastmrpn = 0
            nrpn = false
            isXgPercussion = false
        }

        mutating func resetAllControllers() {
            volume = defVolume
            brightness = 127
            panning = 64
            resetAllControllers121()
        }

        mutating func resetAllControllers121() {
            bend = 0
            bendsenseMsb = defBendsenseMsb
            bendsenseLsb = defBendsenseLsb
            updateBendSensitivity()
            expression = 127
            sustain = false
            softPedal = false
            vibrato = 0
            aftertouch = 0
            for n in 0 ..< 128 { noteAftertouch[n] = 0 }
            noteAfterTouchInUse = false
            vibspeed = 2 * 3.141592653 * 5.0
            vibdepth = 0.5 / 127
            vibdelayUs = 0
            portamento = 0
            portamentoEnable = false
            portamentoSource = -1
            portamentoRate = .infinity
        }

        var hasVibrato: Bool { vibrato > 0 || aftertouch > 0 || noteAfterTouchInUse }

        mutating func updateBendSensitivity() {
            let cent = bendsenseMsb * 128 + bendsenseLsb
            bendsense = Double(cent) * (1.0 / (128 * 8192))
        }

        func findNote(_ note: UInt8) -> Int? { activenotes.firstIndex { $0.note == note } }

        mutating func cleanupNote(_ index: Int) {
            if activenotes[index].glideRate != .infinity { glidingNoteCount -= 1 }
            if activenotes[index].ttl > 0 { extendedNoteCount -= 1 }
        }

        /// Forgets every note's voice on a chip channel.
        mutating func clearAllPhysUsers(_ chipChannel: Int) {
            var index = 0
            while index < activenotes.count {
                if let p = activenotes[index].physIndex(chipChannel) {
                    activenotes[index].chipChannels.remove(at: p)
                    if activenotes[index].chipChannels.isEmpty {
                        activenotes.remove(at: index)
                        continue
                    }
                }
                index += 1
            }
        }
    }

    struct Location: Equatable {
        var midCh: Int
        var note: UInt8
    }

    struct LocationData {
        static let sustainPedal: UInt32 = 0x01, sustainSostenuto: UInt32 = 0x02, sustainAny: UInt32 = 0x03
        var loc: Location
        var sustained: UInt32 = 0
        var ins = Phys()
        var fixedSustain = false
        var konTimeUntilNeglibleUs: Int64 = 0
        var vibdelayUs: Int64 = 0
    }

    struct ChipChannel {
        var koffTimeUntilNeglibleUs: Int64 = 0
        var recentIns = Phys(chipChannel: 0, timbre: -1, pseudo4op: false)
        var users: [LocationData] = []

        func findUser(_ loc: Location) -> Int? { users.firstIndex { $0.loc == loc } }

        mutating func findOrCreateUser(_ loc: Location) -> Int? {
            if let found = findUser(loc) { return found }
            guard users.count < 128 else { return nil }
            users.append(LocationData(loc: loc))
            return users.count - 1
        }

        mutating func addAge(_ us: Int64) {
            let neg: Int64 = 1000 * -0x1FFF_FFFF
            if users.isEmpty {
                koffTimeUntilNeglibleUs = max(koffTimeUntilNeglibleUs - us, neg)
                if koffTimeUntilNeglibleUs < 0 { koffTimeUntilNeglibleUs = 0 }
            } else {
                koffTimeUntilNeglibleUs = 0
                for i in users.indices {
                    if !users[i].fixedSustain {
                        users[i].konTimeUntilNeglibleUs = max(users[i].konTimeUntilNeglibleUs - us, neg)
                    }
                    users[i].vibdelayUs += us
                }
            }
        }
    }

    static let updPatch = 0x1, updPan = 0x2, updVolume = 0x4, updPitch = 0x8, updAll = 0x2 + 0x4 + 0x8, updOff = 0x20, updMute = 0x40

    private static let modeGM = 0x01, modeGS = 0x02, modeXG = 0x04

    private var chipChannels: [ChipChannel]
    private(set) var midiChannels: [MIDIChannel]
    private var synthMode = modeXG

    /// Room for one more note on a channel, made if need be as libADLMIDI makes it: by forgetting
    /// a note that is not played, or one with no voice left, or else by ending the oldest.
    private func hasFreeActiveNotes(_ midCh: Int) -> Bool {
        guard midiChannels[midCh].activenotes.count >= 128 else { return true }
        if let blank = midiChannels[midCh].activenotes.firstIndex(where: { $0.isBlank }) {
            midiChannels[midCh].activenotes.remove(at: blank)
        } else if let empty = midiChannels[midCh].activenotes.firstIndex(where: { $0.chipChannels.isEmpty }) {
            midiChannels[midCh].activenotes.remove(at: empty)
        } else {
            noteUpdate(midCh, 0, Self.updOff)
        }
        return true
    }

    /// The MIDI channel whose note last took each of the chip's channels, for the voices a listener
    /// sees (see `MIDIFMRenderer`); -1 for none yet.
    private(set) var chipChannelOwner = [Int](repeating: -1, count: 18)
    /// The MIDI channels that have started a note since this was last cleared.
    var struckChannels: UInt32 = 0

    // MARK: Messages

    func songBegins() {
        realTimeResetState()
    }

    func receive(_ event: MIDIEvent) {
        let channel = Int(event.channel)
        switch event.kind {
        case .noteOff: realTimeNoteOff(channel, event.data1)
        case .noteOn: _ = realTimeNoteOn(channel, event.data1, event.data2)
        case .polyTouch: realTimeNoteAfterTouch(channel, event.data1, event.data2)
        case .controller: realTimeController(channel, event.data1, event.data2)
        case .program: midiChannels[channel].patch = event.data1
        case .channelTouch: midiChannels[channel].aftertouch = event.data1
        case .pitchBend:
            midiChannels[channel].bend = Int(event.data1) + Int(event.data2) * 128 - 8192
            noteUpdateAll(channel, Self.updPitch)
        case .systemExclusive: _ = realTimeSysEx(event.bytes)
        default: break
        }
    }

    private func realTimeResetState() {
        for ch in midiChannels.indices {
            midiChannels[ch].resetAllControllers()
            midiChannels[ch].vibpos = 0
            midiChannels[ch].lastlrpn = 0
            midiChannels[ch].lastmrpn = 0
            midiChannels[ch].nrpn = false
            if synthMode & Self.modeGS != 0 { midiChannels[ch].isXgPercussion = false }
            noteUpdateAll(ch, Self.updAll)
            noteUpdateAll(ch, Self.updOff)
        }
        masterVolume = 127
    }

    private func realTimeNoteOn(_ channel: Int, _ note: UInt8, _ velocity: UInt8) -> Bool {
        let note = min(note, 127)
        if velocity == 0 {
            noteOff(channel, note, forceNow: false)
            return false
        }
        let midiChan = midiChannels[channel]
        var midiins = Int(midiChan.patch)
        let isPercussion = channel % 16 == 9 || midiChan.isXgPercussion
        // (Every bank but the first falls back to it: the bank has no other.)
        if isPercussion { midiins = Int(note) }
        let ains = isPercussion ? bank.percussion[midiins] : bank.melodic[midiins]
        let velocity = UInt8(min(127, max(1, Int(velocity) + Int(ains.midiVelocityOffset))))
        var tone = Int32(note)
        if isPercussion || ains.flags & OPLInstrument.fixedTone != 0, ains.drumTone != 0 {
            tone = ains.drumTone >= 128 ? Int32(ains.drumTone) - 128 : Int32(ains.drumTone)
        }
        let is2op = ains.flags & (OPLInstrument.pseudo4op | OPLInstrument.real4op) == 0
        let pseudo4op = ains.flags & OPLInstrument.pseudo4op != 0
        var voices = [Phys(chipChannel: 0, timbre: ains.timbres.0, pseudo4op: false),
                      Phys(chipChannel: 0, timbre: is2op ? ains.timbres.0 : ains.timbres.1, pseudo4op: pseudo4op)]
        let isBlankNote = ains.flags & OPLInstrument.noSound != 0

        if isBlankNote {
            // Not played, but a note all the same.
            guard hasFreeActiveNotes(channel) else { return false }
            var dummy = NoteInfo(note: note)
            dummy.isBlank = true
            midiChannels[channel].activenotes.append(dummy)
            midiChannels[channel].portamentoSource = Int8(truncatingIfNeeded: note)
            return false
        }

        // The chip's channel for the note: the best by `calculateChipChannelGoodness`.
        var chipChannel = [-1, -1]
        for ccount in 0 ..< 2 {
            var c = -1
            var bs = Int32(-0x7FFF_FFFF)
            if ccount == 1 {
                if voices[0] == voices[1] { break }
                if chipChannel[0] == -1 { break }
            } else if is2op || pseudo4op, ains.flags & OPLInstrument.rhythmMask == 0 {
                if killSecondVoicesIfOverflow(&c) {
                    chipChannel[0] = c
                    chipChannel[1] = -1
                    voices[1] = voices[0]
                    break
                }
            }
            for a in 0 ..< numChannels {
                if ccount == 1, a == chipChannel[0] { continue }
                if is2op || pseudo4op {
                    if channelCategory[a] != Self.catRegular { continue }
                } else {
                    // (There are no four-operator channels.)
                    continue
                }
                let s = calculateChipChannelGoodness(a, voices[ccount])
                if s > Int64(bs) {
                    bs = Int32(truncatingIfNeeded: s)
                    c = a
                }
            }
            if c < 0 { continue }
            prepareChipChannelForNewNote(c, voices[ccount])
            chipChannel[ccount] = c
        }
        if chipChannel[0] < 0, chipChannel[1] < 0 { return false }

        var velocityPlayed = velocity
        if midiChannels[channel].softPedal { velocityPlayed = UInt8((Float(velocityPlayed) * 0.8).rounded(.down)) }
        guard hasFreeActiveNotes(channel) else { return false }

        var ni = NoteInfo(note: note)
        ni.vol = velocityPlayed
        ni.vibrato = midiChannels[channel].noteAftertouch[Int(note)]
        ni.noteTone = Int16(tone)
        ni.currentTone = Double(tone)
        ni.glideRate = .infinity
        ni.midiins = midiins
        ni.isPercussion = isPercussion
        ni.isBlank = false
        ni.ains = ains
        ni.hasAins = true

        let currentPortamentoSource = midiChannels[channel].portamentoSource
        let currentPortamentoRate = midiChannels[channel].portamentoRate
        let portamentoEnable = midiChannels[channel].portamentoEnable && currentPortamentoRate != .infinity && !isPercussion
        midiChannels[channel].portamentoSource = Int8(truncatingIfNeeded: note)
        if portamentoEnable, currentPortamentoSource >= 0 {
            ni.currentTone = Double(currentPortamentoSource)
            ni.glideRate = currentPortamentoRate
            midiChannels[channel].glidingNoteCount += 1
        }
        if isPercussion {
            // Drums sound for at least 30 ms.
            ni.ttl = 0.03
            midiChannels[channel].extendedNoteCount += 1
        }
        for ccount in 0 ..< 2 {
            let c = chipChannel[ccount]
            if c < 0 { continue }
            if let p = ni.physIndex(c) {
                ni.chipChannels[p].timbre = voices[ccount].timbre
                ni.chipChannels[p].pseudo4op = voices[ccount].pseudo4op
            } else if ni.chipChannels.count < 2 {
                ni.chipChannels.append(Phys(chipChannel: c, timbre: voices[ccount].timbre, pseudo4op: voices[ccount].pseudo4op))
            }
        }
        midiChannels[channel].activenotes.append(ni)
        noteUpdate(channel, midiChannels[channel].activenotes.count - 1, Self.updAll | Self.updPatch)
        for ccount in 0 ..< 2 {
            let c = chipChannel[ccount]
            if c < 0 { continue }
            chipChannels[c].recentIns = voices[ccount]
            chipChannels[c].addAge(0)
            if c < 18 { chipChannelOwner[c] = channel }
        }
        struckChannels |= 1 << UInt32(channel & 15)
        return true
    }

    private func realTimeNoteOff(_ channel: Int, _ note: UInt8) {
        noteOff(channel, note, forceNow: false)
    }

    private func realTimeNoteAfterTouch(_ channel: Int, _ note: UInt8, _ atVal: UInt8) {
        if let i = midiChannels[channel].findNote(note) { midiChannels[channel].activenotes[i].vibrato = atVal }
        let old = midiChannels[channel].noteAftertouch[Int(note % 128)]
        if atVal != old {
            midiChannels[channel].noteAftertouch[Int(note % 128)] = atVal
            var inUse = atVal != 0
            var n = 0
            while !inUse, n < 128 {
                inUse = midiChannels[channel].noteAftertouch[n] != 0
                n += 1
            }
            midiChannels[channel].noteAfterTouchInUse = inUse
        }
    }

    private func realTimeController(_ channel: Int, _ type: UInt8, _ value: UInt8) {
        let value = min(value, 127)
        switch type {
        case 1:
            midiChannels[channel].vibrato = value
        case 0:
            midiChannels[channel].bankMsb = value
            if synthMode & Self.modeGS == 0 { midiChannels[channel].isXgPercussion = Self.isXgPercChannel(midiChannels[channel].bankMsb) }
        case 32:
            midiChannels[channel].bankLsb = value
            if synthMode & Self.modeGS == 0 { midiChannels[channel].isXgPercussion = Self.isXgPercChannel(midiChannels[channel].bankMsb) }
        case 5:
            midiChannels[channel].portamento = (midiChannels[channel].portamento & 0x007F) | UInt16(value) << 7
            updatePortamento(channel)
        case 37:
            midiChannels[channel].portamento = (midiChannels[channel].portamento & 0x3F80) | UInt16(value)
            updatePortamento(channel)
        case 65:
            midiChannels[channel].portamentoEnable = value >= 64
            updatePortamento(channel)
        case 7:
            midiChannels[channel].volume = value
            noteUpdateAll(channel, Self.updVolume)
        case 74:
            midiChannels[channel].brightness = value
            noteUpdateAll(channel, Self.updVolume)
        case 64:
            midiChannels[channel].sustain = value >= 64
            if !midiChannels[channel].sustain { killSustainingNotes(channel, -1, LocationData.sustainPedal) }
        case 66:
            if value >= 64 {
                markSostenutoNotes(channel)
            } else {
                killSustainingNotes(channel, -1, LocationData.sustainSostenuto)
            }
        case 67:
            midiChannels[channel].softPedal = value >= 64
        case 11:
            midiChannels[channel].expression = value
            noteUpdateAll(channel, Self.updVolume)
        case 10:
            midiChannels[channel].panning = value
            noteUpdateAll(channel, Self.updPan)
        case 121:
            midiChannels[channel].resetAllControllers121()
            noteUpdateAll(channel, Self.updPan + Self.updVolume + Self.updPitch)
            killSustainingNotes(channel, -1, LocationData.sustainAny)
        case 120:
            noteUpdateAll(channel, Self.updOff + Self.updMute)
        case 123:
            noteUpdateAll(channel, Self.updOff)
        case 98:
            midiChannels[channel].lastlrpn = value
            midiChannels[channel].nrpn = true
        case 99:
            midiChannels[channel].lastmrpn = value
            midiChannels[channel].nrpn = true
        case 100:
            midiChannels[channel].lastlrpn = value
            midiChannels[channel].nrpn = false
        case 101:
            midiChannels[channel].lastmrpn = value
            midiChannels[channel].nrpn = false
        case 6:
            setRPN(channel, value, msb: true)
        case 38:
            setRPN(channel, value, msb: false)
        default:
            break
        }
    }

    private static func isXgPercChannel(_ msb: UInt8) -> Bool { msb == 0x7E || msb == 0x7F }

    private func realTimeSysEx(_ message: [UInt8]) -> Bool {
        let size = message.count
        guard size >= 4, message[0] == 0xF0, message[size - 1] == 0xF7 else { return false }
        let manufacturer = message[1], dev = message[2]
        let data = Array(message[3 ..< size - 1])
        switch manufacturer {
        case 0x7E, 0x7F: return doUniversalSysEx(dev, realtime: manufacturer == 0x7F, data)
        case 0x41: return doRolandSysEx(dev, data)
        case 0x43: return doYamahaSysEx(dev, data)
        default: return false
        }
    }

    private func doUniversalSysEx(_ dev: UInt8, realtime: Bool, _ data: [UInt8]) -> Bool {
        guard data.count >= 2, dev == 0x7F || dev == 0 else { return false }
        let address = Int(data[0] & 0x7F) << 8 | Int(data[1] & 0x7F)
        let rest = data[2...]
        switch (realtime ? 1 << 16 : 0) | address {
        case 0x0901:
            // General MIDI System On.
            synthMode = Self.modeGM
            realTimeResetState()
            return true
        case 0x0902:
            synthMode = Self.modeXG
            realTimeResetState()
            return true
        case 1 << 16 | 0x0401:
            // Master volume.
            guard rest.count == 2 else { return false }
            let volume = Int(rest[rest.startIndex] & 0x7F) | Int(rest[rest.startIndex + 1] & 0x7F) << 7
            masterVolume = UInt8(volume >> 7)
            for ch in midiChannels.indices { noteUpdateAll(ch, Self.updVolume) }
            return true
        default:
            return false
        }
    }

    private func doRolandSysEx(_ dev: UInt8, _ message: [UInt8]) -> Bool {
        guard message.count >= 6, dev == 0x7F || dev & 0x0F == 0 else { return false }
        let model = Int(message[0] & 0x7F), mode = message[1] & 0x7F
        let checksum = Int(message[message.count - 1] & 0x7F)
        var data = Array(message[2 ..< message.count - 1])
        var check = 0
        for byte in data { check += Int(byte & 0x7F) }
        check = (128 - (check & 127)) & 127
        guard check == checksum, data.count >= 3 else { return false }
        var address = Int(data[0] & 0x7F) << 16 | Int(data[1] & 0x7F) << 8 | Int(data[2] & 0x7F)
        var targetChannel = 0
        if address & 0xFFF0FF == 0x401015 {
            address = 0x401015
            targetChannel = Int(data[1] & 0x0F)
        }
        data.removeFirst(3)
        guard mode == 0x12 else { return false }
        switch model << 24 | address {
        case 0x42 << 24 | 0x00007F, 0x42 << 24 | 0x40007F:
            // System mode set, and the GS reset.
            guard data.count == 1, dev & 0xF0 == 0x10 else { return false }
            synthMode = Self.modeGS
            realTimeResetState()
            return true
        case 0x42 << 24 | 0x401015:
            // A part played as drums.
            guard data.count == 1, dev & 0xF0 == 0x10 else { return false }
            let channelsMap = [9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15]
            let value = data[0] & 0x7F
            midiChannels[channelsMap[targetChannel]].isXgPercussion = value == 0x01 || value == 0x02
            return true
        default:
            return false
        }
    }

    private func doYamahaSysEx(_ dev: UInt8, _ data: [UInt8]) -> Bool {
        guard data.count >= 1, dev == 0x7F || dev & 0x0F == 0 else { return false }
        let model = Int(data[0] & 0x7F)
        guard model == 0x4C, dev & 0xF0 == 0x10, data.count >= 4 else { return false }
        let address = Int(data[1] & 0x7F) << 16 | Int(data[2] & 0x7F) << 8 | Int(data[3] & 0x7F)
        guard address == 0x00007E, data.count == 5 else { return false }
        // XG System On.
        synthMode = Self.modeXG
        realTimeResetState()
        return true
    }

    // MARK: Notes

    private func noteUpdPatch(_ loc: Location, _ ins: Phys, _ ains: OPLInstrument) {
        setPatch(ins.chipChannel, ins.timbre)
        if let i = chipChannels[ins.chipChannel].findOrCreateUser(loc) {
            chipChannels[ins.chipChannel].users[i].sustained = 0
            chipChannels[ins.chipChannel].users[i].vibdelayUs = 0
            chipChannels[ins.chipChannel].users[i].fixedSustain = ains.soundKeyOnMs == 40000
            chipChannels[ins.chipChannel].users[i].konTimeUntilNeglibleUs = 1000 * Int64(ains.soundKeyOnMs)
            chipChannels[ins.chipChannel].users[i].ins = ins
        }
    }

    /// Ends one voice of a note: `phys` is its place in the note's voices, which it is taken out of.
    private func noteUpdOff(_ midCh: Int, _ noteIndex: Int, _ loc: Location, _ phys: Int, mute: Bool) {
        let ins = midiChannels[midCh].activenotes[noteIndex].chipChannels[phys]
        let c = ins.chipChannel
        if !midiChannels[midCh].sustain {
            let k = chipChannels[c].findUser(loc)
            let doEraseUser = k != nil && chipChannels[c].users[k!].sustained & LocationData.sustainSostenuto == 0
            if doEraseUser { chipChannels[c].users.remove(at: k!) }
            if doEraseUser, chipChannels[c].users.isEmpty {
                chipNoteOff(c)
                if mute {
                    touchNote(c, velocity: 0, channelVolume: 0, channelExpression: 0)
                    chipChannels[c].koffTimeUntilNeglibleUs = 0
                } else {
                    chipChannels[c].koffTimeUntilNeglibleUs = 1000 * Int64(midiChannels[midCh].activenotes[noteIndex].ains.soundKeyOffMs)
                }
            }
        } else {
            // Held by the pedal: forgotten, but not keyed off.
            if let d = chipChannels[c].findOrCreateUser(loc) { chipChannels[c].users[d].sustained |= LocationData.sustainPedal }
        }
        midiChannels[midCh].activenotes[noteIndex].chipChannels.remove(at: phys)
    }

    private func noteUpdVolume(_ midCh: Int, _ info: NoteInfo, _ ins: Phys) {
        let ch = midiChannels[midCh]
        let isPercussion = midCh == 9 || ch.isXgPercussion
        // As after a high-pass filter, which halves a sound at most.
        let brightness: UInt32 = ch.brightness >= 64 ? 127 : UInt32(ch.brightness) * 2
        touchNote(ins.chipChannel, velocity: UInt32(info.vol), channelVolume: UInt32(ch.volume), channelExpression: UInt32(ch.expression),
                  brightness: brightness, isDrum: isPercussion)
    }

    private func noteUpdFreq(_ midCh: Int, _ loc: Location, _ info: NoteInfo, _ ins: Phys) {
        let d = chipChannels[ins.chipChannel].findUser(loc)
        // A note held by a pedal is not bent.
        guard d == nil || chipChannels[ins.chipChannel].users[d!].sustained == 0 else { return }
        let chan = midiChannels[midCh]
        let midibend = Double(chan.bend) * chan.bendsense
        var bend = midibend + Double(bank.timbres[ins.timbre].noteOffset)
        var phase = 0.0
        var vibrato = max(chan.vibrato, chan.aftertouch)
        vibrato = max(vibrato, info.vibrato)
        if info.ains.flags & OPLInstrument.pseudo4op != 0, ins.pseudo4op { phase = info.ains.voice2FineTune }
        if vibrato != 0, d == nil || chipChannels[ins.chipChannel].users[d!].vibdelayUs >= chan.vibdelayUs {
            bend += Double(vibrato) * chan.vibdepth * sin(chan.vibpos)
        }
        let second = info.chipChannels.count > 1 ? info.chipChannels[1].chipChannel : 0
        chipNoteOn(ins.chipChannel, second, tone: info.currentTone + bend + phase)
    }

    /// Updates what `props` asks of a note's voices, on one chip channel or on all of them.
    func noteUpdate(_ midCh: Int, _ noteIndex: Int, _ props: Int, _ selectChipChannel: Int = -1) {
        var props = props
        let note = midiChannels[midCh].activenotes[noteIndex]
        let loc = Location(midCh: midCh, note: note.note)
        if note.isBlank {
            if props & Self.updOff != 0 { midiChannels[midCh].activenotes.remove(at: noteIndex) }
            return
        }
        if note.chipChannels.count > 1, !note.chipChannels[1].pseudo4op {
            for ins in note.chipChannels {
                if selectChipChannel >= 0, ins.chipChannel != selectChipChannel { continue }
                if props & Self.updPatch != 0 { noteUpdPatch(loc, ins, note.ains) }
            }
            props &= ~Self.updPatch
        }
        var ccount = 0
        while ccount < midiChannels[midCh].activenotes[noteIndex].chipChannels.count {
            let ins = midiChannels[midCh].activenotes[noteIndex].chipChannels[ccount]
            if selectChipChannel >= 0, ins.chipChannel != selectChipChannel {
                ccount += 1
                continue
            }
            if props & Self.updPatch != 0 { noteUpdPatch(loc, ins, note.ains) }
            if props & Self.updOff != 0 {
                noteUpdOff(midCh, noteIndex, loc, ccount, mute: props & Self.updMute != 0)
                continue
            }
            if props & Self.updPan != 0 { setPan(ins.chipChannel, midiChannels[midCh].panning) }
            if props & Self.updVolume != 0 { noteUpdVolume(midCh, midiChannels[midCh].activenotes[noteIndex], ins) }
            if props & Self.updPitch != 0 { noteUpdFreq(midCh, loc, midiChannels[midCh].activenotes[noteIndex], ins) }
            ccount += 1
        }
        if midiChannels[midCh].activenotes[noteIndex].chipChannels.isEmpty {
            midiChannels[midCh].cleanupNote(noteIndex)
            midiChannels[midCh].activenotes.remove(at: noteIndex)
        }
    }

    /// The same, for every note of a channel.
    private func noteUpdateAll(_ midCh: Int, _ props: Int) {
        // (A note that is ended is taken out of the list as it goes.)
        var index = 0
        while index < midiChannels[midCh].activenotes.count {
            let count = midiChannels[midCh].activenotes.count
            noteUpdate(midCh, index, props)
            if midiChannels[midCh].activenotes.count == count { index += 1 }
        }
    }

    private func calculateChipChannelGoodness(_ c: Int, _ ins: Phys) -> Int64 {
        let chan = chipChannels[c]
        let koffMs = chan.koffTimeUntilNeglibleUs / 1000
        var s = -koffMs
        // A channel whose note is dying away: the same instrument waits for it to be over.
        if s < 0, chan.users.isEmpty {
            let isSame = chan.recentIns == ins
            s -= 40000
            if isSame { s = -koffMs }
            return s
        }
        for jd in chan.users {
            let konMs = jd.konTimeUntilNeglibleUs / 1000
            s -= jd.sustained == 0 ? (4_000_000 + konMs) : (500_000 + konMs / 2)
            if let k = midiChannels[jd.loc.midCh].findNote(jd.loc.note) {
                let info = midiChannels[jd.loc.midCh].activenotes[k]
                if jd.ins == ins {
                    s += 300
                    if jd.vibdelayUs < 70000 || jd.konTimeUntilNeglibleUs > 20_000_000 { s += 10 }
                }
                s += info.isPercussion ? 50 : 0
            }
            var evacuationStations: Int64 = 0
            for c2 in 0 ..< numChannels where c2 != c && channelCategory[c2] == channelCategory[c] {
                for md in chipChannels[c2].users {
                    if md.sustained != 0 { continue }
                    if md.vibdelayUs >= 200_000 { continue }
                    if md.ins != jd.ins { continue }
                    evacuationStations += 1
                }
            }
            s += evacuationStations * 4
        }
        return s
    }

    private func killSecondVoicesIfOverflow(_ newChan: inout Int) -> Bool {
        var free2op = 0
        var volume = -1
        for a in 0 ..< numChannels where channelCategory[a] == Self.catRegular {
            let chan = chipChannels[a]
            if chan.users.isEmpty {
                free2op += 1
                break
            } else if chan.recentIns.pseudo4op {
                let jd = chan.users[0]
                let mc = midiChannels[jd.loc.midCh]
                var total = Int(mc.volume) + Int(mc.expression)
                if let nc = mc.findNote(jd.loc.note) { total += Int(mc.activenotes[nc].vol) }
                if volume < 0 || total < volume {
                    volume = total
                    newChan = a
                }
            }
        }
        if free2op == 0, newChan >= 0 {
            let jd = chipChannels[newChan].users[0]
            midiChannels[jd.loc.midCh].clearAllPhysUsers(newChan)
            chipChannels[newChan].users.remove(at: 0)
            chipNoteOff(newChan)
            return true
        }
        return false
    }

    private func prepareChipChannelForNewNote(_ c: Int, _ ins: Phys) {
        if chipChannels[c].users.isEmpty { return }
        // Every note on the channel is ended at once.
        for jd in chipChannels[c].users { midiChannels[jd.loc.midCh].clearAllPhysUsers(c) }
        chipChannels[c].users.removeAll()
        chipNoteOff(c)
    }

    private func killSustainingNotes(_ midCh: Int, _ thisChipChannel: Int, _ sustainType: UInt32) {
        let range = thisChipChannel >= 0 ? thisChipChannel ..< thisChipChannel + 1 : 0 ..< numChannels
        for c in range {
            if chipChannels[c].users.isEmpty { continue }
            var j = 0
            while j < chipChannels[c].users.count {
                let jd = chipChannels[c].users[j]
                if midCh < 0 || jd.loc.midCh == midCh, jd.sustained & sustainType != 0 {
                    chipChannels[c].users[j].sustained &= ~sustainType
                    if chipChannels[c].users[j].sustained == 0 {
                        chipChannels[c].users.remove(at: j)
                        continue
                    }
                }
                j += 1
            }
            if chipChannels[c].users.isEmpty { chipNoteOff(c) }
        }
    }

    private func markSostenutoNotes(_ midCh: Int) {
        for c in 0 ..< numChannels {
            for j in chipChannels[c].users.indices where chipChannels[c].users[j].loc.midCh == midCh && chipChannels[c].users[j].sustained == 0 {
                chipChannels[c].users[j].sustained |= LocationData.sustainSostenuto
            }
        }
    }

    private func setRPN(_ midCh: Int, _ value: UInt8, msb: Bool) {
        let nrpn = midiChannels[midCh].nrpn
        let addr = Int(midiChannels[midCh].lastmrpn) * 0x100 + Int(midiChannels[midCh].lastlrpn)
        switch addr + (nrpn ? 0x10000 : 0) + (msb ? 0x20000 : 0) {
        case 0x0000 + 0x20000:
            // The pitch bend's range, in semitones; and in cents.
            midiChannels[midCh].bendsenseMsb = Int(value)
            midiChannels[midCh].updateBendSensitivity()
        case 0x0000:
            midiChannels[midCh].bendsenseLsb = Int(value)
            midiChannels[midCh].updateBendSensitivity()
        case 0x0108 + 0x10000 + 0x20000:
            // XG's vibrato rate.
            if synthMode & Self.modeXG != 0 {
                if value == 64 {
                    midiChannels[midCh].vibspeed = 1.0
                } else if value < 100 {
                    midiChannels[midCh].vibspeed = 1.0 / (1.6e-2 * Double(value != 0 ? value : 1))
                } else {
                    midiChannels[midCh].vibspeed = 1.0 / (0.051153846 * Double(value) - 3.4965385)
                }
                midiChannels[midCh].vibspeed *= 2 * 3.141592653 * 5.0
            }
        case 0x0109 + 0x10000 + 0x20000:
            // Its depth.
            if synthMode & Self.modeXG != 0 { midiChannels[midCh].vibdepth = ((Double(Int(value) - 64)) * 0.15) * 0.01 }
        case 0x010A + 0x10000 + 0x20000:
            // Its delay, in milliseconds.
            if synthMode & Self.modeXG != 0 { midiChannels[midCh].vibdelayUs = value != 0 ? Int64(209.2 * exp(0.0795 * Double(value))) : 0 }
        default:
            break
        }
    }

    private func updatePortamento(_ midCh: Int) {
        var rate = Double.infinity
        let midival = midiChannels[midCh].portamento
        if midiChannels[midCh].portamentoEnable, midival > 0 {
            rate = 350.0 * pow(2.0, -0.062 * (1.0 / 128) * Double(midival))
        }
        midiChannels[midCh].portamentoRate = rate
    }

    private func noteOff(_ midCh: Int, _ note: UInt8, forceNow: Bool) {
        guard let i = midiChannels[midCh].findNote(note) else { return }
        if forceNow || midiChannels[midCh].activenotes[i].ttl <= 0 {
            noteUpdate(midCh, i, Self.updOff)
        } else {
            midiChannels[midCh].activenotes[i].isOnExtendedLifeTime = true
        }
    }

    // MARK: Time

    /// What happens as `s` seconds pass: notes age, drums that were ended too soon end, and vibrato
    /// and portamento move on.
    func tickIterators(_ s: Double) {
        for c in 0 ..< numChannels { chipChannels[c].addAge(Int64(s * 1e6)) }
        for c in midiChannels.indices where midiChannels[c].extendedNoteCount != 0 {
            var index = 0
            while index < midiChannels[c].activenotes.count {
                let count = midiChannels[c].activenotes.count
                var ttl = midiChannels[c].activenotes[index].ttl
                if ttl > 0 {
                    ttl -= s
                    midiChannels[c].activenotes[index].ttl = ttl
                    if ttl <= 0 {
                        midiChannels[c].extendedNoteCount -= 1
                        if midiChannels[c].activenotes[index].isOnExtendedLifeTime {
                            noteUpdate(c, index, Self.updOff)
                            if midiChannels[c].activenotes.count < count { continue }
                            midiChannels[c].activenotes[index].isOnExtendedLifeTime = false
                        }
                    }
                }
                index += 1
            }
        }
        updateVibrato(s)
        updateGlide(s)
    }

    private func updateVibrato(_ amount: Double) {
        for a in midiChannels.indices {
            if midiChannels[a].hasVibrato, !midiChannels[a].activenotes.isEmpty {
                noteUpdateAll(a, Self.updPitch)
                midiChannels[a].vibpos += amount * midiChannels[a].vibspeed
            } else {
                midiChannels[a].vibpos = 0.0
            }
        }
    }

    private func updateGlide(_ amount: Double) {
        for channel in midiChannels.indices where midiChannels[channel].glidingNoteCount != 0 {
            var index = 0
            while index < midiChannels[channel].activenotes.count {
                let info = midiChannels[channel].activenotes[index]
                let finalTone = Double(info.noteTone)
                let previousTone = info.currentTone
                let directionUp = previousTone < finalTone
                let toneIncr = amount * (directionUp ? info.glideRate : -info.glideRate)
                var currentTone = previousTone + toneIncr
                let glideFinished = !(directionUp ? currentTone < finalTone : currentTone > finalTone)
                currentTone = glideFinished ? finalTone : currentTone
                if Int64(currentTone * 1_000_000.0) != Int64(previousTone * 1_000_000.0) {
                    midiChannels[channel].activenotes[index].currentTone = currentTone
                    let count = midiChannels[channel].activenotes.count
                    noteUpdate(channel, index, Self.updPitch)
                    if midiChannels[channel].activenotes.count < count { continue }
                }
                index += 1
            }
        }
    }
}
