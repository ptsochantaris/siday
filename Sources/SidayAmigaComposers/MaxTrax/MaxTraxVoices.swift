// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the MaxTrax Music Driver of Talin (David Joiner) and Joe Pearce (1991-93), whose source
// Joe Pearce released under the GNU Lesser General Public Licence 2.1 or later, as UADE carries it
// (amigasrc/players/other/max_trax: max.asm, shared.asm, driver.i). Its routines are named here as
// it names them, and the places in them by their labels.

import SidayChips

/// The driver's notes, channels and voices: what a note does when it begins and ends, how a voice is
/// chosen for it, its pitch and its envelope, and the MIDI controllers.
extension MaxTraxPlayer {
    // MARK: Notes

    /// `NoteOn` (max.asm): a note on channel `c`, at the volume the score gives it (nought being no note).
    /// On a channel in MONO mode the voice already playing it plays the note, gliding to it under
    /// portamento; otherwise a voice is chosen (`pick_voice`), whatever it was playing silenced, its
    /// pitch worked out and its sample's octave chosen (`CalcNote`), and its attack and sustain
    /// written to audio.device, at the voice's period and a volume of nought until its envelope
    /// begins (in this same tick, `EnvelopeManager`).
    mutating func noteOn<Output: TFMXOutput>(_ c: Int, note: UInt8, velocity: UInt8, priority: UInt8, _ output: inout Output) {
        guard velocity != 0 else { return }
        let patchIndex = channels[c].patch
        guard patch(patchIndex).sample >= 0 else { return }
        let velocityFlag = global.flags & Self.musicVelocity != 0
        var v: Int
        if channels[c].flags & Self.chanMono != 0, channels[c].voicesActive != 0 {
            // (`.l3`) The first voice that is playing the channel; none, and the note is not played.
            guard let found = (0 ..< 4).first(where: { voices[$0].channel == c }) else { return }
            v = found
            if !Self.negative8(voices[v].status &- Self.envSustain), channels[c].flags & Self.chanPortamento != 0 {
                // Under portamento, the voice glides from where it is to the note, from now.
                voices[v].portaTicks = 0
                if voices[v].flags & Self.voicePortamento != 0 { voices[v].baseNote = voices[v].endNote }
                voices[v].flags |= Self.voicePortamento
                voices[v].endNote = note
                channels[c].lastNote = note
                voices[v].noteVolume = velocityFlag ? UInt16(velocity &+ 1) : 128
                global.flags |= Self.musicAddedNote
                global.lastVoice = UInt8(v)
                return
            }
        } else {
            guard let picked = pickVoice(channels[c].flags & Self.chanPan != 0 ? 1 : 0, priority: priority) else { return }
            v = picked
        }

        // (`.l5`)
        if voices[v].channel >= 0 {
            killVoice(v, &output)
            voices[v].flags = Self.voiceStolen
        } else {
            voices[v].flags = 0
        }
        voices[v].channel = c
        voices[v].patch = patchIndex
        voices[v].baseNote = note
        let first = calcNote(v)
        voices[v].sample = first
        voices[v].priority = priority
        voices[v].status = Self.envStart
        // The note's volume: its own, if the file says to hear it, and the channel's (`.l23`).
        var noteVolume: UInt16 = velocityFlag ? UInt16(velocity &+ 1) : 128
        let channelVolume = channels[c].volume
        if !Self.negative8(channelVolume) { noteVolume = UInt16(truncatingIfNeeded: UInt32(noteVolume) * UInt32(channelVolume)) >> 7 }
        voices[v].noteVolume = noteVolume
        voices[v].baseVolume = 0

        let period = voices[v].lastPeriod != 0 ? voices[v].lastPeriod : 1000
        if let sample = sample(first) {
            // The attack, once (`ioa_Cycles` 1), with its period and a volume of nought (`ADIOF_PERVOL`);
            // then the sustain, for ever (`ioa_Cycles` 0), after it, or by itself with that period and
            // volume. audio.device writes Paula a write's place and length (in words, half its bytes) and
            // starts her, and the next write's as she begins the first.
            if sample.attack != 0 {
                setPeriodAndVolume(v, period: period, volume: 0)
                output.takeNextBuffer(v, start: sample.waveform, length: UInt16(truncatingIfNeeded: sample.attack >> 1))
                output.on(v)
            }
            if sample.sustain != 0 {
                if sample.attack == 0 { setPeriodAndVolume(v, period: period, volume: 0) }
                output.takeNextBuffer(v, start: sample.waveform + sample.attack, length: UInt16(truncatingIfNeeded: sample.sustain >> 1))
                if sample.attack == 0 { output.on(v) }
            } else if sample.attack != 0 {
                // With nothing written after the attack, audio.device stops the voice once it has played.
                output.takeNextBuffer(v, start: silenceAt, length: 1)
            }
        }
        channels[c].voicesActive &+= 1

        // In MONO mode under portamento, from the channel's last note to this one (`.l14`).
        if channels[c].flags & Self.chanMono != 0, channels[c].flags & Self.chanPortamento != 0 {
            let last = channels[c].lastNote
            if !Self.negative8(last), last != voices[v].baseNote {
                voices[v].portaTicks = 0
                voices[v].endNote = voices[v].baseNote
                voices[v].baseNote = last
                voices[v].flags |= Self.voicePortamento
            }
        }
        if channels[c].flags & Self.chanPortamento != 0 { channels[c].lastNote = note }
        global.flags |= Self.musicAddedNote
        global.lastVoice = UInt8(v)
    }

