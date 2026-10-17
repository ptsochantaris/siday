// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A port of libtfmxaudiodecoder's envelopes, vibratos and portamentos of Jochen Hippel's players and
// of Future Composer (src/Jochen/Envelope.cpp, Vibrato.cpp and Portamento.cpp), Copyright (C) Michael
// Schwendt, used under the GPL-2.0-or-later, as it is at its commit dcec102 of 2026-09-26.

extension HippelDecoder {
    // MARK: The envelope

    /// The voice's volume for this tick, from its instrument's volume sequence: 0 to 64 from the
    /// sequence, less a random amount in TFMX 7V (which can wrap round to as much as 127), scaled by
    /// the voice's own volume where the player has one.
    mutating func envelope(_ v: Int) -> UInt16 {
        var repeatVolSeq: Bool
        var jumpCount = 0
        repeat {
            repeatVolSeq = false
            if voices[v].volSustainTime != 0 {
                // The volume held.
                voices[v].volSustainTime &-= 1
            } else if traits.volSeqEA, voices[v].volSlideTime != 0 {
                fcVolSlide(v)
            } else if envelopeIsDue(v) {
                // Time for the sequence's next volume.
                voices[v].envelopeCount = voices[v].envelopeSpeed
                var readNextVal: Bool
                repeat {
                    readNextVal = false
                    jumpCount += 1
                    if jumpCount > Self.recurseLimit { break }
                    // The envelope may go on past 64 bytes, and some modules make use of that, though it
                    // may go into whatever follows.
                    let seqOffs = voices[v].volSeq &+ UInt32(voices[v].volSeqPos)
                    let cmd = byte(seqOffs)
                    if cmd == 0xE8 { // sustain
                        voices[v].volSustainTime = byte(seqOffs &+ 1)
                        if voices[v].volSustainTime == 0 { voices[v].volSustainTime = 1 } // nought makes no sense
                        voices[v].volSeqPos &+= 2
                        repeatVolSeq = true
                        break
                    } else if traits.volSeqEA, cmd == 0xEA { // volume slide
                        voices[v].volSlideSpeed = byte(seqOffs &+ 1)
                        voices[v].volSlideTime = byte(seqOffs &+ 2)
                        voices[v].volSeqPos &+= 3
                        fcVolSlide(v)
                        break
                    } else if cmd == 0xE0 { // loop, to 5 to $3F, past the instrument's header
                        voices[v].volSeqPos = UInt16(byte(seqOffs &+ 1) & 0x3F)
                        if voices[v].volSeqPos >= 5 {
                            voices[v].volSeqPos -= 5
                        } else {
                            voices[v].volSeqPos = 0
                        }
                        // (Some Future Composer players read no value at the new place here.)
                        readNextVal = true
                    } else if cmd == 0xE1 { // the end
                        break
                    } else { // a volume
                        voices[v].volume = Int8(bitPattern: cmd)
                        if voices[v].envelopeSpeed != 0 { voices[v].volSeqPos &+= 1 }
                        if voices[v].volume > 64 {
                            voices[v].volume = 64
                        } else if voices[v].volume < 0 {
                            voices[v].volume = 0
                        }
                        break
                    }
                } while readNextVal
            }
        } while repeatVolSeq

        if traits.randomVolume, voices[v].volRandomThreshold != 0 {
            if voices[v].volRandomCurrent == 0 {
                let t = voices[v].volRandomThreshold
                voices[v].volRandomThreshold = 0
                let w = randomWord &+ 0x4793
                randomWord = w ^ (w >> 6 | w << 10) // ROR #6, then EOR with itself
                voices[v].volRandomCurrent = UInt8((Int(randomWord & 0xFF) * Int(t)) / 0xFF)
            }
            voices[v].volume = Int8(truncatingIfNeeded: Int(voices[v].volume) - Int(voices[v].volRandomCurrent))
            if voices[v].volume < 0 { voices[v].volume = 0 }
        }

        if traits.voiceVolume {
            return UInt16(truncatingIfNeeded: (Int(voices[v].volume) * Int(voices[v].voiceVol)) / 100)
        }
        return UInt16(truncatingIfNeeded: Int(voices[v].volume))
    }

    /// Whether the envelope's count has come round. (A speed of nought, which makes no sense, has the
    /// sequence read every tick, and does not move it on: see `envelope`.)
    mutating func envelopeIsDue(_ v: Int) -> Bool {
        if voices[v].envelopeSpeed == 0 { return true }
        voices[v].envelopeCount &-= 1
        return voices[v].envelopeCount == 0
    }

    /// Future Composer's volume slide, at half its speed.
    mutating func fcVolSlide(_ v: Int) {
        voices[v].volSlideDelayFlag ^= 0xFF
        if voices[v].volSlideDelayFlag != 0 {
            voices[v].volSlideTime &-= 1
            voices[v].volume = Int8(truncatingIfNeeded: Int(voices[v].volume) + Int(voices[v].volSlideSpeed))
            if voices[v].volume < 0 {
                voices[v].volume = 0
                voices[v].volSlideTime = 0
            }
            // (Most players do not keep it to Paula's 64.)
            if voices[v].volume > 64 {
                voices[v].volume = 64
                voices[v].volSlideTime = 0
            }
        }
    }

    // MARK: Vibrato

