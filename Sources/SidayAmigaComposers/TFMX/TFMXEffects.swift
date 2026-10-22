// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A port of libtfmxaudiodecoder's effects of TFMX (src/Chris/Modulation.cpp), Copyright (C) Michael
// Schwendt, used under the GPL-2.0-or-later, as it is at its commit dcec102 of 2026-09-26.

import SidayChips

extension TFMXDecoder {
    /// A voice's effects, each tick: the moving start of its sample, the synthesiser, vibrato,
    /// portamento and envelope (once a macro has had a tick to set them, for some players), then random
    /// play and the fade, which sets Paula's volume.
    mutating func processModulation<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        if voices[v].effectsMode > 0 {
            addBegin(v, &out)
            sid(v)
            vibrato(v)
            portamento(v)
            envelope(v)
        } else if voices[v].effectsMode == 0 {
            voices[v].effectsMode = 1
        }
        randomPlay(v)
        fadeApply(v)
    }

    /// AddBegin's change added again every so many ticks, and then taken away as many times.
    mutating func addBegin<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        if variant.noAddBeginCount || voices[v].addBeginCount == 0 { return }
        voices[v].sampleStart &+= UInt32(bitPattern: voices[v].addBeginOffset)
        // (Only one module was found to go before the samples, by $10. TFMX Pro, $1fe8, lets it.)
        if voices[v].sampleStart < offsets.sampleData, variant.original == .none { voices[v].sampleStart = offsets.sampleData }
        if voices[v].sid.targetLength != 0 {
            voices[v].sid.sourceOffset = voices[v].sampleStart
        } else {
            toPaulaStart(v, voices[v].sampleStart, &out)
        }
        voices[v].addBeginCount &-= 1
        if voices[v].addBeginCount == 0 {
            voices[v].addBeginCount = voices[v].addBeginArg
            voices[v].addBeginOffset = 0 &- voices[v].addBeginOffset
        }
    }

    mutating func envelope(_ v: Int) {
        if voices[v].envelopeFlag == 0 { return }
        if voices[v].envelopeCount > 0 {
            voices[v].envelopeCount -= 1
            return
        }
        voices[v].envelopeCount = voices[v].envelopeFlag
        let target = Int(voices[v].envelopeTarget)
        if Int(voices[v].volume) < target { // up
            voices[v].volume = Int8(truncatingIfNeeded: Int(voices[v].volume) + Int(voices[v].envelopeSpeed))
            if Int(voices[v].volume) >= target {
                voices[v].volume = Int8(truncatingIfNeeded: target)
                voices[v].envelopeFlag = 0
            }
        } else { // down
            voices[v].volume = Int8(truncatingIfNeeded: Int(voices[v].volume) - Int(voices[v].envelopeSpeed))
            if Int(voices[v].volume) <= target {
                voices[v].volume = Int8(truncatingIfNeeded: target)
                voices[v].envelopeFlag = 0
            }
        }
    }

    /// Vibrato, by so much of the period (or, in TFMX 1, by so many of it).
    mutating func vibrato(_ v: Int) {
        if voices[v].vibratoTime == 0 { return }
        voices[v].vibratoDelta &+= Int16(voices[v].vibratoIntensity)
        let p: UInt16
        if variant.vibratoUnscaled {
            p = voices[v].period &+ UInt16(bitPattern: voices[v].vibratoDelta)
        } else {
            p = UInt16(truncatingIfNeeded: ((0x800 &+ Int32(voices[v].vibratoDelta)) &* Int32(voices[v].period)) >> 11)
        }
        if voices[v].portamentoSpeed == 0 { voices[v].outputPeriod = p }
        voices[v].vibratoCount &-= 1
        if voices[v].vibratoCount == 0 {
            voices[v].vibratoCount = voices[v].vibratoTime
            voices[v].vibratoIntensity = 0 &- voices[v].vibratoIntensity
        }
    }

    /// Portamento to the period of the note, by so much of the period each step (or, in TFMX 1, by so
    /// many of it), every so many ticks.
    mutating func portamento(_ v: Int) {
        if voices[v].portamentoSpeed == 0 { return }
        voices[v].portamentoWait &-= 1
        if voices[v].portamentoWait != 0 { return }
        voices[v].portamentoWait = voices[v].portamentoCount

        var current = voices[v].portamentoPeriod
        let target = voices[v].period
        let speed = voices[v].portamentoSpeed
        var reached = current == target
        // TFMX 1.x, $1680: at the note's period, it waits there, and is not stopped; so a note set
        // after is glided to as well.
        if reached, variant.original == .tfmx { return }
        if !reached {
            if current < target { // down: the period grows
                if variant.portaUnscaled {
                    current &+= speed
                } else {
                    current = UInt16(truncatingIfNeeded: ((0x100 &+ Int32(speed)) &* Int32(current)) >> 8)
                }
                reached = current >= target
            } else { // up: the period shrinks
                if variant.portaUnscaled {
                    current &-= speed
                } else {
                    current = UInt16(truncatingIfNeeded: ((0x100 &- Int32(speed)) &* Int32(current)) >> 8)
                }
                reached = current <= target
            }
        }
        if reached {
            voices[v].portamentoSpeed = 0
            current = target
        }
        current &= 0x7FF
        voices[v].portamentoPeriod = current
        voices[v].outputPeriod = current
    }

    // MARK: The synthesiser

    /// The synthesiser of some later players: each tick it makes the voice's own stretch of the samples
    /// (256 bytes for each voice, beginning four bytes in) afresh from another, which Paula plays.
    /// Each byte is taken from the source at a step the second operator changes, from a place the
    /// third moves; and, if the first operator's step is not nought, the sound moves towards what is
    /// taken only so far at each byte.
    mutating func sid(_ v: Int) {
        if voices[v].sid.targetLength == 0 { return }
        let sid = voices[v].sid
        // (The library writes with a pointer of its own, not checked against the memory: what would go
        // outside it is left out here.)
        var target = Int(offsets.sampleData) + Int(sid.targetOffset)
        var currSourceOffset: UInt32 = 0
        var x = sid.op3Offset
        let d = UInt8(truncatingIfNeeded: sid.op1InterDelta >> 8)
        var dx: UInt8 = 0
        var cur = Int16(sid.lastSample)

        @inline(__always) func put(_ value: Int16) {
            if target >= 0, target < size { memory[target] = UInt8(truncatingIfNeeded: value) }
            target += 1
        }

        for _ in 0 ... Int(sid.targetLength) {
            x &+= sid.op2Offset
            currSourceOffset &+= x
            let s = Int16(Int8(bitPattern: byte(sid.sourceOffset &+ ((currSourceOffset >> 16) & UInt32(sid.sourceLength)))))
            if d == 0 || s == cur { // sampled directly, or reached
                put(s)
            } else if s > cur { // higher
                cur = Int16(truncatingIfNeeded: Int(cur) + Int(d) + Int(dx))
                dx = cur > 0x7F ? 1 : 0
                if cur > 0x7F || cur >= s { // over the top, or reached
                    cur = s
                    put(s)
                } else {
                    put(cur)
                }
            } else { // lower
                cur = Int16(truncatingIfNeeded: Int(cur) - (Int(d) + Int(dx)))
                dx = cur < -128 ? 1 : 0
                if cur < -128 || cur <= s { // under the bottom, or reached
                    cur = s
                    put(s)
                } else {
                    put(cur)
                }
            }
        }
        voices[v].sid.lastSample = Int8(truncatingIfNeeded: cur)

        if d != 0 {
            voices[v].sid.op1InterDelta &+= UInt16(bitPattern: voices[v].sid.op1InterMod)
            voices[v].sid.op1Count &-= 1
            if voices[v].sid.op1Count == 0 {
                voices[v].sid.op1Count = voices[v].sid.op1Speed
                voices[v].sid.op1InterMod = 0 &- voices[v].sid.op1InterMod
            }
        }
        voices[v].sid.op3Offset &+= UInt32(bitPattern: Int32(voices[v].sid.op3Delta))
        voices[v].sid.op3Count &-= 1
        if voices[v].sid.op3Count == 0 {
            voices[v].sid.op3Count = voices[v].sid.op3Speed
            if voices[v].sid.op3Count != 0 { voices[v].sid.op3Delta = 0 &- voices[v].sid.op3Delta }
        }
        voices[v].sid.op2Offset &+= UInt32(bitPattern: Int32(voices[v].sid.op2Delta))
        voices[v].sid.op2Count &-= 1
        if voices[v].sid.op2Count == 0 {
            voices[v].sid.op2Count = voices[v].sid.op2Speed
            if voices[v].sid.op2Count != 0 { voices[v].sid.op2Delta = 0 &- voices[v].sid.op2Delta }
        }
    }

    // MARK: The fade

    /// The song's volume, set, or brought up or down to a target by one every so many ticks.
    mutating func fadeInit(_ target: UInt8, _ speed: UInt8) {
        if fade.active { return }
        fade.active = true
        fade.target = target
        fade.count = speed
        fade.speed = speed
        // With a speed of nought the volume is set at once.
        if fade.speed == 0 || fade.volume == fade.target {
            fade.volume = fade.target
            fade.delta = 0
            fade.active = false
            return
        }
        fade.delta = fade.volume < fade.target ? 1 : -1
    }

    /// The fade, and Paula's volume for the voice with it.
    mutating func fadeApply(_ v: Int) {
        if fade.delta != 0 {
            fade.count &-= 1
            if fade.count == 0 {
                fade.count = fade.speed
                fade.volume &+= UInt8(bitPattern: fade.delta)
                if fade.volume == fade.target {
                    fade.delta = 0
                    fade.active = false
                }
            }
        }
        if variant.original != .none {
            paula[v].volume = originalVolume(v, lockHeeded: true)
            return
        }
        var volume = voices[v].volume
        if fade.volume < 64 { volume = Int8(truncatingIfNeeded: (4 * Int(voices[v].volume) * Int(fade.volume)) / (4 * 0x40)) }
        paula[v].volume = UInt16(bitPattern: Int16(volume))
    }

    // MARK: Random play

    /// Random play ($1B) and its mask ($1E): the notes of another macro, taken as a list, played in
    /// turn or at random. Players differ in what they do, and no module uses them.
    mutating func randomPlay(_ v: Int) {
        if voices[v].rndFlag == 0 {
            return
        } else if voices[v].rndFlag > 0 {
            voices[v].arpOffset = getMacroOffset(voices[v].rndMacro)
            voices[v].arpPos = 0
            voices[v].rndFlag = -1
            if voices[v].rndMode & 1 != 0 { randomPlayMask(v) }
        }

        voices[v].rndCount &-= 1
        if voices[v].rndCount == 0 {
            voices[v].rndCount = voices[v].rndSpeed
            while true {
                cmd.aa = byte(voices[v].arpOffset &+ UInt32(voices[v].arpPos))
                if cmd.aa != 0 { break }
                if voices[v].arpPos == 0 { return }
                voices[v].arpPos = 0
            }
        } else {
            randomPlayReverb(v)
            return
        }

        let n = (Int(Int8(bitPattern: cmd.aa)) + Int(voices[v].note)) & 0x3F
        if n == 0 {
            randomPlayMask(v)
            return
        }
        var p = noteToPeriod(n)
        let finetune = voices[v].detune
        if finetune != 0 { p = UInt16(truncatingIfNeeded: ((Int32(finetune) + 0x100) &* Int32(p)) >> 8) }
        if voices[v].rndMode & 1 == 0 {
            voices[v].period = p
            if voices[v].portamentoSpeed != 0 { return }
            voices[v].outputPeriod = p
            randomPlayCheckWait(v)
            voices[v].arpPos &+= 1
            return
        }

        randomize()
        if voices[v].rndMode & 4 != 0 || voices[v].arpPos & 3 != 0 || admin.randomWord & 0xFF > 16 {
            randomPlayCheckWait(v)
            voices[v].period = p
            if voices[v].portamentoSpeed == 0 { voices[v].outputPeriod = p }
        }
        voices[v].arpPos &+= 1
        if cmd.aa & 0x40 == 0 { return }
        randomize()
        if admin.randomWord >> 8 > 6 { randomPlayMask(v) }
    }

    /// An echo on the next voice (from the fourth, the first).
    mutating func randomPlayReverb(_ v: Int) {
        if voices[v].rndMode & 2 == 0 || (Int(voices[v].rndSpeed) * 3) / 8 != Int(voices[v].rndCount) { return }
        let other = Int((voices[v].voiceNum &+ 1) & 3)
        voices[other].volume = Int8(truncatingIfNeeded: (Int(voices[v].volume) * 5) / 8)
        if voices[v].period != voices[other].period {
            voices[other].period = voices[v].period
            voices[other].outputPeriod = voices[v].period
            randomPlayCheckWait(v)
        }
    }

    mutating func randomPlayMask(_ v: Int) {
        randomize()
        voices[v].arpPos = (admin.randomWord & 0xFF) & UInt16(voices[v].rndMask)
    }

    mutating func randomPlayCheckWait(_ v: Int) {
        if cmd.aa & 0x80 != 0 { voices[v].rndBlockWait = false }
    }

    /// The players read the Amiga's raster position for this, each in its own way.
    mutating func randomize() {
        randomState = randomState &* 1_103_515_245 &+ 12345
        let random = UInt16((randomState >> 16) & 0x7FFF)
        admin.randomWord = (admin.randomWord ^ random) &+ 0x4335
    }
}