    /// `NoteOff`: the note on the voice the driver is looking at (`glob_LastVoice`) ends, if it is still
    /// that note on that channel and has not already begun to: it is released, or held for the damper
    /// pedal.
    mutating func noteOff(_ c: Int, note: UInt8) {
        guard channels[c].voicesActive != 0 else { return }
        let v = Int(global.lastVoice & 3)
        guard voices[v].channel == c, voices[v].status > Self.envRelease else { return }
        let playing = voices[v].flags & Self.voicePortamento != 0 ? voices[v].endNote : voices[v].baseNote
        guard note == playing else { return }
        if channels[c].flags & Self.chanDamper != 0 {
            voices[v].flags |= Self.voiceDamper
        } else {
            voices[v].status = Self.envRelease
        }
    }

    /// `AllNotesOff`: every voice of the channel released (or held for the damper pedal).
    mutating func allNotesOff(_ c: Int) {
        guard channels[c].voicesActive != 0 else { return }
        for v in 0 ..< 4 where voices[v].channel == c {
            if channels[c].flags & Self.chanDamper != 0 {
                voices[v].flags |= Self.voiceDamper
            } else {
                voices[v].status = Self.envRelease
            }
        }
    }

    /// `AllSoundsOff`: every voice of the channel silenced at once.
    mutating func allSoundsOff<Output: TFMXOutput>(_ c: Int, _ output: inout Output) {
        guard channels[c].voicesActive != 0 else { return }
        for v in 0 ..< 4 where voices[v].channel == c { killVoice(v, &output) }
    }