    /// TFMX's vibrato, which Future Composer copied: up and down by its speed between nought and twice
    /// its amplitude, doubled for each octave below the fifth (`vibScaling`). Later TFMX players take a
    /// speed with its top bit set to mean half speed (`vibSpeedFlag`); the earlier ones' half speed
    /// never worked, and is left out.
    mutating func tfmxVibrato(_ v: Int, _ period: UInt16, _ note: UInt8) -> UInt16 {
        if voices[v].vibDelay != 0 {
            voices[v].vibDelay &-= 1
            return period
        }
        var offs = Int16(voices[v].vibCurOffs)
        var speed = voices[v].vibSpeed
        if traits.vibSpeedFlag, speed & 0x80 != 0 {
            speed &= 0x7F
            voices[v].vibFlag ^= 0x01 // bit 0 says when to move
        }
        if voices[v].vibFlag & 0x01 == 0 {
            // From nought to twice the amplitude, less the amplitude.
            let vibDelta = Int16(truncatingIfNeeded: Int(voices[v].vibAmpl) << 1)
            if voices[v].vibFlag & (1 << 5) == 0 { // down
                offs = Int16(truncatingIfNeeded: Int(offs) - Int(speed))
                if offs < 0 {
                    offs = 0
                    voices[v].vibFlag |= 1 << 5 // up
                }
            } else { // up
                offs = Int16(truncatingIfNeeded: Int(offs) + Int(speed))
                if offs > vibDelta {
                    offs = vibDelta
                    voices[v].vibFlag &= ~(1 << 5) // down
                }
            }
            voices[v].vibCurOffs = UInt8(truncatingIfNeeded: offs)
        }
        offs = Int16(truncatingIfNeeded: Int(offs) - Int(voices[v].vibAmpl))
        // Doubled for each octave below the fifth (the period table's 48th note and on).
        if traits.vibScaling {
            var n = note &+ 80
            while n < 128 {
                offs = offs &+ offs
                n &+= 12
            }
        }
        return UInt16(truncatingIfNeeded: Int(period) + Int(offs))
    }

    /// The compressed modules' vibrato: half the amplitude, as 1024ths of the period, and no half speed.
    mutating func cosoVibrato(_ v: Int, _ period: UInt16) -> UInt16 {
        if voices[v].vibDelay != 0 {
            voices[v].vibDelay &-= 1
            return period
        }
        var offs = Int16(voices[v].vibCurOffs)
        if voices[v].vibFlag & (1 << 5) == 0 { // down
            offs = Int16(truncatingIfNeeded: Int(offs) - Int(voices[v].vibSpeed))
            if offs < 0 {
                offs = 0
                voices[v].vibFlag |= 1 << 5
            }
        } else { // up
            offs = Int16(truncatingIfNeeded: Int(offs) + Int(voices[v].vibSpeed))
            if offs > Int16(voices[v].vibAmpl) {
                offs = Int16(voices[v].vibAmpl)
                voices[v].vibFlag &= ~(1 << 5)
            }
        }
        voices[v].vibCurOffs = UInt8(truncatingIfNeeded: offs)
        offs = Int16(truncatingIfNeeded: Int(offs) - Int(voices[v].vibAmpl >> 1))
        // In 1024ths of the period (the product cut to sixteen bits, as the library's is).
        offs = Int16(truncatingIfNeeded: Int(offs) * Int(period))
        offs >>= 10
        return UInt16(truncatingIfNeeded: Int(period) + Int(offs))
    }

    // MARK: Portamento

    /// TFMX's portamento: bit 5 of the note's second byte on (bit 6 in MCMD), the period slid by the
    /// speed from the row before, in 32nds of a period a tick (256ths, `portaWeaker`).
    mutating func tfmxPortamento(_ v: Int, _ period: UInt16) -> UInt16 {
        let on = traits.portaIsBit6 ? voices[v].pattVal2 & 0x40 != 0 : voices[v].pattVal2 & 0x20 != 0
        guard on else { return period }
        let speed = Int(voices[v].portaSpeed)
        let x = UInt32(truncatingIfNeeded: abs(speed))
        let step = traits.portaWeaker ? x << 8 : x << 11
        voices[v].portaOffs = Int32(bitPattern: UInt32(bitPattern: voices[v].portaOffs) &+ step)
        let delta = Int(voices[v].portaOffs >> 16)
        return UInt16(truncatingIfNeeded: speed < 0 ? Int(period) + delta : Int(period) - delta)
    }

    /// The compressed modules' portamento: in 1024ths of the period.
    mutating func cosoPortamento(_ v: Int, _ period: UInt16) -> UInt16 {
        guard voices[v].pattVal2 & 0x20 != 0 else { return period }
        let speed = Int32(voices[v].portaSpeed)
        voices[v].portaOffs = voices[v].portaOffs &+ (speed < 0 ? -speed : speed)
        let x = UInt32(period) &* UInt32(truncatingIfNeeded: 0xFFFF & voices[v].portaOffs)
        return UInt16(truncatingIfNeeded: speed < 0 ? UInt32(period) &+ (x >> 10) : UInt32(period) &- (x >> 10))
    }

    /// Future Composer's portamento (at half speed in 1.4), and its pitch bend (at half speed too).
    mutating func fcPortamentoPitchbend(_ v: Int, _ period: UInt16) -> UInt16 {
        voices[v].portaDelayFlag = ~voices[v].portaDelayFlag
        if traits.isSMOD || voices[v].portaDelayFlag != 0 {
            var x = voices[v].portaSpeed
            if x != 0 {
                if x > 0x1F { // from $20, down
                    x &= 0x1F
                    x = -x
                }
                voices[v].portaOffs &-= Int32(x)
            }
        }
        voices[v].pitchBendDelayFlag ^= 0xFF
        if voices[v].pitchBendDelayFlag != 0, voices[v].pitchBendTime != 0 {
            voices[v].pitchBendTime &-= 1
            let speed = voices[v].pitchBendSpeed
            if speed != 0 { voices[v].portaOffs &-= Int32(speed) }
        }
        return UInt16(truncatingIfNeeded: Int(period) + Int(voices[v].portaOffs))
    }
}
