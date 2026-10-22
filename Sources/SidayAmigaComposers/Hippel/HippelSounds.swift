// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A port of libtfmxaudiodecoder's instruments and sound sequences of Jochen Hippel's players and of
// Future Composer (src/Jochen/Instrument.cpp), Copyright (C) Michael Schwendt, used under the
// GPL-2.0-or-later, as it is at its commit dcec102 of 2026-09-26.

import SidayChips

// An instrument is a volume modulation sequence: its envelope's speed, the sound modulation sequence
// to play, the vibrato's speed, amplitude and delay, then the envelope (volumes, and commands). The
// sound sequence, run each tick, sets the samples or waves Paula plays and transposes the note (or
// fixes it), with commands $E0 to $EA, which the players of different years and games did differently.

extension HippelDecoder {
    /// Starts an instrument: its volume sequence, and with it its sound sequence.
    mutating func setInstrument(_ v: Int, _ instr: UInt8) {
        voices[v].currentVolSeq = instr
        var seqOffs = getVolSeq(instr)
        // (Future Composer did not check an envelope's speed: one of nought is dealt with as it plays.)
        voices[v].envelopeSpeed = byte(seqOffs)
        voices[v].envelopeCount = voices[v].envelopeSpeed
        seqOffs &+= 1
        var sound = byte(seqOffs) // the sound sequence
        seqOffs &+= 1
        voices[v].vibSpeed = byte(seqOffs)
        seqOffs &+= 1
        voices[v].vibFlag = 0x40 // up, to start with
        voices[v].vibAmpl = byte(seqOffs)
        voices[v].vibCurOffs = voices[v].vibAmpl
        seqOffs &+= 1
        voices[v].vibDelay = byte(seqOffs)
        seqOffs &+= 1
        voices[v].volSeq = seqOffs // the envelope
        voices[v].volSeqPos = 0
        voices[v].volSustainTime = 0

        Analyze.insert(&analyze.sndSeqs, sound) // also if it is $80
        // Older TFMX and Future Composer set the sound sequence as it is; the compressed modules and
        // later TFMX can have it set by bit 6 of the note's second byte; TFMX 7V keeps the one playing
        // for $80.
        if !traits.volSeqSnd80 || sound != 0x80 {
            if traits.porta40SetSnd, voices[v].pattVal2 & 0x40 != 0 {
                sound = UInt8(bitPattern: voices[v].portaSpeed)
            } else if traits.porta80SetSnd, voices[v].pattVal2 & 0x80 != 0 { // MCMD
                sound = UInt8(bitPattern: voices[v].portaSpeed)
            }
            voices[v].currentSndSeq = sound
            voices[v].sndSeq = getSndSeq(sound)
            voices[v].sndSeqPos = 0
            voices[v].sndModSustainTime = 0
        }
        gatherVibrato(v)
    }

    mutating func gatherVibrato(_ v: Int) {
        if voices[v].vibSpeed > 0x80 { analyze.negVibSpeed = true }
    }

    /// Plays sample or wave `num`, from its start, and after a few ticks its repeat.
    mutating func setWave<Output: TFMXOutput>(_ v: Int, _ num: UInt8, _ out: inout Output) {
        let sample = samples[Int(num)]
        voices[v].pSampleStart = sample.pStart
        paula[v].start = sample.pStart
        paula[v].length = sample.len
        takeNextBuf(v, &out)
        voices[v].repeatOffset = UInt16(truncatingIfNeeded: sample.repOffs)
        voices[v].repeatLength = sample.repLen
        voices[v].repeatDelay = 3
    }

    // MARK: The sound sequence

    mutating func pushModFunc(_ f: ModFunc) {
        modFuncs[modFuncCount] = f
        modFuncCount += 1
    }