    /// `KillVoice` (shared.asm): the voice freed, and silenced (`stop_audio`): audio.device told to
    /// forget what it was writing (`CMD_FLUSH`), and, as the driver does for an audio.device older than
    /// version 37 (Kickstart 1.3's), Paula's period set to 1 and her volume to nought, which nothing
    /// hears, the voice being stopped.
    mutating func killVoice<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let c = voices[v].channel
        if c >= 0 { channels[c].voicesActive &-= 1 }
        voices[v].channel = -1
        voices[v].status = Self.envFree
        voices[v].flags = 0
        voices[v].priority = 0
        output.off(v)
        setPeriodAndVolume(v, period: 1, volume: 0)
    }

    /// `SystemReset`: every voice silenced, and every channel reset, out of MONO mode, with no last note.
    mutating func systemReset<Output: TFMXOutput>(_ output: inout Output) {
        for v in 0 ..< 4 where voices[v].channel >= 0 { killVoice(v, &output) }
        for c in 0 ..< 16 {
            resetChannel(c)
            channels[c].flags &= ~Self.chanMono
            channels[c].lastNote = 0xFF
        }
    }

    /// `ResetChannel` (shared.asm), for MIDI's Reset All Controllers: portamento of half a second, no
    /// bend and a range of 24 semitones, full volume, the odd channels to the right, no portamento.
    mutating func resetChannel(_ c: Int) {
        channels[c].portamentoTime = 500
        channels[c].pitchBend = 64 << 7
        channels[c].realBend = 0
        channels[c].pitchBendRange = 24
        channels[c].volume = 128
        if channels[c].number & 1 != 0 {
            channels[c].flags |= Self.chanPan
        } else {
            channels[c].flags &= ~Self.chanPan
        }
        channels[c].flags &= ~(Self.chanPortamento | Self.chanMicrotonal)
        channels[c].flags |= Self.chanAltered
    }

    // MARK: Choosing a voice

    /// `pick_voice` (shared.asm): a voice for a note to start on the side `start` (nought for the left,
    /// one for the right) asks for: the other side if this one's two are both busier than a release
    /// and the other has one that is not; then between the side's two (`pick_voice1`); then, if that
    /// one is kept for a sound or plays at a higher priority, the other of the two, then the other
    /// side's. Nil if none will do.
    mutating func pickVoice(_ start: Int, priority: UInt8) -> Int? {
        let wanted = priority & ~0x08
        var pick = start & 3
        if priority & 0x08 == 0 {
            let near = min(Int8(bitPattern: voices[pick].status), Int8(bitPattern: voices[pick ^ 3].status))
            let far = min(Int8(bitPattern: voices[pick ^ 1].status), Int8(bitPattern: voices[pick ^ 1 ^ 3].status))
            if near > Int8(Self.envRelease), far <= Int8(Self.envRelease) { pick ^= 1 }
        }
        func usable(_ v: Int) -> Bool {
            voices[v].flags & Self.voiceBlocked == 0 && !Self.negative8(wanted &- voices[v].priority)
        }
        var round = pickBetween(&pick)
        var found = usable(pick)
        if !found {
            pick ^= 3
            found = usable(pick)
        }
        if !found {
            pick ^= 1
            round = pickBetween(&pick)
            found = usable(pick)
            if !found {
                pick ^= 3
                found = usable(pick)
            }
        }
        guard found else { return nil }
        rounds[round] = UInt8(pick & 2)
        return pick
    }

    /// `pick_voice1`: of the two voices on a side, the one in the earlier state of its note (free before
    /// halting before releasing, and so on); of two alike, not the one picked last on that side
    /// (`right_round`, `left_round`). Returns which side's bounce byte it used.
    private func pickBetween(_ pick: inout Int) -> Int {
        let round = (pick &- 1) & 2 != 0 ? 1 : 0
        let other = pick ^ 3
        let difference = voices[pick].status &- voices[other].status
        if Self.negative8(difference) { return round }
        if difference != 0 || UInt8(pick & 2) == rounds[round] { pick = other }
        return round
    }

    // MARK: Pitch

    /// `CalcNote` (shared.asm): the voice's pitch as a logarithm of its period, from its note, the
    /// channel's bend, its portamento and its instrument's tuning; on a note's start, the octave of its
    /// sample that is played (the first that brings the period down to `PREF_PERIOD`'s or below),
    /// remembered, and taken off again when the pitch is worked out afresh (`VOICE_RECALC`). The period
    /// is nought, as an error, for a pitch too high. Returns the octave's sample.
    mutating func calcNote(_ v: Int) -> Int {
        let c = voices[v].channel
        var bend = Int32(Int16(bitPattern: channels[c].realBend))
        voices[v].lastPeriod = 0
        var glide: Int32 = 0
        if voices[v].flags & Self.voicePortamento != 0 {
            // (The notes apart, times the portamento's time so far, over its length, in a word.)
            let apart = Int32(Int8(bitPattern: voices[v].endNote &- voices[v].baseNote))
            let product = Int32(bitPattern: UInt32(bitPattern: voices[v].portaTicks) &* UInt32(bitPattern: apart))
            glide = Int32(Int16(truncatingIfNeeded: Self.divsWord(product, Int16(bitPattern: channels[c].portamentoTime))))
        }
        bend &+= glide
        var tone = bend &+ Int32(UInt16(voices[v].baseNote) << 8)
        let instrument = patch(voices[v].patch)
        let tuning = Self.divsWord(Int32(instrument.tune) << 8, 24)
        tone &+= Int32(Int16(truncatingIfNeeded: tuning))
        tone &-= 45 << 8
        // ((tone << 2) / 3) << 4, the division in a word: the logarithm, in 65,536ths of an octave.
        tone = Int32(Int16(truncatingIfNeeded: Self.divsWord(tone &* 4, 3))) &<< 4
        var logPeriod = Self.kValue &- tone
        var sample = instrument.sample
        if voices[v].flags & Self.voiceRecalc == 0 {
            voices[v].periodOffset = 0
            while logPeriod > Self.preferredPeriod, let next = self.sample(sample)?.next, next >= 0 {
                sample = next
                voices[v].periodOffset &+= 0x10000
                logPeriod &-= 0x10000
            }
        } else {
            logPeriod &-= voices[v].periodOffset
        }
        guard logPeriod >= Self.periodLimit else { return sample }
        voices[v].lastPeriod = UInt16(truncatingIfNeeded: Self.intAlg(logPeriod))
        return sample
    }

    /// `K_VALUE`, `PREF_PERIOD` and `PERIOD_LIMIT` (driver.i): the logarithm of the period of MIDI's note
    /// 45 untuned, the highest a sample is played at before its next octave down is taken, and the
    /// lowest there may be.
    static let kValue: Int32 = 0x09FD77, preferredPeriod: Int32 = 0x08FD77, periodLimit: Int32 = 0x06F73D

    /// `IntAlg` (shared.asm): two to the power of a logarithm of 16 bits of fraction, from a table of 256
    /// steps of the fraction, between which it goes in a straight line, rounded. A power of 32 or more
    /// is nought. (What the driver's register held before, in the bits below the sixteen of the result
    /// that it shifts in, is taken as nought: it would matter only to a period too long for Paula's
    /// register of sixteen bits.)
    static func intAlg(_ logarithm: Int32) -> UInt32 {
        let bits = UInt32(bitPattern: logarithm)
        let mantissa = UInt16(truncatingIfNeeded: bits)
        let index = Int(mantissa >> 8)
        let low = alogTable[index]
        let step = alogTable[index + 1] &- low
        let fraction = (mantissa << 8) &+ 128
        let product = UInt32(step) * UInt32(fraction)
        let sum = UInt32(low) + (product >> 16)
        let carry = sum > 0xFFFF
        var value = (UInt32(UInt16(truncatingIfNeeded: sum)) << 16 | 1)
        value = value >> 1 | value << 31
        let power = UInt16(truncatingIfNeeded: bits >> 16)
        guard power < 32 else { return 0 }
        let shift = UInt32(31 - power)
        // Rounded by the last bit shifted out (or, for no shift, by the carry of the sum before).
        let round: UInt32 = shift == 0 ? (carry ? 1 : 0) : value >> (shift - 1) & 1
        return (value >> shift) &+ round
    }

    /// `alogtable`: two to the power of each 256th of an octave, less one, in 65,536ths.
    static let alogTable: [UInt16] = [
        0, 178, 356, 535, 714, 893, 1073, 1254, 1435, 1617, 1799, 1981, 2164, 2348, 2532, 2716,
        2902, 3087, 3273, 3460, 3647, 3834, 4022, 4211, 4400, 4590, 4780, 4971, 5162, 5353, 5546, 5738,
        5932, 6125, 6320, 6514, 6710, 6906, 7102, 7299, 7496, 7694, 7893, 8092, 8292, 8492, 8693, 8894,
        9096, 9298, 9501, 9704, 9908, 10113, 10318, 10524, 10730, 10937, 11144, 11352, 11560, 11769, 11979, 12189,
        12400, 12611, 12823, 13036, 13249, 13462, 13676, 13891, 14106, 14322, 14539, 14756, 14974, 15192, 15411, 15630,
        15850, 16071, 16292, 16514, 16737, 16960, 17183, 17408, 17633, 17858, 18084, 18311, 18538, 18766, 18995, 19224,
        19454, 19684, 19915, 20147, 20379, 20612, 20846, 21080, 21315, 21550, 21786, 22023, 22260, 22498, 22737, 22977,
        23216, 23457, 23698, 23940, 24183, 24426, 24670, 24915, 25160, 25406, 25652, 25900, 26148, 26396, 26645, 26895,
        27146, 27397, 27649, 27902, 28155, 28409, 28664, 28919, 29175, 29432, 29690, 29948, 30207, 30466, 30727, 30988,
        31249, 31512, 31775, 32039, 32303, 32568, 32834, 33101, 33369, 33637, 33906, 34175, 34446, 34717, 34988, 35261,
        35534, 35808, 36083, 36359, 36635, 36912, 37190, 37468, 37747, 38028, 38308, 38590, 38872, 39155, 39439, 39724,
        40009, 40295, 40582, 40870, 41158, 41448, 41738, 42029, 42320, 42613, 42906, 43200, 43495, 43790, 44087, 44384,
        44682, 44981, 45280, 45581, 45882, 46184, 46487, 46791, 47095, 47401, 47707, 48014, 48322, 48631, 48940, 49251,
        49562, 49874, 50187, 50500, 50815, 51131, 51447, 51764, 52082, 52401, 52721, 53041, 53363, 53685, 54008, 54333,
        54658, 54983, 55310, 55638, 55966, 56296, 56626, 56957, 57289, 57622, 57956, 58291, 58627, 58964, 59301, 59640,
        59979, 60319, 60661, 61003, 61346, 61690, 62035, 62381, 62727, 63075, 63424, 63774, 64124, 64476, 64828, 65182,
        0,
    ]

    // MARK: Envelopes

    /// `EnvelopeManager` (shared.asm): each voice in turn (`DoOneVoice`), a frame's time on; then no
    /// channel is any longer marked as changed.
    mutating func envelopeManager<Output: TFMXOutput>(_ output: inout Output) {
        for v in 0 ..< 4 { doOneVoice(v, &output) }
        for c in 0 ..< 16 { channels[c].flags &= ~Self.chanAltered }
    }

    /// `DoOneVoice`: a voice's envelope moved on by a frame (`glob_FrameUnit`), a new step begun when one
    /// ends, a note just started set on its attack (or straight to its sustain at its instrument's
    /// volume, if it has none), a released one on its release (or to silence); a voice halted the frame
    /// before silenced. Then its volume, and its pitch if it glides or its channel has changed; and the
    /// two sent to audio.device (`ADCMD_PERVOL`). A voice sustaining that nothing changes is left be.
    mutating func doOneVoice<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        let c = voices[v].channel
        guard c >= 0 else { return }
        let delta = Self.frameUnit
        var volume: UInt16 = 0
        var step = Step.envelope
        let status = voices[v].status
        if status == Self.envSustain {
            guard channels[c].flags & Self.chanAltered != 0 || voices[v].flags & Self.voicePortamento != 0 else { return }
            step = .volume
        } else if status == Self.envHalt {
            killVoice(v, &output)
            return
        } else if status == Self.envStart {
            let instrument = patch(voices[v].patch)
            if instrument.attack >= 0 {
                voices[v].envelope = instrument.attack
                voices[v].envelopeLeft = instrument.attackCount
                let segment = envelope(instrument.attack)
                voices[v].ticksLeft = Int32(segment.duration) << 8
                voices[v].status = Self.envAttack
                voices[v].incrVolume = Self.calcIncrVol(Int32(segment.volume), time: segment.duration)
            } else {
                voices[v].status = Self.envSustain
                voices[v].baseVolume = instrument.volume
                step = .volume
            }
        } else if status == Self.envRelease {
            let instrument = patch(voices[v].patch)
            if instrument.release >= 0 {
                voices[v].envelope = instrument.release
                voices[v].envelopeLeft = instrument.releaseCount
                let segment = envelope(instrument.release)
                voices[v].ticksLeft = Int32(segment.duration) << 8
                voices[v].status = Self.envDecay
                voices[v].incrVolume = Self.calcIncrVol(Int32(segment.volume) - Int32(voices[v].baseVolume), time: segment.duration)
            } else {
                voices[v].status = Self.envHalt
                step = .send
            }
        }

        if step == .envelope, voices[v].status != Self.envSustain {
            // (`.l9`) The step's time runs out in this frame: its volume is reached, and the next step begun;
            // or, after the last, the sustain, or for a release silence.
            if !Self.negative(delta &- voices[v].ticksLeft) {
                let segment = envelope(voices[v].envelope)
                voices[v].baseVolume = segment.volume
                voices[v].envelopeLeft &-= 1
                if voices[v].envelopeLeft != 0 {
                    voices[v].envelope += 1
                    let next = envelope(voices[v].envelope)
                    voices[v].ticksLeft = Int32(next.duration) << 8
                    voices[v].incrVolume = Self.calcIncrVol(Int32(next.volume) - Int32(voices[v].baseVolume), time: next.duration)
                } else if voices[v].status == Self.envDecay {
                    voices[v].status = Self.envHalt
                    step = .send
                } else {
                    voices[v].status = Self.envSustain
                }
            } else {
                // (`.l10`) On towards it, no lower than nought and no higher than full.
                var level = Int32(voices[v].baseVolume) &+ voices[v].incrVolume
                if level < 0 {
                    level = 0
                } else if !Self.negative(level &- 0x8000) {
                    level = 0x8000
                }
                voices[v].baseVolume = UInt16(truncatingIfNeeded: level)
                voices[v].ticksLeft &-= delta
            }
        }

        if step != .send {
            // (`.l18`)
            volume = calcVolume(v)
            var recalculate = channels[c].flags & Self.chanAltered != 0
            if voices[v].flags & Self.voicePortamento != 0 {
                voices[v].portaTicks &+= delta
                let time = UInt16(truncatingIfNeeded: UInt32(bitPattern: voices[v].portaTicks) >> 8)
                if !Self.negative16(time &- channels[c].portamentoTime) {
                    voices[v].flags &= ~Self.voicePortamento
                    voices[v].baseNote = voices[v].endNote
                }
                recalculate = true
            }
            if recalculate {
                voices[v].flags |= Self.voiceRecalc
                _ = calcNote(v)
            }
        }

        // (`.l17`) A period of nought is an error, sent as 1000 and silence.
        let period = voices[v].lastPeriod
        setPeriodAndVolume(v, period: period != 0 ? period : 1000, volume: period != 0 ? volume : 0)
    }

    private enum Step { case envelope, volume, send }

    /// `calc_incrvol`: how far the volume moves each frame to go by `delta` in `time` milliseconds, as
    /// 1000 × the distance over the time × 50 frames a second; all of it at once for no time, or for a
    /// time so short the step would be further than the distance (each compared in a word).
    static func calcIncrVol(_ delta: Int32, time: UInt16) -> Int32 {
        guard time != 0 else { return delta }
        let distance = delta < 0 ? 0 &- delta : delta
        let saved = UInt16(truncatingIfNeeded: distance)
        let step = UInt32(UInt16(truncatingIfNeeded: distance)) * 1000 / (UInt32(time) * frequency)
        if negative16(saved &- UInt16(truncatingIfNeeded: step)) { return delta }
        let signed = Int32(bitPattern: step)
        return delta < 0 ? 0 &- signed : signed
    }

    /// `CalcVolume` (shared.asm): the driver's volume (64), times the note's volume over 128 if it is
    /// less than 128, times the top byte of the envelope's over 128 if it is less than 128 (the
    /// driver's "experiment"), and no more than 64. The channel's volume is in the note's already.
    mutating func calcVolume(_ v: Int) -> UInt16 {
        var volume = global.volume
        let noteVolume = voices[v].noteVolume
        if Self.negative16(noteVolume &- 128) { volume = UInt16(truncatingIfNeeded: UInt32(noteVolume) * UInt32(volume)) >> 7 }
        let envelope = voices[v].baseVolume >> 8
        if Self.negative16(envelope &- 128) { volume = UInt16(truncatingIfNeeded: UInt32(volume) * UInt32(envelope)) >> 7 }
        if !Self.negative16(volume &- 65) { volume = 64 }
        voices[v].lastVolume = UInt8(truncatingIfNeeded: volume)
        return volume
    }

    // MARK: Controllers

    /// `PitchBend` (shared.asm): the bend wheel's fourteen bits, and how far that bends the pitch, in
    /// 256ths of a semitone: (bend - 8192) × range × 256 / 8192, in words.
    mutating func pitchBend(_ c: Int, lsb: UInt8, msb: UInt8) {
        let shifted = UInt16(msb) << 7
        let bend = shifted & 0xFF00 | UInt16(UInt8(truncatingIfNeeded: shifted) &+ lsb)
        channels[c].pitchBend = bend
        let range = Int16(bitPattern: UInt16(channels[c].pitchBendRange) << 8)
        let product = Int32(Int16(bitPattern: bend &- (64 << 7))) * Int32(range)
        channels[c].realBend = UInt16(truncatingIfNeeded: Self.divsWord(product, 64 << 7))
        channels[c].flags |= Self.chanAltered
    }

    /// `ControlCh` (shared.asm): MIDI's controllers, as many as the driver knows: portamento's time (5,
    /// 37), the bend's range (data entry, 6, for registered parameter nought), the channel's volume (7,
    /// for its notes to come), the side (10), the damper pedal (64), portamento (65), the Amiga's
    /// filter (81), the registered parameter (100, 101), and Reset All Controllers, All Notes Off, MONO,
    /// POLY and All Sounds Off (121, 123, 126, 127, 120). Event `at` is the control's own.
    mutating func controlChange<Output: TFMXOutput>(_ c: Int, number: UInt8, value: UInt8, at: Int, _ output: inout Output) {
        switch number {
        case 5:
            channels[c].portamentoTime = UInt16(value) << 7
        case 37:
            channels[c].portamentoTime = channels[c].portamentoTime & 0x3F80 | UInt16(value)
        case 6:
            guard channels[c].rpn == 0 else { return }
            let range = Int8(bitPattern: value) <= 24 ? value : 24
            channels[c].pitchBendRange = range
            let offset = channels[c].pitchBend &- (64 << 7)
            guard offset != 0 else { return }
            // (Here without signs, unlike `PitchBend`: a bend downwards comes out as one far upwards.)
            let product = (UInt32(offset) * UInt32(range)) << 8
            channels[c].realBend = UInt16(truncatingIfNeeded: Self.divuWord(product, 64 << 7))
            channels[c].flags |= Self.chanAltered
        case 7:
            channels[c].volume = value == 0 ? 0 : value &+ 1
        case 10:
            // (Below 64 sets the bit the driver's notes call the right, above 64 clears it; 64 sets it for
            // an even channel.)
            let difference = value &- 64
            if Self.negative8(difference) || (difference == 0 && channels[c].number & 1 == 0) {
                channels[c].flags |= Self.chanPan
            } else {
                channels[c].flags &= ~Self.chanPan
            }
        case 64:
            if value & 0x40 != 0 {
                channels[c].flags |= Self.chanDamper
            } else {
                channels[c].flags &= ~Self.chanDamper
                for v in 0 ..< 4 where voices[v].channel == c && voices[v].flags & Self.voiceDamper != 0 {
                    voices[v].flags &= ~Self.voiceDamper
                    voices[v].status = Self.envRelease
                }
            }
        case 65:
            if value & 0x40 != 0 {
                channels[c].flags |= Self.chanPortamento
            } else {
                channels[c].flags &= ~Self.chanPortamento
                // The driver means to forget the channel's last note here, but writes its $FF through the
                // wrong register, which holds the event: into the 17th byte from it, the lower byte of the
                // length of the event two on (`ControlCh`, `.l21`).
                clobberEvent(at + 2)
            }
        case 81:
            let difference = value &- 64
            setAudioFilter(difference == 0 ? global.filter : Self.negative8(difference) ? 0 : 1)
        case 100:
            channels[c].rpn = channels[c].rpn & 0xFF00 | UInt16(value)
        case 101:
            channels[c].rpn = channels[c].rpn & 0x00FF | UInt16(value) << 8
        case 121:
            resetChannel(c)
        case 123:
            allNotesOff(c)
        case 126:
            channels[c].flags |= Self.chanMono
            allNotesOff(c)
        case 127:
            channels[c].flags &= ~Self.chanMono
            allNotesOff(c)
        case 120:
            allSoundsOff(c, &output)
        default:
            break
        }
    }
}
