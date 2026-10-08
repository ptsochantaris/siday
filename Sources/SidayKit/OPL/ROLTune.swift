// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from AdPlug's rol.cpp, Copyright (C) 1999 - 2006 Simon Peter and others, by OPLx; used
// under the GNU Lesser General Public License, version 2.1 or later (see THIRD-PARTY.md).

/// A ROL file as it is read: a piano roll from AdLib's Visual Composer.
///
/// It has nine voices, or six and five drums. Each voice is four lists: its notes, one after
/// another with how long each lasts; and, each at a time of its own, the instruments it changes
/// to, its volumes, and its bends of pitch. Times are in ticks, so many to a beat.
///
/// Instruments are named and not described: the sounds are in a bank. See `AdLibBank`.
struct ROLFile {
    struct Note {
        /// Twelve to the octave, or nought for a rest.
        var number: Int16
        var duration: Int16
    }

    /// Something that happens at a time: a tempo, a volume or a bend of pitch, as a number to
    /// multiply by.
    struct Change {
        var time: Int16
        var value: Float
    }

    struct InstrumentChange {
        var time: Int16
        /// Which of the file's `instruments`.
        var instrument: Int
    }

    struct Voice {
        var notes: [Note] = []
        var instruments: [InstrumentChange] = []
        var volumes: [Change] = []
        var pitches: [Change] = []
    }

    var comment = ""
    var ticksPerBeat = 0
    /// Nought for the drums, and anything else for nine voices.
    var mode: UInt8 = 0
    var basicTempo: Float = 0
    var tempos: [Change] = []
    var voices: [Voice] = []
    var timeOfLastNote: Int16 = 0
    /// The names of the instruments the file asks for, in capitals, each once.
    var instruments: [[UInt8]] = []

    init(_ data: [UInt8]) throws {
        // The player this is ported from reads a file a byte at a time, and past the end of one
        // reads bytes of all ones: so a file cut short plays as far as it goes.
        var at = 0
        var failed = false
        func byte() -> UInt8 {
            defer { at += 1 }
            if at < data.count { return data[at] }
            failed = true
            return 0xFF
        }
        func word() -> UInt16 {
            let low = byte()
            return UInt16(low) | UInt16(byte()) << 8
        }
        func number() -> Float {
            let low = word()
            return Float(bitPattern: UInt32(low) | UInt32(word()) << 16)
        }
        func changes() -> [Change] {
            var list: [Change] = []
            for _ in 0 ..< word() {
                // (From here on there would be nothing but changes at a time that never comes.)
                if failed { break }
                let time = Int16(bitPattern: word())
                list.append(Change(time: time, value: number()))
            }
            return list
        }

        guard word() == 0, word() == 4 else { throw TuneError.malformed("not a ROL file") }
        var text: [UInt8] = []
        for _ in 0 ..< 40 { text.append(byte()) }
        text[39] = 0
        comment = ByteReader(text).cString(at: 0).0
        if comment == "\\roll\\default" { comment = "" }
        ticksPerBeat = Int(word())
        at += 2 + 2 + 2 + 1 // beats to the bar, and how the composer's screen was scaled
        mode = byte()
        at += 90 + 38 + 15
        basicTempo = number()
        tempos = changes()

        for _ in 0 ..< (mode != 0 ? 9 : 11) {
            var voice = Voice()

            at += 15
            let time_of_last_note = Int16(bitPattern: word())
            if time_of_last_note != 0 {
                var total_duration: Int16 = 0
                repeat {
                    let number = Int16(bitPattern: word())
                    let duration = Int16(bitPattern: word())
                    voice.notes.append(Note(number: number, duration: duration))
                    total_duration &+= duration
                } while total_duration < time_of_last_note && !failed
                if time_of_last_note > timeOfLastNote { timeOfLastNote = time_of_last_note }
            }

            at += 15
            for _ in 0 ..< word() {
                if failed { break }
                let time = Int16(bitPattern: word())
                var name: [UInt8] = []
                for _ in 0 ..< 9 { name.append(byte()) }
                at += 3
                name = AdLibBank.capitals(name)
                let known = instruments.firstIndex(of: name)
                if known == nil { instruments.append(name) }
                voice.instruments.append(InstrumentChange(time: time, instrument: known ?? instruments.count - 1))
            }

            at += 15
            voice.volumes = changes()
            at += 15
            voice.pitches = changes()

            voices.append(voice)
        }
    }
}

/// A ROL file being played, on AdLib's sound driver.
///
/// On each tick, each voice is given what its lists have for that tick: an instrument, a volume,
/// its next note when the one before has run its length, a bend of pitch. A change is looked for
/// only at its own tick, so one that comes out of order is never found, and holds up those behind it.
/// The names are the reference's.
final class ROLTune: OPLTune {
    private struct VoiceState {
        var noteEnd = false, pitchEnd = false, instrEnd = false, volumeEnd = false
        var mNoteDuration: Int16 = 0
        var current_note_duration: Int16 = 0
        var current_note: UInt16 = 0
        var next_instrument_event = 0
        var next_volume_event = 0
        var next_pitch_event = 0
        var mForceNote = true
    }

    private static let kMaxTickBeat = 60

    private let file: ROLFile
    /// The sound of each of the file's instruments, in the file's order.
    private let sounds: [AdLibInstrument]
    private let missing: Int
    private let driver: AdLibDriver
    private var voices: [VoiceState]
    private var mRefresh: Float = 18.2
    private var mNextTempoEvent = 0
    private var mCurrTick: Int16 = 0
    /// The part of a sample that ticks are over by.
    private var remainder = 0.0

