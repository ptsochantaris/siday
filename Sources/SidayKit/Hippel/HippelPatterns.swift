// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A port of libtfmxaudiodecoder's reading of the track tables and patterns of Jochen Hippel's players
// and of Future Composer (src/Jochen/TFMX.cpp, COSO.cpp, TFMX7V.cpp and FC.cpp), Copyright (C)
// Michael Schwendt, used under the GPL-2.0-or-later, as it is at its commit dcec102 of 2026-09-26.

extension HippelDecoder {
    // MARK: TFMX

    /// A voice's next row: at the end of its pattern (or a row that says so), the next step of the
    /// track table first.
    mutating func tfmxNextNote<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        let pattOffs = getPattOffs(v)
        if Int(voices[v].pattPos) == traits.patternSize || byte(pattOffs) & 0x7F == 0x01 {
            // Where the step to play is.
            var trackOffs = voices[v].trackStart &+ UInt32(voices[v].trackPos)
            if trackOffs >= voices[v].trackEnd {
                // The end of the song's steps: it goes round.
                voices[v].trackPos = 0
                trackOffs = voices[v].trackStart
                songEnd = true
            }
            // Where the next step will be.
            voices[v].trackPos &+= UInt16(trackStepLen)

            let pattern = byte(trackOffs) // PT
            trackOffs &+= 1
            voices[v].pattStart = offsets.patterns &+ (UInt32(pattern) << 6)
            voices[v].transpose = signedByte(trackOffs) // TR
            trackOffs &+= 1
            voices[v].soundTranspose = signedByte(trackOffs) // ST
            trackOffs &+= 1
            if trackColumnSize == 3, UInt8(bitPattern: voices[v].soundTranspose) == 0x80 {
                // ST $80 stops the player.
                songEnd = true
                stopCommanded = true
            } else if trackColumnSize == 4 {
                sevenVoicesTrackTabCmd(v, trackOffs)
            }
            voices[v].pattPos = 0
        }
        tfmxProcessPattern(v, &out)
    }

    mutating func tfmxProcessPattern<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        var pattOffs = getPattOffs(v)
        let note = byte(pattOffs)
        pattOffs &+= 1
        if note & 0x7F != 0 { // nought: nothing more to do here
            voices[v].pattVal1 = note & 0x7F
            voices[v].pattVal2 = byte(pattOffs)
            voices[v].portaOffs = 0
            // The row before's second byte, but in the same pattern.
            if voices[v].pattPos == 0 {
                voices[v].portaSpeed = signedByte(pattOffs &+ UInt32(truncatingIfNeeded: traits.patternSize) &- 2)
            } else {
                voices[v].portaSpeed = signedByte(pattOffs &- 2)
            }
            if note & 0x80 == 0 {
                // (Some players stop Paula's voice here, as if for new samples, which breaks some
                // modules.) The instrument, and the step's transpose of instruments.
                let instr = Int(voices[v].pattVal2 & 0x1F) + Int(voices[v].soundTranspose)
                setInstrument(v, UInt8(truncatingIfNeeded: instr))
            }
        }
        voices[v].pattPos &+= 2
    }

    // MARK: Compressed TFMX

    /// A voice's next row of a compressed pattern, whose rows are of one to three bytes, and which may
    /// say how many ticks to wait before the next.
    mutating func cosoNextNote<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        voices[v].pattCompressCount &-= 1
        if voices[v].pattCompressCount >= 0 { return }
        voices[v].pattCompressCount = voices[v].pattCompress

        var maxLoops = Self.recurseLimit
        while true {
            maxLoops -= 1
            guard maxLoops >= 0 else { break }
            var pattOffs = getPattOffs(v)
            let pattVal: UInt8
            if voices[v].pattStart == 0xFFFF_FFFF {
                pattVal = 0xFF
            } else {
                pattVal = byte(pattOffs)
                pattOffs &+= 1
            }
            voices[v].pattPos &+= 1

            if pattVal == 0xFF { // the end of the pattern
                // Where the step to play is.
                var trackOffs = voices[v].trackStart &+ UInt32(voices[v].trackPos)
                if trackOffs >= voices[v].trackEnd {
                    voices[v].trackPos = 0
                    trackOffs = voices[v].trackStart
                    songEnd = true
                }
                voices[v].trackPos &+= UInt16(trackStepLen)

                let pattern = byte(trackOffs) // PT
                trackOffs &+= 1
                voices[v].pattStart = offsets.header &+ UInt32(word(offsets.patterns &+ (UInt32(pattern) << 1)))
                voices[v].pattPos = 0
                let oldTrans = voices[v].transpose
                voices[v].transposeNew = signedByte(trackOffs) // TR
                trackOffs &+= 1

                // A new step's transpose is heard at once, in the sound playing too, which in a few
                // modules is wrong: one known to be (`avoidTRglitch`) has a change of an octave or more
                // left until the next note, if that is soon.
                var setTR = true
                if traits.avoidTRglitch, abs(Int(oldTrans) - Int(voices[v].transposeNew)) >= 12 {
                    let c = cosoCountPatternWait(v)
                    if c != 0, c <= 4 { setTR = false }
                }
                if setTR { voices[v].transpose = voices[v].transposeNew }

                let st = byte(trackOffs) // ST
                if trackColumnSize == 4 {
                    voices[v].soundTranspose = signedByte(trackOffs)
                    trackOffs &+= 1
                    sevenVoicesTrackTabCmd(v, trackOffs)
                } else if trackColumnSize == 3, st & 0x80 != 0 {
                    sevenVoicesTrackTabCmd(v, trackOffs)
                } else {
                    voices[v].soundTranspose = signedByte(trackOffs)
                }
            } else if pattVal == 0xFE { // the pattern's speed, and the next row
                voices[v].pattCompressCount = Int8(bitPattern: byte(pattOffs))
                voices[v].pattCompress = voices[v].pattCompressCount
                voices[v].pattPos &+= 1
            } else if pattVal == 0xFD { // the pattern's speed
                voices[v].pattCompressCount = Int8(bitPattern: byte(pattOffs))
                voices[v].pattCompress = voices[v].pattCompressCount
                voices[v].pattPos &+= 1
                return
            } else { // a note
                voices[v].pattVal1 = pattVal
                break
            }
        }
        cosoProcessPattern(v, &out)
    }

    mutating func cosoProcessPattern<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        var pattOffs = getPattOffs(v)
        voices[v].pattVal2 = byte(pattOffs)
        pattOffs &+= 1
        voices[v].pattPos &+= 1
        if voices[v].pattVal2 & 0xE0 != 0 {
            voices[v].portaSpeed = signedByte(pattOffs)
            voices[v].pattPos &+= 1
        }
        voices[v].portaOffs = 0
        if voices[v].pattVal1 & 0x80 == 0 {
            voices[v].transpose = voices[v].transposeNew
            let instr = Int(voices[v].pattVal2 & 0x1F) + Int(voices[v].soundTranspose)
            setInstrument(v, UInt8(truncatingIfNeeded: instr))
        }
    }

    /// How many of a pattern's next eight rows play no note.
    func cosoCountPatternWait(_ v: Int) -> Int {
        var comprCount = 0, compress = 0
        var c = 0
        var po = getPattOffs(v)
        for _ in 0 ..< 8 {
            comprCount -= 1
            if comprCount >= 0 {
                c += 1
                continue
            }
            comprCount = compress
            var maxLoops = Self.recurseLimit
            while true {
                maxLoops -= 1
                guard maxLoops >= 0 else { break }
                let pattVal = byte(po)
                po &+= 1
                if pattVal == 0xFF {
                    return c
                } else if pattVal == 0xFE {
                    compress = Int(byte(po))
                    comprCount = compress
                    po &+= 1
                } else if pattVal == 0xFD {
                    compress = Int(byte(po))
                    comprCount = compress
                    po &+= 1
                    c += 1
                    break
                } else {
                    let pattVal2 = byte(po)
                    po &+= 1
                    if pattVal2 & 0xE0 != 0 { po &+= 1 }
                    if pattVal == 0 {
                        c += 1
                    } else {
                        return c
                    }
                }
            }
        }
        return c
    }

    // MARK: TFMX 7V

    /// A command in a step's last column (TFMX 7V's, or a compressed module's instruments' transpose
    /// with its top bit set): a voice's volume, the rate, the speed, or stop.
    mutating func sevenVoicesTrackTabCmd(_ v: Int, _ trackOffs: UInt32) {
        let val = byte(trackOffs)
        let v1 = val >> 4
        let v2 = val & 0x0F
        if v1 == 0x0F { // the voice's volume
            voices[v].voiceVol = v2 == 0 ? 100 : UInt8((15 - Int(v2) + 1) * 6)
        } else if v1 == 0x0D { // the rate (TFMX 7V only, and not all of it)
            sevenVoicesSetRate(signedByte(trackOffs &+ 2 &* UInt32(trackColumnSize) &- 1))
        } else if v1 == 0x0E { // the speed
            admin.speed = Int16(v2)
        } else if v1 == 0x08 { // stop
            songEnd = true
            stopCommanded = true
        }
    }

    // MARK: Future Composer

    mutating func fcNextNote<Output: TFMXOutput>(_ v: Int, _ out: inout Output) {
        var pattOffs = getPattOffs(v)
        // At the pattern's end, or a row saying so (in Future Composer 1.4), the next step. (The row that
        // says so must be at the same place in the four voices' patterns, for them to stay together.)
        if Int(voices[v].pattPos) == traits.patternSize || (!traits.isSMOD && byte(pattOffs) == Self.fcPatternBreak) {
            var trackOffs = voices[v].trackStart &+ UInt32(voices[v].trackPos)
            voices[v].pattPos = 0
            // (Some players test for being at the end, not beyond it, and can go past the song's end.)
            if trackOffs >= voices[v].trackEnd {
                voices[v].trackPos = 0
                trackOffs = voices[v].trackStart
                songEnd = true
            }
            voices[v].trackPos &+= UInt16(trackStepLen)

            // A step is each voice's pattern, transpose and instruments' transpose, then the speed,
            // which the first voice reads.
            if voices[v].voiceNum == 0 {
                let newSpeed = byte(trackOffs &+ 12)
                if newSpeed != 0 { // nought would count down too far
                    admin.speed = Int16(newSpeed)
                    admin.count = admin.speed
                }
            }
            let pattern = byte(trackOffs) // PT
            trackOffs &+= 1
            voices[v].transpose = signedByte(trackOffs) // TR
            trackOffs &+= 1
            voices[v].soundTranspose = signedByte(trackOffs) // ST
            trackOffs &+= 1
            voices[v].pattStart = offsets.patterns &+ (UInt32(pattern) << 6)
            pattOffs = voices[v].pattStart
        }

        let note = byte(pattOffs)
        pattOffs &+= 1
        let info = byte(pattOffs)
        if note != 0 {
            // A new note ends portamento.
            voices[v].portaSpeed = 0
            voices[v].portaOffs = 0
            voices[v].pattVal1 = note & 0x7F
            prepareChannelUpdate(v, &out)
            // The instrument, and the step's transpose of instruments (masked, against overflow).
            let sound = UInt16(truncatingIfNeeded: Int(info & 0x3F) + Int(voices[v].soundTranspose)) & 0x3F
            setInstrument(v, UInt8(sound))
        }
        // Portamento: bit 7 on, bit 6 off, and its speed in the next row's second byte.
        if info & 0x40 != 0 { voices[v].portaSpeed = 0 }
        if info & 0x80 != 0 { voices[v].portaSpeed = Int8(byte(pattOffs &+ 2) & 0x3F) }
        voices[v].pattPos &+= 2
    }

    static let fcPatternBreak: UInt8 = 0x49
}