    /// The sound sequence's tick for a voice, then its period and volume.
    mutating func soundModulation<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        admin.readModRecurse = 0
        modFuncCount = 0
        pushModFunc(.processSndModSustain)
        while modFuncCount > 0 {
            admin.readModRecurse += 1
            guard admin.readModRecurse < Self.recurseLimit else { break }
            modFuncCount -= 1
            let f = modFuncs[modFuncCount]
            switch f {
            case .processSndModSustain: processSndModSustain(v)
            case .processSndModSeq: processSndModSeq(v)
            case .waveModulation: waveModulation(v, &out)
            case .sndSeqTrans: sndSeqTrans(v)
            case .undef: sndSeqUndef()
            case .e0: sndSeqE0(v)
            case .e1: break // the end: nothing
            case .e1WaveMod: pushModFunc(.waveModulation)
            case .e2: sndSeqE2(v, &out)
            case .e3: sndSeqE3(v)
            case .e4: sndSeqE4(v, &out)
            case .e5: sndSeqE5(v, &out)
            case .e5RepOffs: sndSeqE5RepOffs(v, &out)
            case .e6: sndSeqE6(v)
            case .e7: sndSeqE7(v)
            case .e7SetDiffWave: sndSeqE7SetDiffWave(v, &out)
            case .e8: sndSeqE8(v)
            case .e9: sndSeqE9(v, &out)
            case .eaSkip: voices[v].sndSeqPos &+= 2
            case .ea: sndSeqEA(v)
            case .fcE9: fcSndSeqE9(v, &out)
            case .fcEAPitchbend: fcSndSeqEAPitchbend(v)
            }
        }
        processPerVol(v)
    }

    mutating func processSndModSustain(_ v: Int) {
        if voices[v].sndModSustainTime == 0 {
            pushModFunc(.processSndModSeq)
        } else {
            voices[v].sndModSustainTime &-= 1
            if traits.skipToWaveMod { pushModFunc(.waveModulation) } // some players
        }
    }

    mutating func processSndModSeq(_ v: Int) {
        let f = byte(voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos))
        // Commands are $E0 to $EA; bytes below are transposes, and from $80 notes to play fixed (which
        // are below $C8, as the periods go to $48).
        if f < 0xE0 {
            pushModFunc(.waveModulation)
            pushModFunc(.sndSeqTrans)
        } else if f < 0xEB {
            if f == 0xE7 { Analyze.insert(&analyze.e7Seqs, voices[v].currentSndSeq) }
            pushModFunc(sndModFuncs[Int(f - 0xE0)])
        }
    }

    /// After a command: a transpose next, or the next command (as the player has it).
    mutating func sndSeqNext() {
        if traits.sndSeqToTrans {
            pushModFunc(.sndSeqTrans)
        } else if traits.sndSeqGoto {
            pushModFunc(.processSndModSeq)
        }
    }

    mutating func sndSeqUndef() { sndSeqNext() }

    /// $E0: go to a place in the sequence.
    mutating func sndSeqE0(_ v: Int) {
        voices[v].sndSeqPos = UInt16(byte(voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos) &+ 1) & 0x3F)
        pushModFunc(.processSndModSeq)
    }

    /// $E2: set the wave, and start the envelope again.
    mutating func sndSeqE2<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        prepareChannelUpdate(v, &out)
        voices[v].volRandomThreshold = 0
        voices[v].currentWave = 0xFF
        voices[v].waveModSwitch1 = 0
        voices[v].volSeqPos = 0
        voices[v].envelopeCount = 1
        setWave(v, byte(voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos) &+ 1), &out)
        voices[v].sndSeqPos &+= 2
        sndSeqNext()
    }

    /// $E3: set the vibrato.
    mutating func sndSeqE3(_ v: Int) {
        let seqOffs = voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos) &+ 1
        voices[v].vibSpeed = byte(seqOffs)
        voices[v].vibAmpl = byte(seqOffs &+ 1)
        voices[v].sndSeqPos &+= 3
        gatherVibrato(v)
        sndSeqNext()
    }

    /// $E4: a new wave, without stopping the voice.
    mutating func sndSeqE4<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        setWave(v, byte(voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos) &+ 1), &out)
        voices[v].repeatDelay = 0
        voices[v].sndSeqPos &+= 2
        voices[v].waveModSwitch1 = 0
        sndSeqNext()
    }

    /// $E5 of some players: a stretch of a sample, a number of its repeat's lengths into it.
    mutating func sndSeqE5RepOffs<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        prepareChannelUpdate(v, &out)
        let seqOffs = voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos) &+ 1
        let s = byte(seqOffs) // the sample
        let x = byte(seqOffs &+ 1) // how many repeats' lengths
        var snd = samples[Int(s)]
        let skip = UInt32(Int(snd.repLen) * Int(x))
        snd.startOffs &+= skip
        snd.len = snd.repLen
        snd.repOffs &+= skip
        snd.assertBoundaries(length)

        voices[v].pSampleStart = snd.pStart
        paula[v].start = snd.pStart
        paula[v].length = snd.len
        takeNextBuf(v, &out)
        voices[v].repeatOffset = UInt16(truncatingIfNeeded: snd.repOffs)
        voices[v].repeatLength = snd.repLen
        voices[v].repeatDelay = 3
        voices[v].volSeqPos = 0
        voices[v].envelopeCount = 1
        voices[v].sndSeqPos &+= 3
        if traits.sndSeqGoto { pushModFunc(.processSndModSeq) }
    }

    /// $E5: wave modulation, a stretch of a sample moved along it a little each few ticks.
    mutating func sndSeqE5<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        voices[v].volRandomThreshold = 0
        prepareChannelUpdate(v, &out)
        var seqOffs = voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos) &+ 1
        let s = Int(byte(seqOffs))
        seqOffs &+= 1
        voices[v].waveModStartOffs = samples[s].startOffs
        voices[v].waveModEndOffs = samples[s].startOffs &+ UInt32(samples[s].len) &+ UInt32(samples[s].len)
        var p0 = UInt16(byte(seqOffs)) << 8 | UInt16(byte(seqOffs &+ 1))
        seqOffs &+= 2
        if p0 == 0xFFFF { p0 = samples[s].len }
        voices[v].waveModCurrentOffs = p0
        voices[v].waveModLen = UInt16(byte(seqOffs)) << 8 | UInt16(byte(seqOffs &+ 1))
        seqOffs &+= 2
        voices[v].waveModOffs = Int16(bitPattern: UInt16(byte(seqOffs)) << 8 | UInt16(byte(seqOffs &+ 1)))
        seqOffs &+= 2
        voices[v].waveModSpeedCount = 0
        voices[v].waveModSpeed = Int8(bitPattern: byte(seqOffs))
        voices[v].waveModInit = true // its first step takes the stretch as it is
        voices[v].waveModSwitch1 = 0xFF
        voices[v].waveModSwitch2 = 0
        voices[v].volSeqPos = 0
        voices[v].envelopeCount = 1
        voices[v].sndSeqPos &+= 9
        if traits.sndSeqGoto { pushModFunc(.processSndModSeq) }
    }

    /// $E6: the wave modulation's length, step and speed, on the sample it has.
    mutating func sndSeqE6(_ v: Int) {
        var seqOffs = voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos) &+ 1
        voices[v].waveModLen = UInt16(byte(seqOffs)) << 8 | UInt16(byte(seqOffs &+ 1))
        seqOffs &+= 2
        voices[v].waveModOffs = Int16(bitPattern: UInt16(byte(seqOffs)) << 8 | UInt16(byte(seqOffs &+ 1)))
        seqOffs &+= 2
        voices[v].waveModSpeedCount = 0
        voices[v].waveModSpeed = Int8(bitPattern: byte(seqOffs))
        voices[v].waveModInit = true
        voices[v].waveModSwitch2 = 0
        voices[v].sndSeqPos &+= 6
        if traits.sndSeqGoto { pushModFunc(.processSndModSeq) }
    }

    /// $E7 of old: go to another sound sequence.
    mutating func sndSeqE7(_ v: Int) {
        let seq = byte(voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos) &+ 1)
        voices[v].currentSndSeq = seq
        voices[v].sndSeq = getSndSeq(seq)
        voices[v].sndSeqPos = 0
        pushModFunc(.processSndModSeq)
    }

    /// $E7 of later players: a different wave, if it is.
    mutating func sndSeqE7SetDiffWave<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        let s = byte(voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos) &+ 1)
        if s != voices[v].currentWave {
            voices[v].volRandomThreshold = 0
            voices[v].currentWave = s
            prepareChannelUpdate(v, &out)
            setWave(v, s, &out)
        }
        voices[v].waveModSwitch1 = 0
        voices[v].volSeqPos = 0
        voices[v].envelopeCount = 1
        voices[v].sndSeqPos &+= 2
        sndSeqNext()
    }

    /// $E8: hold the sequence for a number of ticks.
    mutating func sndSeqE8(_ v: Int) {
        voices[v].sndModSustainTime = byte(voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos) &+ 1)
        voices[v].sndSeqPos &+= 2
        pushModFunc(.processSndModSustain)
    }

    /// $E9: a sample of a sample pack, played once. (Some players do not check the pack's "SSMP".)
    mutating func sndSeqE9<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        voices[v].volRandomThreshold = 0
        voices[v].currentWave = 0xFF
        prepareChannelUpdate(v, &out)
        var seqOffs = voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos) &+ 1
        var s = UInt16(byte(seqOffs)) // the pack
        seqOffs &+= 1
        var sndOffs = samples[Int(s)].startOffs
        if !traits.checkSSMPtag || long(sndOffs) == Self.ssmp {
            let packLen = word(sndOffs &+ 4)
            let packOffs = word(sndOffs &+ 6)
            sndOffs &+= 8
            // Where the pack's samples begin.
            let samplesOffset = sndOffs &+ UInt32(packLen) &* 24 &+ UInt32(packOffs) &* 4
            s = UInt16(byte(seqOffs)) // the sample in the pack
            sndOffs &+= UInt32(s) &* 24
            let startOffset = long(sndOffs) & 0xFFFF_FFFE
            let endOffset = long(sndOffs &+ 4) & 0xFFFF_FFFE
            let len = UInt16(truncatingIfNeeded: (endOffset &- startOffset) >> 1)

            var snd = Sample(startOffs: startOffset &+ samplesOffset, repOffs: 0, len: len, repLen: 1)
            snd.assertBoundaries(length)
            voices[v].pSampleStart = snd.pStart
            paula[v].start = snd.pStart
            paula[v].length = snd.len
            takeNextBuf(v, &out)
            voices[v].repeatOffset = UInt16(truncatingIfNeeded: snd.repOffs)
            voices[v].repeatLength = snd.repLen
            let o = snd.startOffs &+ snd.repOffs
            setByte(o &+ 1, byte(o))
            voices[v].repeatDelay = 3
            voices[v].waveModSwitch1 = 0
            voices[v].volSeqPos = 0
            voices[v].envelopeCount = 1
        }
        voices[v].sndSeqPos &+= 3
        sndSeqNext()
    }

    /// $EA of TFMX 7V and compressed modules: take a random amount off the volume.
    mutating func sndSeqEA(_ v: Int) {
        if traits.randomVolume {
            voices[v].volRandomThreshold = byte(voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos) &+ 1)
            voices[v].volRandomCurrent = 0
        }
        voices[v].sndSeqPos &+= 2
        if traits.sndSeqGoto { pushModFunc(.processSndModSeq) }
    }

    /// A transpose (or a note to play fixed), not a command.
    mutating func sndSeqTrans(_ v: Int) {
        voices[v].seqTranspose = signedByte(voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos))
        voices[v].sndSeqPos &+= 1
    }

    /// Moves the wave modulation's stretch along its sample, every `waveModSpeed` ticks, until it
    /// would go outside it.
    mutating func waveModulation<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        // Nothing, if it is off.
        if voices[v].waveModSwitch1 == 0 || voices[v].waveModSwitch2 != 0 { return }
        voices[v].waveModSpeedCount &-= 1
        if voices[v].waveModSpeedCount >= 0 { return }
        voices[v].waveModSpeedCount = voices[v].waveModSpeed

        var offs = Int32(voices[v].waveModCurrentOffs)
        let len = voices[v].waveModLen
        if voices[v].waveModInit {
            voices[v].waveModInit = false
        } else {
            offs &+= Int32(voices[v].waveModOffs)
            if offs < 0 {
                voices[v].waveModSwitch2 = 0xFF
                offs &-= Int32(voices[v].waveModOffs) // back from before the start
            } else {
                let repeatStartOffs = voices[v].waveModStartOffs &+ UInt32(bitPattern: offs << 1)
                let repeatEndOffs = repeatStartOffs &+ UInt32(len) &+ UInt32(len)
                if repeatEndOffs > voices[v].waveModEndOffs {
                    voices[v].waveModSwitch2 = 0xFF
                    offs &-= Int32(voices[v].waveModOffs) // back from beyond the end
                }
            }
        }
        voices[v].waveModCurrentOffs = UInt16(truncatingIfNeeded: offs)

        var snd = Sample(startOffs: voices[v].waveModStartOffs &+ UInt32(bitPattern: offs << 1), repOffs: 0, len: len, repLen: len)
        snd.assertBoundaries(length)
        paula[v].start = snd.pStart
        paula[v].length = snd.len
        takeNextBuf(v, &out)
        voices[v].repeatOffset = UInt16(truncatingIfNeeded: snd.repOffs)
        voices[v].repeatLength = snd.len
        voices[v].repeatDelay = 0
    }

    // MARK: Future Composer's commands

    /// $E9 of Future Composer, which brought in its "SSMP" sample packs.
    mutating func fcSndSeqE9<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        voices[v].volRandomThreshold = 0
        voices[v].currentWave = 0xFF
        prepareChannelUpdate(v, &out)
        var seqOffs = voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos) &+ 1
        var s = UInt16(byte(seqOffs)) // the pack, or a sample
        seqOffs &+= 1
        if s < 10 {
            var sndOffs = samples[Int(s)].startOffs
            if long(sndOffs) == Self.ssmp {
                sndOffs &+= 4
                // Past the header and the ten samples' sixteen bytes each, twice over.
                let smpStart = sndOffs &+ 320
                s = UInt16(byte(seqOffs)) << 4 // the sample, by sixteen bytes
                sndOffs &+= UInt32(s)

                var snd = Sample(startOffs: smpStart &+ long(sndOffs), repOffs: UInt32(word(sndOffs &+ 6)),
                                 len: word(sndOffs &+ 4), repLen: word(sndOffs &+ 8))
                snd.assertBoundaries(length)
                voices[v].pSampleStart = snd.pStart
                paula[v].start = snd.pStart
                paula[v].length = snd.len
                takeNextBuf(v, &out)
                voices[v].repeatDelay = 3
                // (The players set the period here by mistake, which is not done.)
                voices[v].repeatOffset = UInt16(truncatingIfNeeded: snd.repOffs)
                voices[v].repeatLength = snd.repLen
                if voices[v].repeatLength == 1 {
                    // The first word after a sample played once is cleared, against its beeping.
                    setByte(smpStart &+ UInt32(voices[v].repeatOffset), 0)
                    setByte(smpStart &+ UInt32(voices[v].repeatOffset) &+ 1, 0)
                }
                voices[v].volSeqPos = 0
                voices[v].envelopeCount = 1
            }
        }
        voices[v].sndSeqPos &+= 3
        sndSeqNext()
    }

    /// $EA of Future Composer: pitch bend, its speed and time.
    mutating func fcSndSeqEAPitchbend(_ v: Int) {
        let seqOffs = voices[v].sndSeq &+ UInt32(voices[v].sndSeqPos) &+ 1
        voices[v].pitchBendSpeed = signedByte(seqOffs &+ 1)
        voices[v].pitchBendTime = byte(seqOffs &+ 2)
        voices[v].sndSeqPos &+= 3
        sndSeqNext()
    }

    // MARK: The period and the volume

    /// The voice's volume from its envelope, and its period from its note and transposes, its vibrato
    /// and portamento, kept inside the player's range.
    mutating func processPerVol(_ v: Int) {
        voices[v].outputVolume = envelope(v)

        var t = voices[v].seqTranspose
        if t >= 0 {
            t = Int8(truncatingIfNeeded: Int(t) + Int(voices[v].pattVal1))
            t = Int8(truncatingIfNeeded: Int(t) + Int(voices[v].transpose))
        }
        // A transpose a few notes too far down goes round into the lowest octave, at $48.
        if t < 0, UInt8(bitPattern: t) & 0x7F >= 0x78 {
            t = Int8(truncatingIfNeeded: Int(t) + 0x48)
        }
        // (Otherwise a negative value from the sequence is a note played fixed.)
        var note = UInt8(bitPattern: t) & 0x7F
        var period: Int16
        if traits.lowerPeriods {
            note = UInt8(bitPattern: t) & 0x3F
            period = Int16(HippelTables.periodsLower[Int(note)])
        } else {
            period = Int16(HippelTables.periods[Int(note)])
        }
        // Checked once here, so that the lower periods can be in the same table.
        if Int(period) < Int(traits.periodMin) { period = Int16(traits.periodMin) }

        let vibrato = vibratoKind == .tfmx ? tfmxVibrato(v, UInt16(bitPattern: period), note) : cosoVibrato(v, UInt16(bitPattern: period))
        period = Int16(bitPattern: vibrato)
        let portamento: UInt16 = switch portamentoKind {
        case .tfmx: tfmxPortamento(v, UInt16(bitPattern: period))
        case .coso: cosoPortamento(v, UInt16(bitPattern: period))
        case .fc: fcPortamentoPitchbend(v, UInt16(bitPattern: period))
        }
        period = Int16(bitPattern: portamento)

        // The last range check (a period of $8000 or more being negative here, it is the shortest).
        if Int(period) < Int(traits.periodMin) {
            period = Int16(traits.periodMin)
        } else if Int(period) > Int(traits.periodMax) {
            period = Int16(traits.periodMax)
        }
        voices[v].outputPeriod = UInt16(bitPattern: period)
    }
}