    var detail: String {
        "AdLib Visual Composer, " + (driver.mRhythmMode ? "6 voices and drums" : "9 voices")
            + (missing == 0 ? "" : missing == 1 ? ", 1 instrument not found" : ", \(missing) instruments not found")
    }

    private init(_ file: ROLFile, sounds: [AdLibInstrument], missing: Int, card: OPLCard?) {
        self.file = file
        self.sounds = sounds
        self.missing = missing
        driver = AdLibDriver(card: card)
        voices = [VoiceState](repeating: VoiceState(), count: file.voices.count)

        // frontend_rewind
        driver.SetRhythmMode(file.mode ^ 1 != 0)
        SetRefresh(1.0)
    }

    /// A number with a fraction as C makes a whole one of it on the machine the reference player
    /// was built for, where one out of range is not an error: below nought is nought, too big is
    /// the biggest, and what does not fit the place it is going to loses its top.
    private static func whole(_ value: Float) -> UInt32 {
        if !(value > 0) { return 0 }
        return value >= 4_294_967_296.0 ? 0xFFFF_FFFF : UInt32(value)
    }

    /// One tick. False once the last note's time has come.
    private func update() -> Bool {
        if mNextTempoEvent < file.tempos.count, file.tempos[mNextTempoEvent].time == mCurrTick {
            SetRefresh(file.tempos[mNextTempoEvent].value)
            mNextTempoEvent += 1
        }

        for voice in 0 ..< voices.count { UpdateVoice(voice) }

        mCurrTick &+= 1
        return mCurrTick <= file.timeOfLastNote
    }

    /// The tempo, as ticks a second: the file's own, times what a tempo change says. A beat is
    /// played as sixty ticks at most, however many the file says it has.
    private func SetRefresh(_ multiplier: Float) {
        let tickBeat = Float(min(Self.kMaxTickBeat, file.ticksPerBeat))
        mRefresh = (tickBeat * file.basicTempo * multiplier) / 60.0
    }

    private func UpdateVoice(_ voice: Int) {
        let events = file.voices[voice]
        if events.notes.isEmpty || voices[voice].noteEnd { return }

        if !voices[voice].instrEnd {
            let next = voices[voice].next_instrument_event
            if next < events.instruments.count {
                if events.instruments[next].time == mCurrTick {
                    driver.SetInstrument(voice, sounds[events.instruments[next].instrument])
                    voices[voice].next_instrument_event += 1
                }
            } else {
                voices[voice].instrEnd = true
            }
        }

        if !voices[voice].volumeEnd {
            let next = voices[voice].next_volume_event
            if next < events.volumes.count {
                if events.volumes[next].time == mCurrTick {
                    let volume = UInt8(truncatingIfNeeded: Self.whole(Float(AdLibDriver.kMaxVolume) * events.volumes[next].value))
                    driver.SetVolume(voice, volume)
                    voices[voice].next_volume_event += 1
                }
            } else {
                voices[voice].volumeEnd = true
            }
        }

        if voices[voice].mForceNote || Int(voices[voice].current_note_duration) > Int(voices[voice].mNoteDuration) - 1 {
            if mCurrTick != 0 { voices[voice].current_note &+= 1 }

            if Int(voices[voice].current_note) < events.notes.count {
                let noteEvent = events.notes[Int(voices[voice].current_note)]

                driver.NoteOn(voice, Int(noteEvent.number))
                voices[voice].current_note_duration = 0
                voices[voice].mNoteDuration = noteEvent.duration
                voices[voice].mForceNote = false
            } else {
                driver.NoteOff(voice)
                voices[voice].noteEnd = true
                return
            }
        }

        if !voices[voice].pitchEnd {
            let next = voices[voice].next_pitch_event
            if next < events.pitches.count {
                if events.pitches[next].time == mCurrTick {
                    let variation = events.pitches[next].value
                    let pitchBend = variation == 1.0 ? UInt16(AdLibDriver.kMidPitch)
                        : UInt16(truncatingIfNeeded: Self.whole(Float(0x3FFF >> 1) * variation))
                    driver.ChangePitch(voice, pitchBend)
                    voices[voice].next_pitch_event += 1
                }
            } else {
                voices[voice].pitchEnd = true
            }
        }

        voices[voice].current_note_duration &+= 1
    }

    func tick() -> Int? {
        if !update() { return nil }
        // A tempo of nothing, or none that is a number, would be no tempo at all.
        var refresh = mRefresh
        if !(refresh > 0) { refresh = 18.2 }
        if refresh < 0.01 { refresh = 0.01 }
        remainder += OPL3Chip.rate / Double(refresh)
        let samples = Int(remainder)
        remainder -= Double(samples)
        return samples
    }

    /// A player for a ROL file.
    /// - Parameter banks: the banks that were found for it, the one to be asked first first. An
    ///   instrument that none of them has is looked for among those that come with the player, and
    ///   one found nowhere is silent.
    static func renderer(_ data: [UInt8], banks: [AdLibBank]) throws -> OPLRenderer<ROLTune> {
        let file = try ROLFile(data)
        var missing = 0
        let sounds = file.instruments.map { name -> AdLibInstrument in
            for bank in banks {
                if let found = bank.instrument(named: name) { return found }
            }
            if let found = BuiltInAdLibBank.instrument(named: name) { return found }
            missing += 1
            return AdLibInstrument()
        }
        var info = TuneInfo(format: "ROL")
        info.comment = file.comment
        let notFound = missing
        return OPLRenderer(info: info) { card in ROLTune(file, sounds: sounds, missing: notFound, card: card) }
    }
}
