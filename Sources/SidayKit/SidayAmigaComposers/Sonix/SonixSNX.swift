// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the 68000 code of Mark Riley's Sonix Music Driver 2.3c, as Wanted Team's player for
// EaglePlayer carries it for SNX scores (see `SonixPlayer`). The labels given are that player's source's.

/// The player of SNX scores, Sonix Music Driver 2.3c, from Dynamix's Rise of the Dragon.
///
/// Its variables, at `Sonix` (A6): 0 the tempo, 2 the pitch ($80 for none), 4 the score playing, 8
/// whether it plays, $A where it starts, $E how far it has come and $12 where it ends (-1, never); $2E
/// a count of ticks, $30 the tempo the timer was last set for and $32 the rate the envelopes go at for
/// it ($4B0000 over the tempo); for each track, $38 its bend (its low byte) and $48 a period it is held
/// at; $57 and $58, the notes and tracks a game has taken over; eight volumes ramped at $5A, to $6A, by
/// $7A; the instruments at $8A, 64 of six bytes; the four voices at $20A, $54 bytes each; for each
/// track, its instrument at $35A, its count of ticks at $36A and where it is reading at $3B2, its state
/// at the start at $37A ($3AE as it is begun again); and the chip memory at $3E2.
///
/// The score (`Buffer2`, `InitScore`): 2 its tempo, 4 its transpose ($80 none), 6 its instrument if a
/// track has none, at 12 a word for each track (its volume, $FF), at $1A each track's place, and at $2A
/// the numbers of the 64 instruments (one more than their places in the table).
///
/// A track's events are words: a note ($nnvv: note nn at velocity vv, a velocity of nought letting it
/// go), a command ($80 the instrument, $81 the track's volume, $82 the tempo, $83 the bend), a wait
/// ($C000 and the number of ticks), or $FFFF, the end.
extension SonixPlayer {
    /// A voice, by its offsets from the voice's place (`$20A(A6)` and on).
    private func voiceAt(_ v: Int) -> UInt32 { sonixAt &+ 0x20A &+ 0x54 &* UInt32(v & 0xFFFF) }

    /// `InitScore`: the score set out in `Buffer2`: its tempo and pitch, from the file's words at $10
    /// and $12, a transpose of $80 (none), each track's place, and its volume, $FF.
    mutating func initScore() {
        let a5 = scoreAt
        setWord(a5, word(moduleAt &+ 0x10))
        setWord(a5 &+ 2, word(moduleAt &+ 0x12))
        setWord(a5 &+ 4, 0x80)
        var track = moduleAt &+ 0x14
        for t in 0 ..< UInt32(4) {
            setLong(a5 &+ 0x1A &+ 4 &* t, track)
            track &+= long(moduleAt &+ 4 &* t)
            setByte(a5 &+ 13 &+ 4 &* t, 0xFF)
        }
    }

    /// `PlayScore` (for `InitSound`, from nought to -1, for ever): the score's state at its start found
    /// and taken, the four volumes ramped to nought and then at once to full.
    mutating func playSNXScore() {
        stopSNXScore()
        let score = scoreAt
        setS(0xA, long: 0)
        setS(0x12, long: 0xFFFF_FFFF)
        setS(0, word: word(score &+ 2))
        findStart(score)
        beginAgain(score)
        setS(4, long: score)
        setS(0x2E, word: 0)
        rampVolume(ticks: 0, to: 0, mask: 15)
        rampVolume(ticks: 0, to: 0xFF, mask: 15)
        setS(8, word: 0xFFFF)
    }

    /// `StopScore` (`lbC01E5FE`): if it plays, the notes of the tracks the game has not taken over let go.
    private mutating func stopSNXScore() {
        guard sWord(8) != 0 else { return }
        setS(8, word: 0)
        for v in 0 ..< 4 where sByte(0x58) & 1 << v == 0 { releaseSNXNote(v) }
    }

    /// `lbC01E632`: what each track is at the score's start (here always its first event): where it
    /// reads ($37E), its count of ticks ($38E), its instrument plus one ($39E), volume ($39F) and bend
    /// ($3A0), and at $37C the tempo; a track that is empty is left out of $37A's mask.
    private func findStart(_ score: UInt32) {
        let s = sonixAt
        setWord(s &+ 0x37C, 0)
        setByte(s &+ 0x37A, 15)
        let start = sLong(0xA)
        for v in 0 ..< UInt32(4) {
            let a1 = s &+ 0x37A &+ 4 &* v
            setWord(a1 &+ 0x14, 0)
            setByte(a1 &+ 0x24, 0)
            setByte(a1 &+ 0x26, 0)
            setByte(a1 &+ 0x25, 0xFF)
            var a2 = long(score &+ 0x1A &+ 4 &* v)
            var ended = a2 == 0
            var d5 = Int32(bitPattern: start)
            // (Reading stops where the start is reached, here at once.)
            var guardCount = 0
            while !ended {
                setLong(a1 &+ 4, a2)
                let d0 = word(a2)
                a2 &+= 2
                if d0 == 0xFFFF {
                    ended = true
                    break
                }
                if d5 <= 0 { break }
                guardCount &+= 1
                if guardCount > 0x10_0000 { break }
                guard d0 & 0x8000 != 0 else { continue }
                if d0 < 0x8100 {
                    setByte(a1 &+ 0x24, UInt8(truncatingIfNeeded: d0 &+ 1))
                } else if d0 < 0x8200 {
                    setByte(a1 &+ 0x25, UInt8(truncatingIfNeeded: d0))
                } else if d0 < 0x8300 {
                    setByte(s &+ 0x37D, UInt8(truncatingIfNeeded: d0))
                } else if d0 < 0x8400 {
                    setByte(a1 &+ 0x26, UInt8(truncatingIfNeeded: d0))
                } else if d0 >= 0xC000 {
                    d5 = d5 &- Int32(d0 & 0x3FFF)
                    if d5 < 0 { setWord(a1 &+ 0x14, UInt16(truncatingIfNeeded: 0 &- d5)) }
                }
            }
            if ended {
                setLong(a1 &+ 4, 0)
                setByte(s &+ 0x37A, byte(s &+ 0x37A) & ~UInt8(1 << v))
            }
        }
    }

    /// `lbC01E6E2`: the score begun again from its start as `findStart` found it: the tempo, each
    /// track's place, count, instrument, volume and bend, its note let go.
    private mutating func beginAgain(_ score: UInt32) {
        let s = sonixAt
        for i in 0 ..< UInt32(52) { setByte(s &+ 0x3AE &+ i, byte(s &+ 0x37A &+ i)) }
        let tempo = sWord(0x3B0)
        if tempo != 0 { setS(0, word: tempo) }
        setS(0xE, long: sLong(0xA))
        for v in 0 ..< UInt32(4) {
            if sByte(0x58) & 1 << v == 0 { releaseSNXNote(Int(v)) }
            setS(0x36A &+ 4 &* v, long: UInt32(sWord(0x3C2 &+ 4 &* v) &+ 1))
            var instrument: UInt32 = 0
            let number = sByte(0x3D2 &+ 4 &* v)
            if number != 0 {
                let n = byte(score &+ 0x2A &+ UInt32(number &- 1))
                if n != 0 { instrument = s &+ 0x8A &+ 6 &* UInt32(n &- 1) }
            }
            setS(0x35A &+ 4 &* v, long: instrument)
            setByte(score &+ 13 &+ 4 &* v, sByte(0x3D3 &+ 4 &* v))
            setS(0x39 &+ 4 &* v, byte: sByte(0x3D4 &+ 4 &* v))
        }
    }

    /// The interrupt (`PlaySNX`): the volumes ramped, notes a game held let go, the score's tick, then
    /// the instruments'.
    mutating func playSNX() {
        rampTick()
        heldNotes()
        scoreTick()
        instrumentsTick()
    }

    /// `lbC01E798`: the timer set for a tempo, if it is another: `Clock` over it (`SetTimer`), and the
    /// rate the envelopes go at, $4B0000 over it (a quotient too big for a word left undone, its
    /// lower word, nought, taken). For a tempo of nought, for which the 68000 would stop, nothing.
    private mutating func setTempo(_ tempo: UInt16) {
        guard tempo != sWord(0x30) else { return }
        setS(0x30, word: tempo)
        guard tempo != 0, let timer = Self.divideClock(by: UInt32(tempo)) else { return }
        latch = timer
        let rate = 0x4B_0000 / UInt32(tempo)
        setS(0x32, word: UInt16(truncatingIfNeeded: rate > 0xFFFF ? 0x4B_0000 : rate))
        setS(0x34, word: 1)
    }

    /// `lbC01E7DA`: the score's tick. Each track counts down its wait; when it is done, its events are
    /// read up to its next wait (`lbC01E820`): notes started and let go, its instrument, volume, bend
    /// and the tempo set. When all four have ended, the song has come to its end and is begun again.
    private mutating func scoreTick() {
        if sWord(0x2E) != 0 {
            setS(0x2E, word: sWord(0x2E) &- 1)
            if sWord(0x2E) != 0 { return }
        }
        setTempo(sWord(0))
        setS(0x2E, word: sWord(0x34))
        guard sWord(8) != 0 else { return }
        let score = sLong(4)
        var ended: UInt16 = 0
        var rounds = 0
        while true {
            rounds &+= 1
            for v in 0 ..< UInt32(4) {
                let count = sLong(0x36A &+ 4 &* v)
                if count != 0 {
                    setS(0x36A &+ 4 &* v, long: count &- 1)
                    if count &- 1 != 0 { continue }
                }
                if readTrack(Int(v), score: score) { ended &+= 1 }
            }
            let position = sLong(0xE)
            setS(0xE, long: position &+ 1)
            let end = sLong(0x12)
            if Int32(bitPattern: end) >= 0 {
                guard position == end else { return }
            } else {
                guard ended == 4 else { return }
            }
            // (Begun again in the same tick; were it to end at once again, as a score of empty tracks
            // would, it is not begun a third time, as the player's count of ended tracks has passed four.)
            songEnded()
            beginAgain(score)
            ended &+= 1
            if rounds > 1 { return }
        }
    }

    /// A track's events read, up to its next wait or its end (`lbC01E818` to `lbC01E874`). Returns
    /// true if it has ended, or has none.
    private mutating func readTrack(_ v: Int, score: UInt32) -> Bool {
        let s = sonixAt
        let o = 4 &* UInt32(v)
        var events = 0
        while true {
            let place = sLong(0x3B2 &+ o)
            if place == 0 { return true }
            var a0 = place
            var d2: UInt16 = 0
            repeat {
                d2 = word(a0)
                a0 &+= 2
                events &+= 1
            } while d2 == 0 && events < Self.mostEvents
            // (A track that reads on through more than `mostEvents` events in a tick, which the player
            // would read through memory for ever, is taken to have ended.)
            if d2 == 0xFFFF || events >= Self.mostEvents {
                setS(0x3B2 &+ o, long: 0)
                return true
            }
            setS(0x3B2 &+ o, long: a0)
            if d2 >= 0xC000 {
                let wait = d2 & 0x3FFF
                if wait == 0 { continue }
                setS(0x36C &+ o, word: wait)
                return false
            }
            let command = UInt8(d2 >> 8)
            let d3 = UInt16(d2 & 0xFF)
            if command & 0x80 == 0 {
                guard sByte(0x58) & 1 << v == 0 else { continue }
                if d3 == 0 {
                    releaseSNXNote(v)
                    continue
                }
                var instrument = sLong(0x35A &+ o)
                if instrument == 0 { instrument = long(score &+ 6) }
                guard instrument != 0 else { continue }
                let note = UInt16(bitPattern: Int16(bitPattern: word(score &+ 4)) >> 4) &- 8 &+ UInt16(command)
                // The volume: the track's (one more) times twice the velocity and one, over 256, of the
                // product's lower word.
                let product = UInt32(word(score &+ 12 &+ o) &+ 1) &* UInt32(d3 &* 2 &+ 1)
                let volume = UInt16(truncatingIfNeeded: product) >> 8
                startSNXNote(entry: instrument, voice: v, note: note, volume: volume, flags: 0)
                continue
            }
            switch command {
            case 0x80:
                var instrument: UInt32 = 0
                let n = byte(score &+ 0x2A &+ UInt32(d3))
                if n != 0 { instrument = s &+ 0x8A &+ 6 &* UInt32(n &- 1) }
                setS(0x35A &+ o, long: instrument)
            case 0x81: setByte(score &+ 13 &+ o, UInt8(d3))
            case 0x82:
                setS(0, word: d3)
                setTempo(d3)
            case 0x83: setS(0x39 &+ o, byte: UInt8(d3))
            default: break
            }
        }
    }

    /// The most events a track is read through in a tick: far more than any score has between its waits.
    static let mostEvents = 4096

    /// `StartNote`: the instrument (an entry of the table, its first long its place) given to the voice,
    /// stopping what it played if that was of another kind; its note, volume and marks kept, its held
    /// period let go, and the note to be begun.
    private mutating func startSNXNote(entry: UInt32, voice v: Int, note: UInt16, volume: UInt16, flags: UInt8) {
        guard entry != 0 else { return }
        let info = long(entry)
        guard info != 0 else { return }
        let a1 = voiceAt(v)
        if byte(a1 &+ 1) != 0, long(info) != long(long(a1 &+ 4)) { stopSNXNote(v) }
        setLong(a1 &+ 4, info)
        setWord(a1 &+ 2, note)
        setWord(a1 &+ 8, volume & 0xFF)
        setByte(a1 &+ 10, flags)
        setS(0x48 &+ 4 &* UInt32(v), word: 0)
        setLong(a1 &+ 0x1C, 0xFFFF_FFFF)
        setByte(a1, 1)
    }

    /// `ReleaseNote`: a voice that plays told to let its note go.
    private func releaseSNXNote(_ v: Int) {
        let a1 = voiceAt(v)
        setByte(a1, 0)
        if byte(a1 &+ 1) == 1 { setByte(a1, 2) }
    }

    /// `StopNote`: the voice stopped, its sound turned off.
    private mutating func stopSNXNote(_ v: Int) {
        let a1 = voiceAt(v)
        setByte(a1, 0)
        setLong(a1 &+ 0x1C, 0)
        if byte(a1 &+ 1) != 0 {
            setByte(a1 &+ 1, 0)
            silence(v)
        }
    }

    /// `lbC01EA46`: the voice's DMA turned off, and its period set to 2.
    private mutating func silence(_ v: Int) {
        pokeDMA(1 << UInt16(v))
        pokePeriod(v, 2)
    }

    /// `RampVolume`: the volumes of `mask` (of the eight) ramped to `to` (in 256ths), over `ticks`
    /// (nought for at once).
    private func rampVolume(ticks: UInt16, to: UInt8, mask: UInt8) {
        let target = UInt16(to) << 8
        for i in 0 ..< UInt32(8) where mask & 1 << i != 0 {
            var step: UInt16 = 0
            if ticks == 0 {
                setS(0x5A &+ 2 &* i, word: target)
            } else {
                setS(0x6A &+ 2 &* i, word: target)
                let now = sWord(0x5A &+ 2 &* i)
                let apart = now >= target ? now &- target : target &- now
                step = UInt16(UInt32(apart) / UInt32(ticks))
                if step == 0 { step = 1 }
            }
            setS(0x7A &+ 2 &* i, word: step)
        }
    }

    /// `lbC01EAB8`: each volume ramped a step towards its target, the step times the rate.
    private func rampTick() {
        let rate = UInt32(sWord(0x32))
        for i in 0 ..< UInt32(8) {
            let step = UInt32(sWord(0x7A &+ 2 &* i))
            guard step != 0 else { continue }
            var now = sWord(0x5A &+ 2 &* i)
            let doubled = UInt64(step &* rate) &* 2
            var done = doubled > 0xFFFF_FFFF
            if !done {
                let d0 = UInt16(truncatingIfNeeded: doubled >> 16)
                var d3 = d0
                var d2 = sWord(0x6A &+ 2 &* i) &- now
                if sWord(0x6A &+ 2 &* i) < now {
                    d3 = 0 &- d3
                    d2 = 0 &- d2
                }
                if d0 >= d2 {
                    done = true
                } else {
                    now = now &+ d3
                }
            }
            if done {
                setS(0x7A &+ 2 &* i, word: 0)
                now = sWord(0x6A &+ 2 &* i)
            }
            setS(0x5A &+ 2 &* i, word: now)
        }
    }

    /// `lbC01EB14`: a note a game took a track over for, let go when it has run its length.
    private mutating func heldNotes() {
        for v in 0 ..< 4 {
            guard sByte(0x57) & 1 << v != 0, long(voiceAt(v) &+ 0x1C) == 0 else { continue }
            releaseSNXNote(v)
            setS(0x58, byte: sByte(0x58) & ~UInt8(1 << v))
            setS(0x57, byte: sByte(0x57) & ~UInt8(1 << v))
        }
    }

    /// `lbC01E996`: each voice's instrument run for the tick (its tech's first routine), the voice then
    /// playing or let go as it was told; then each that plays told Paula what it is to play (its tech's
    /// second), and those begun turned on.
    private mutating func instrumentsTick() {
        for v in 0 ..< 4 {
            let a1 = voiceAt(v)
            guard byte(a1) != 0 || byte(a1 &+ 1) != 0 else { continue }
            var state: UInt8 = 0
            let info = long(a1 &+ 4)
            if info != 0 {
                switch Tech(rawValue: long(info)) {
                case .synthesised: snxSynthesised(v)
                case .sampled: snxSampled(v)
                case .iff: snxIFF(v)
                case .aiff: snxAIFF(v)
                case nil: break
                }
                let command = byte(a1)
                if command == 1 {
                    state = 1
                } else if command == 2 {
                    state = 2
                } else {
                    setByte(a1, 0)
                    continue
                }
            }
            setByte(a1 &+ 1, state)
            setByte(a1, 0)
        }
        var on: UInt16 = 0x8000
        for v in 0 ..< 4 {
            let a1 = voiceAt(v)
            guard byte(a1 &+ 1) != 0 else { continue }
            switch Tech(rawValue: long(long(a1 &+ 4))) {
            case .synthesised:
                // `lbC01EBE8`: its buffer, period and volume; turned on at its note's start.
                pokeAddress(v, long(a1 &+ 12))
                pokeLength(v, word(a1 &+ 0x10))
                pokePeriod(v, word(a1 &+ 0x18))
                pokeVolume(v, word(a1 &+ 0x1A))
                if byte(a1 &+ 10) != 0 {
                    setByte(a1 &+ 10, 0)
                    on |= 1 << UInt16(v)
                }
            case .sampled, .iff, .aiff:
                // `lbC01E286`: the sample's start, once, turned on; the next tick its loop; and its period
                // and volume.
                let start = long(a1 &+ 12)
                if start != 0 {
                    setLong(a1 &+ 12, 0)
                    pokeLength(v, word(a1 &+ 0x10))
                    pokeAddress(v, start)
                    on |= 1 << UInt16(v)
                } else {
                    let loop = long(a1 &+ 0x12)
                    if loop != 0 {
                        setLong(a1 &+ 0x12, 0)
                        pokeLength(v, word(a1 &+ 0x16))
                        pokeAddress(v, loop)
                    }
                }
                pokePeriod(v, word(a1 &+ 0x18))
                pokeVolume(v, word(a1 &+ 0x1A))
            case nil: break
            }
        }
        pokeDMA(on)
    }

    // MARK: Shared by the instruments

    /// `lbC01E2C0`: a sample's place for Paula: its start, played for the first part and the loop's
    /// length (in bytes), the loop then; a sample with no loop then plays `Empty`'s eight bytes, and
    /// runs its length (`$1C`, for `noteRun`). A note marked to (its first mark) starts at the loop.
    private func placeSample(_ voice: UInt32, base: UInt32, first d0in: UInt32, loop d1: UInt32) {
        var a2 = base
        var d2 = d0in &+ d1
        var a0 = base &+ d0in
        var d0 = d1
        if d1 == 0 {
            a0 = long(sonixAt &+ 0x3E2) &+ 0x400
            d0 = 8
        }
        if byte(voice &+ 10) & 1 != 0 {
            a2 = a0
            d2 = d0
        }
        if d1 == 0 { setLong(voice &+ 0x1C, d2) }
        setLong(voice &+ 12, a2)
        setWord(voice &+ 0x10, UInt16(truncatingIfNeeded: d2 >> 1))
        setLong(voice &+ 0x12, a0)
        setWord(voice &+ 0x16, UInt16(truncatingIfNeeded: d0 >> 1))
    }

    /// `lbC01E308`: the voice's volume times its ramp (the track's, or for a track a game has taken
    /// over, the game's), in the upper word.
    private func rampedVolume(_ v: Int, _ voice: UInt32) -> UInt16 {
        var i = UInt32(v)
        if sByte(0x58) & 1 << v != 0 { i &+= 4 }
        let product = UInt32(sWord(0x5A &+ 2 &* i)) &* ((UInt32(word(voice &+ 8)) &+ 1) & 0xFFFF)
        return UInt16(truncatingIfNeeded: product >> 16)
    }

    /// `lbC01E328`: the period as the track bends it (command $83, of `SonixTables.bends`), or as it
    /// is held (`$48`).
    private func bentPeriod(_ v: Int, _ d0: UInt32) -> UInt16 {
        let o = 4 &* UInt32(v)
        let held = sWord(0x48 &+ o)
        if held != 0 { return held }
        let bend = sWord(0x38 &+ o)
        guard bend != 0 else { return UInt16(truncatingIfNeeded: d0) }
        var d1 = bend & 0xFF00 | UInt16(UInt8(truncatingIfNeeded: bend) &+ 0x80)
        d1 >>= 2
        let factor = SonixTables.bends.indices.contains(Int(d1)) ? UInt32(SonixTables.bends[Int(d1)]) : UInt32(word(0))
        let product = (d0 & 0xFFFF) &* factor
        return UInt16(truncatingIfNeeded: (product &<< 1) >> 16)
    }

    /// `lbC01E35C`: a note that runs its length (a sample with no loop) counted down, by $E90B over its
    /// period times the rate. (A period of nought, by which the 68000 would stop, counts nothing.)
    private func noteRun(_ voice: UInt32, period: UInt16) {
        let left = Int32(bitPattern: long(voice &+ 0x1C))
        guard left > 0, period != 0 else { return }
        let q = UInt32(0xE90B) / UInt32(period)
        let d1 = ((q &* UInt32(sWord(0x32))) &<< 1) >> 16
        var d2 = left &- Int32(d1)
        if d2 < 0 { d2 = 0 }
        setLong(voice &+ 0x1C, UInt32(bitPattern: d2))
    }

    /// The envelope of a synthesised or sampled sound (`lbC01ED76`, `lbC01F390`): of its four phases (0
    /// to 6, in steps of 2; 6 is its release), each a level (`levels` on from the instrument's start)
    /// and a rate (`rates` on), its value (a long, its level in the upper word) moved towards the
    /// phase's level, and on to the next phase but the last two when there. A value of nought ends a
    /// note that runs its length.
    private func envelopeStep(info: UInt32, phaseAt: UInt32, valueAt: UInt32, levels: UInt32, rates: UInt32, voice: UInt32?) {
        let phase = word(phaseAt)
        let a0 = info &+ UInt32(bitPattern: Int32(Int16(bitPattern: phase)))
        let d1 = UInt32(word(a0 &+ levels)) << 16
        var d2 = long(valueAt)
        let rate = word(a0 &+ rates)
        let shift = (rate >> 5 ^ 7) & 0x3F
        let scaled = ((UInt32(rate & 0x1F) &+ 0x21) &* UInt32(sWord(0x32))) &<< 3
        let step = shift >= 32 ? 0 : scaled >> UInt32(shift)
        var apart = Int32(bitPattern: d1 &- d2)
        if apart < 0 { apart = 0 &- apart }
        if apart <= Int32(bitPattern: step) {
            d2 = d1
            if Int16(bitPattern: phase) < 4 { setWord(phaseAt, phase &+ 2) }
        } else if Int32(bitPattern: d2) >= Int32(bitPattern: d1) {
            d2 = d2 &- step
        } else {
            d2 = d2 &+ step
        }
        setLong(valueAt, d2)
        if d2 == 0, let voice { setLong(voice &+ 0x1C, 0) }
    }

    // MARK: The synthesised instrument (`SyntTech`)

    /// `lbC01EC0E`: a synthesised instrument's tick, its state at $20 of the voice: 0 its period, 2 and 4
    /// a slide to the note (its ticks and step), 6 which of its two buffers it writes, 8 the octave it
    /// plays in, 10 its envelope's phase and 12 its value, $10 its vibrato's place in its table, $12 the
    /// ticks before it starts and $14 its value, $16 and $18 its phase's movement. A note is begun
    /// (sliding from the last, if the instrument says to), the vibrato and envelope move, the period is
    /// worked out and halved into the octave Paula plays it in, and the waveform written into a buffer:
    /// through the filter the envelope and vibrato choose, its phase moved if the instrument says.
    private mutating func snxSynthesised(_ v: Int) {
        let s = sonixAt
        let a1 = voiceAt(v)
        let a3 = long(a1 &+ 4)
        let a2 = a1 &+ 0x20
        let rate = UInt32(sWord(0x32))
        let command = byte(a1)
        if command == 1 {
            let note = word(a1 &+ 2)
            if Int16(bitPattern: note) < 0x24 || Int16(bitPattern: note) >= 0x6C {
                setByte(a1, 0)
                setLong(a1 &+ 0x1C, 0)
                if byte(a1 &+ 1) == 0 { return }
            } else {
                let d1 = note &- 0x24
                if byte(a1 &+ 1) == 0 { setLong(a2 &+ 12, 0) }
                if byte(a1 &+ 1) != 1 {
                    setWord(a2 &+ 10, 0)
                    if byte(a1 &+ 10) & 1 != 0 {
                        setWord(a2 &+ 10, 4)
                        setLong(a2 &+ 12, long(a3 &+ 0x1CA) & 0xFFFF_0000)
                    }
                }
                let octave = UInt32(d1 / 12), step = Int(d1 % 12)
                var d0 = (UInt32(0xD5C8) &* UInt32(SonixTables.semitones[step])) >> ((octave &+ 0x11) & 31)
                if word(a2) == 0 {
                    setWord(a2 &+ 2, 0)
                } else {
                    // A slide from the last note: its ticks, from the instrument's time, and its step.
                    let d1s = Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: d0) &- word(a2)))
                    var ticks = Self.divide((UInt32(word(a3 &+ 0x1B2)) << 15), by: rate)
                    ticks = (ticks >> 3) &+ 1
                    setWord(a2 &+ 2, ticks)
                    let stepWord: UInt16
                    let q = d1s / Int32(Int16(bitPattern: ticks))
                    if ticks == 0 || q < -32768 || q > 32767 {
                        // (A quotient too big for a word is not made: the dividend's lower word.)
                        stepWord = UInt16(truncatingIfNeeded: d1s)
                    } else {
                        stepWord = UInt16(truncatingIfNeeded: q)
                    }
                    setWord(a2 &+ 4, stepWord)
                    let back = UInt32(stepWord) &* UInt32(ticks)
                    d0 = d0 & 0xFFFF_0000 | UInt32(UInt16(truncatingIfNeeded: d0) &- UInt16(truncatingIfNeeded: back))
                }
                setWord(a2, UInt16(truncatingIfNeeded: d0))
                setWord(a2 &+ 0x18, 1)
                if word(a3 &+ 0x1C2) == 0 { setWord(a2 &+ 0x16, 0) }
                setWord(a2 &+ 0x12, 0)
                if word(a3 &+ 0x1BE) != 0 {
                    setWord(a2 &+ 0x10, 0)
                    setWord(a2 &+ 0x12, Self.divide(UInt32(word(a3 &+ 0x1C0)) << 15, by: rate) >> 2)
                    setWord(a2 &+ 0x14, UInt16(bitPattern: signedByte(a3 &+ 0xA4)))
                }
                setByte(a1 &+ 10, 0xFF)
            }
        } else if command == 2 {
            setWord(a2 &+ 10, 6)
        }
        // The vibrato (`lbC01ED26`): after its delay, its place moves through its table of 256, stopping
        // at its end ($FE00) if the instrument says it is played once.
        let delay = Int16(bitPattern: word(a2 &+ 0x12))
        if delay > 0 {
            setWord(a2 &+ 0x12, word(a2 &+ 0x12) &- 1)
        } else if delay == 0 {
            var d0 = word(a2 &+ 0x10)
            let d1 = UInt16(truncatingIfNeeded: ((UInt32(word(a3 &+ 0x1BC)) &* rate) &<< 6) >> 16)
            if Int16(bitPattern: word(a3 &+ 0x1BE)) > 0 {
                let (sum, carry) = d0.addingReportingOverflow(d1)
                d0 = sum
                if carry || d0 >= 0xFE00 {
                    setWord(a2 &+ 0x12, 0xFFFF)
                    d0 = 0xFE00
                }
            } else {
                d0 = d0 &+ d1
            }
            setWord(a2 &+ 0x10, d0)
            setWord(a2 &+ 0x14, UInt16(bitPattern: signedByte(a3 &+ 0xA4 &+ UInt32(d0 >> 8))))
        }
        envelopeStep(info: a3, phaseAt: a2 &+ 10, valueAt: a2 &+ 12, levels: 0x1C6, rates: 0x1CE, voice: a1)
        // The period, sliding, and the octave it is played in: halved while it is more than $1AC.
        var period = word(a2)
        var octave: UInt16 = 5
        if word(a2 &+ 2) != 0 {
            setWord(a2 &+ 2, word(a2 &+ 2) &- 1)
            period = period &+ word(a2 &+ 4)
            setWord(a2, period)
        }
        while Int16(bitPattern: period) > 0x1AC {
            period >>= 1
            octave &-= 1
        }
        setWord(a2 &+ 8, octave)
        setWord(a1 &+ 0x10, 0x40 >> (octave & 63))
        // The vibrato's and the pitch's change of it, in 4096ths.
        var d1 = Self.mulsWordShift(word(a2 &+ 0x14), word(a3 &+ 0x1B4), 7)
        d1 = d1 &- (sWord(2) &- 0x80)
        d1 = d1 &+ 0x1000
        let d0 = (UInt32(period) &* UInt32(d1)) >> 12
        setWord(a1 &+ 0x18, bentPeriod(v, d0))
        // The volume: the instrument's, moved by the vibrato, times the envelope's (if it has one; with
        // none, nothing once let go), times the ramp's and the note's.
        var volume = word(a3 &+ 0x1AC)
        let depth = word(a3 &+ 0x1B0)
        if depth != 0 { volume = volume &+ Self.mulsWordShift(0 &- word(a2 &+ 0x14), depth, 8) }
        if word(a3 &+ 0x1AE) != 0 {
            volume = UInt16(truncatingIfNeeded: UInt32(volume) &* UInt32(word(a2 &+ 12))) >> 8
        } else if word(a2 &+ 10) == 6 {
            volume = 0
        }
        volume = (volume & 0xFF) &+ 1
        let ramp = UInt32(rampedVolume(v, a1))
        let heard = UInt16(truncatingIfNeeded: ramp &* UInt32(volume)) >> 8
        setWord(a1 &+ 0x1A, (heard &+ 1) >> 2)
        // The filter: the instrument's, less the envelope's part, more the vibrato's.
        let envelopePart = UInt16(truncatingIfNeeded: UInt32(word(a3 &+ 0x1B8)) &* UInt32(word(a2 &+ 12))) >> 8
        var filter = (word(a3 &+ 0x1B6) ^ 0xFF) &- envelopePart
        filter = filter &+ Self.mulsWordShift(word(a2 &+ 0x14), word(a3 &+ 0x1BA), 8)
        var row = UInt32(((filter & 0xFF) >> 2) << 7)
        var wave = long(a3 &- 4)
        if wave == 0 {
            wave = a3 &+ 0x24
            row = 0
        }
        wave &+= row
        let half = word(a2 &+ 6) ^ 0x80
        setWord(a2 &+ 6, half)
        let buffer = long(s &+ 0x3E2) &+ UInt32(half) &+ UInt32(v) << 8
        setLong(a1 &+ 12, buffer)
        writeWave(from: wave, into: buffer, octave: word(a2 &+ 8), length: word(a1 &+ 0x10), state: a2,
                  phaseRate: word(a3 &+ 0x1C2), phaseDepth: word(a3 &+ 0x1C4), rate: rate)
    }

    /// MULS.W then ASR.W: the signed product of two words, its lower word shifted right as signed.
    static func mulsWordShift(_ a: UInt16, _ b: UInt16, _ shift: Int) -> UInt16 {
        let product = Int32(Int16(bitPattern: a)) &* Int32(Int16(bitPattern: b))
        return UInt16(bitPattern: Int16(truncatingIfNeeded: product) >> shift)
    }

    /// DIVU.W: the quotient's word, or for one too big for a word the dividend's lower word; for a
    /// divisor of nought (for which the 68000 would stop) nought.
    static func divide(_ dividend: UInt32, by divisor: UInt32) -> UInt16 {
        let d = divisor & 0xFFFF
        guard d != 0 else { return 0 }
        let q = dividend / d
        return UInt16(truncatingIfNeeded: q > 0xFFFF ? dividend : q)
    }

    // MARK: The sampled instrument (`SSTech`)

    /// `lbC01F276`: a sampled instrument's tick, its state at $3A of the voice: 0 its period, 2 its
    /// envelope's phase and 4 its value, 8 its vibrato's place, 10 the ticks before it starts and 12 its
    /// value. A note is played from the octave of the sample it falls in (if the sample has it), its
    /// first part then its loop; the vibrato, a triangle, and the envelope move.
    private mutating func snxSampled(_ v: Int) {
        let a1 = voiceAt(v)
        let a3 = long(a1 &+ 4)
        let a2 = a1 &+ 0x3A
        let rate = UInt32(sWord(0x32))
        let command = byte(a1)
        if command == 1 {
            let a5 = long(a3 &+ 0x44)
            let note = word(a1 &+ 2)
            var d0: UInt32
            var octave: UInt8
            var played = true
            if note >= 0x80 {
                let q = UInt32(0x369_E990) / UInt32(note)
                d0 = q > 0xFFFF ? 0x369_E990 : q
                octave = byte(a5 &+ 5)
            } else {
                let q = note / 12, step = Int(note % 12)
                octave = UInt8(truncatingIfNeeded: 10 &- q)
                d0 = 0
                let highest = Int8(bitPattern: byte(a5 &+ 5)), lowest = Int8(bitPattern: byte(a5 &+ 4))
                if Int8(bitPattern: octave) > highest || Int8(bitPattern: octave) < lowest {
                    played = false
                } else {
                    d0 = (UInt32(0x1AB9) &* UInt32(SonixTables.semitones[step])) >> 15
                }
            }
            if !played {
                setByte(a1, 0)
                setLong(a1 &+ 0x1C, 0)
                if byte(a1 &+ 1) == 0 { return }
            } else {
                setWord(a2, UInt16(truncatingIfNeeded: d0))
                let shift = UInt32(octave) & 31
                let blocks = (UInt32(1) << shift) &- (UInt32(1) << (UInt32(byte(a5 &+ 4)) & 31))
                let offset = (blocks & 0xFFFF) &* UInt32(word(a5))
                let start = a5 &+ 0x3E &+ offset
                let first = UInt32(word(a5 &+ 2))
                let loop = UInt32(word(a5) &- word(a5 &+ 2))
                placeSample(a1, base: start, first: first << shift, loop: loop << shift)
                setLong(a2 &+ 4, 0)
                setWord(a2 &+ 2, 0)
                if byte(a1 &+ 10) & 1 != 0 {
                    setWord(a2 &+ 2, 4)
                    setLong(a2 &+ 4, long(a3 &+ 0x4E) & 0xFFFF_0000)
                }
                setWord(a2 &+ 8, 0)
                setWord(a2 &+ 10, Self.divide(UInt32(word(a3 &+ 0x5E)) << 15, by: rate) >> 1)
                silence(v)
            }
        } else if command == 2 {
            setWord(a2 &+ 2, 6)
        }
        vibrateTriangle(info: a3, delayAt: a2 &+ 10, placeAt: a2 &+ 8, valueAt: a2 &+ 12, speed: 0x5C, rate: rate)
        envelopeStep(info: a3, phaseAt: a2 &+ 2, valueAt: a2 &+ 4, levels: 0x4A, rates: 0x52, voice: a1)
        var d1 = Self.mulsWordShift(word(a2 &+ 12), word(a3 &+ 0x5A), 7)
        d1 = d1 &- (sWord(2) &- 0x80)
        d1 = d1 &+ 0x1000
        let d0 = (UInt32(word(a2)) &* UInt32(d1)) >> 16
        let period = bentPeriod(v, d0)
        setWord(a1 &+ 0x18, period)
        noteRun(a1, period: period)
        var volume = UInt32(rampedVolume(v, a1)) &+ 1
        volume = UInt32(UInt16(truncatingIfNeeded: (volume & 0xFFFF) &* UInt32(word(a3 &+ 0x48))) >> 8)
        let level = UInt32(word(a2 &+ 4))
        setWord(a1 &+ 0x1A, UInt16(truncatingIfNeeded: volume &* level) >> 10)
    }

    /// A sampled sound's vibrato (`lbC01F368`, and the TINY and SMUS players' alike): after its delay,
    /// its place moves on by its speed times the rate and $40, and its value is the triangle of it.
    func vibrateTriangle(info: UInt32, delayAt: UInt32, placeAt: UInt32, valueAt: UInt32, speed: UInt32, rate: UInt32) {
        let delay = word(delayAt)
        if delay != 0 {
            setWord(delayAt, delay &- 1)
        } else {
            let d1 = UInt16(truncatingIfNeeded: ((UInt32(word(info &+ speed)) &* rate) &<< 7) >> 16) &+ 0x40
            setWord(placeAt, word(placeAt) &+ d1)
        }
        var d0 = (word(placeAt) >> 7) &+ 0x80
        if d0 & 0x100 != 0 { d0 ^= 0xFF }
        d0 ^= 0x80
        let value = Int16(Int8(truncatingIfNeeded: d0))
        setWord(valueAt, UInt16(bitPattern: 0 &- value))
    }

    // MARK: The 8SVX instrument (`IFFTech`)

    /// `lbC01F604`: an 8SVX instrument's tick, its state at $48 of the voice: 0 its period, 2 whether it
    /// sounds. A note plays the octave of the sample it falls in, if the sample has it; letting it go
    /// silences it.
    private mutating func snxIFF(_ v: Int) {
        let a1 = voiceAt(v)
        let a3 = long(a1 &+ 4)
        let a2 = a1 &+ 0x48
        let command = byte(a1)
        if command == 1 {
            let note = word(a1 &+ 2)
            var d0: UInt16 = 0
            var octave: UInt16 = 0
            var played = true
            if note >= 0x80 {
                d0 = UInt16(truncatingIfNeeded: UInt32(0x36_9E99) / UInt32(note))
                octave = UInt16(byte(a3 &+ 0x32) &- 1)
            } else {
                let q = note / 12, step = Int(note % 12)
                d0 = UInt16(truncatingIfNeeded: ((UInt32(0x1AC) &* UInt32(SonixTables.semitones[step])) &<< 1) >> 16)
                octave = (10 &- q) &- word(a3 &+ 0x38)
                let octaves = Int8(bitPattern: byte(a3 &+ 0x32))
                if Int16(bitPattern: octave) < 0 || Int8(bitPattern: UInt8(truncatingIfNeeded: octave)) >= octaves {
                    played = false
                }
            }
            if !played {
                setByte(a1, 0)
                setLong(a1 &+ 0x1C, 0)
                if byte(a1 &+ 1) == 0 { return }
            } else {
                setWord(a2, d0)
                let shift = UInt32(octave) & 63
                let first = long(a3 &+ 0x24), loop = long(a3 &+ 0x28)
                let shifted = { (x: UInt32) -> UInt32 in shift >= 32 ? 0 : x << shift }
                let base = long(a3 &+ 0x3A) &- first &- loop &+ shifted(first) &+ shifted(loop)
                placeSample(a1, base: base, first: shifted(first), loop: shifted(loop))
                setWord(a2 &+ 2, 1)
                silence(v)
            }
        } else if command == 2 {
            setWord(a2 &+ 2, 0)
            setLong(a1 &+ 0x1C, 0)
        }
        let d0 = UInt16(truncatingIfNeeded: ((UInt32(0x1080 &- sWord(2)) &* UInt32(word(a2))) &<< 4) >> 16)
        let period = bentPeriod(v, UInt32(d0))
        setWord(a1 &+ 0x18, period)
        noteRun(a1, period: period)
        var volume: UInt16 = 0
        if word(a2 &+ 2) != 0 {
            let ramped = (UInt32(rampedVolume(v, a1)) &+ 1) & 0xFFFF
            let level = (long(a3 &+ 0x34) >> 1) & 0xFFFF
            volume = UInt16(truncatingIfNeeded: (ramped &* level) >> 16) >> 1
        }
        setWord(a1 &+ 0x1A, volume)
    }

    // MARK: The AIFF instrument (`AIFFTech`)

    /// `InstallAIFF`: an AIFF instrument (a FORM, or a LIST of them, one for each range of notes): each
    /// FORM's SSND chunk becomes an entry of a list, at $28 of `info` the first (`lbC01F7E8`), its id
    /// and size taken over for the next entry's place and its INST chunk's, then the two numbers of its
    /// NAME chunk, its rate (from COMM) and its length in words; its INST's loop's markers become
    /// places in the sound. Returns false where the player would take the score to be corrupt.
    func installAIFF(_ file: UInt32, into info: UInt32, size: Int) -> Bool {
        setLong(info &+ 0x24, file)
        guard long(file &+ 8) == 0x4149_4646 else { return false }
        var previous: UInt32 = 0
        if long(file) == 0x464F_524D {
            guard parseAIFF(file, previous: &previous, info: info) else { return false }
        } else {
            var chunk = findChunk(0x464F_524D, in: file, from: file &+ 12)
            var count = 0
            while chunk != 0, count < 64 {
                count &+= 1
                guard long(chunk &+ 8) == 0x4149_4646, parseAIFF(chunk, previous: &previous, info: info) else { return false }
                chunk = nextChunk(chunk, in: file)
                if chunk == 0 { break }
                chunk = findChunk(0x464F_524D, in: file, from: chunk)
            }
        }
        return long(info &+ 0x28) != 0
    }

    /// `lbC01F708`: the first chunk of `id` from `from` on in the FORM or LIST `container`, or nought.
    private func findChunk(_ id: UInt32, in container: UInt32, from: UInt32) -> UInt32 {
        guard Int32(bitPattern: long(container &+ 4)) > 4 else { return 0 }
        var a1 = from
        var count = 0
        while a1 != 0, count < 4096 {
            if long(a1) == id { return a1 }
            a1 = nextChunk(a1, in: container)
            count &+= 1
        }
        return 0
    }

    /// `lbC01F726`: the chunk after `chunk`, or nought past the container's end.
    private func nextChunk(_ chunk: UInt32, in container: UInt32) -> UInt32 {
        let after = chunk &+ long(chunk &+ 4)
        return after &- container < long(container &+ 4) ? after &+ 8 : 0
    }

    /// `lbC01F7E8`: one AIFF FORM read into the list.
    private func parseAIFF(_ form: UInt32, previous: inout UInt32, info: UInt32) -> Bool {
        let comm = findChunk(0x434F_4D4D, in: form, from: form &+ 12)
        guard comm != 0 else { return false }
        let ssnd = findChunk(0x5353_4E44, in: form, from: form &+ 12)
        guard ssnd != 0 else { return false }
        if previous == 0 { setLong(info &+ 0x28, ssnd) } else { setLong(previous, ssnd) }
        previous = ssnd
        setLong(ssnd, 0)
        let shift = (0x400E &- word(comm &+ 0x10)) & 63
        setWord(ssnd &+ 12, shift >= 16 ? 0 : word(comm &+ 0x12) >> shift)
        setWord(ssnd &+ 14, UInt16(truncatingIfNeeded: long(comm &+ 10) >> 1))
        setWord(ssnd &+ 8, 0)
        setWord(ssnd &+ 10, 0)
        let name = findChunk(0x4E41_4D45, in: form, from: form &+ 12)
        if name != 0 {
            var a = name &+ 8
            setWord(ssnd &+ 8, readNumber(&a))
            setWord(ssnd &+ 10, readNumber(&a))
        }
        let inst = findChunk(0x494E_5354, in: form, from: form &+ 12)
        setLong(ssnd &+ 4, inst)
        guard inst != 0, word(inst &+ 0x10) != 0 else { return true }
        let mark = findChunk(0x4D41_524B, in: form, from: form &+ 12)
        guard mark != 0 else { return false }
        for field in [UInt32(0x12), 0x14] {
            guard let position = marker(word(inst &+ field), in: mark) else { return false }
            let half = Int32(bitPattern: position) >> 1
            guard half >= 0 else { return false }
            setWord(inst &+ field, UInt16(truncatingIfNeeded: half))
        }
        return true
    }

    /// `lbC01F8CE`: the position of marker `id` in a MARK chunk, or nil.
    private func marker(_ id: UInt16, in mark: UInt32) -> UInt32? {
        var count = Int16(bitPattern: word(mark &+ 8))
        var a = mark &+ 10
        while true {
            count &-= 1
            if count < 0 { return nil }
            if word(a) == id { return long(a &+ 2) }
            a &+= 6
            a &+= UInt32((byte(a) &+ 2) & 0xFE)
        }
    }

    /// `lbC01F902`: a number in decimal, after any spaces.
    private func readNumber(_ a: inout UInt32) -> UInt16 {
        var count = 0
        while byte(a) == 0x20, count < 256 {
            a &+= 1
            count &+= 1
        }
        var d0: UInt16 = 0
        while count < 512 {
            let digit = byte(a) &- 0x30
            guard digit < 10 else { break }
            d0 = UInt16(truncatingIfNeeded: UInt32(d0) &* 10) &+ UInt16(digit)
            a &+= 1
            count &+= 1
        }
        return d0
    }

    /// `lbC01F944`: an AIFF instrument's tick, its state at $4C of the voice: 0 its period, 2 its volume
    /// (in 65280ths), 4 and 6 the steps it rises and falls by. A note plays the sound of the list whose
    /// range it falls in (by its INST chunk), at its rate moved by the note's distance from its base
    /// note, its sustain loop looped; it rises to full at once (or by its attack, from the NAME's first
    /// number, if the note is marked to) and falls when let go (by the NAME's second).
    private mutating func snxAIFF(_ v: Int) {
        let a1 = voiceAt(v)
        let a3 = long(a1 &+ 4)
        let a2 = a1 &+ 0x4C
        let rate = UInt32(sWord(0x32))
        let command = byte(a1)
        if command == 1 {
            var a5 = long(a3 &+ 0x28)
            var played = false
            var rateWord: UInt16 = 0
            var count = 0
            search: while a5 != 0, count < 64 {
                count &+= 1
                let a4 = long(a5 &+ 4)
                var d0 = word(a5 &+ 12)
                var d1 = word(a1 &+ 2)
                if d1 == 0 {
                    rateWord = d0
                    played = true
                    break search
                }
                if d1 >= 0x80 {
                    rateWord = d1
                    played = true
                    break search
                }
                var semitones: Int8
                if a4 == 0 {
                    semitones = Int8(truncatingIfNeeded: UInt8(truncatingIfNeeded: d1) &- 0x3C)
                } else {
                    let low = byte(a4 &+ 10), high = byte(a4 &+ 11)
                    if UInt8(truncatingIfNeeded: d1) > high || UInt8(truncatingIfNeeded: d1) < low {
                        a5 = long(a5)
                        continue
                    }
                    semitones = Int8(bitPattern: UInt8(truncatingIfNeeded: d1) &- byte(a4 &+ 8))
                }
                // The rate moved by the note's distance from the base note: halved or doubled for each
                // octave, then divided by the semitone's step.
                if semitones != 0 {
                    if semitones < 0 {
                        repeat {
                            d0 >>= 1
                            semitones &+= 12
                        } while semitones < 0
                    } else {
                        var overflowed = false
                        while semitones >= 12 {
                            let (doubled, carry) = d0.addingReportingOverflow(d0)
                            if carry {
                                overflowed = true
                                break
                            }
                            d0 = doubled
                            semitones &-= 12
                        }
                        if overflowed { break search }
                    }
                    if semitones != 0 {
                        let dividend = UInt32(d0) << 15
                        let divisor = UInt32(SonixTables.semitones[Int(semitones) % 13])
                        let q = dividend / divisor
                        if q > 0xFFFF { break search }
                        d0 = UInt16(q)
                    }
                }
                d1 = d0
                rateWord = d1
                played = true
                break search
            }
            if !played || rateWord == 0 {
                setByte(a1, 0)
                setLong(a1 &+ 0x1C, 0)
                if byte(a1 &+ 1) == 0 { return }
            } else {
                setWord(a2, Self.divide(0x36_9E99, by: UInt32(rateWord)))
                var first = UInt32(word(a5 &+ 14)), loop: UInt32 = 0
                let a4 = long(a5 &+ 4)
                if a4 != 0, word(a4 &+ 0x10) != 0 {
                    first = UInt32(word(a4 &+ 0x12))
                    loop = UInt32(word(a4 &+ 0x14) &- word(a4 &+ 0x12))
                }
                placeSample(a1, base: a5 &+ 0x10, first: first << 1, loop: loop << 1)
                var level: UInt16 = 0
                if byte(a1 &+ 10) & 1 != 0 { level = 0xFF00 }
                setWord(a2 &+ 2, level)
                setWord(a2 &+ 4, Self.divide(0xFF00, by: UInt32(word(a5 &+ 8) &+ 1)))
                setWord(a2 &+ 6, Self.divide(0xFF00, by: UInt32(word(a5 &+ 10) &+ 1)))
                setByte(a1 &+ 10, 0xFF)
                silence(v)
            }
        } else if command == 2 {
            setByte(a1 &+ 10, 0)
        }
        let d0 = UInt16(truncatingIfNeeded: ((UInt32(0x1080 &- sWord(2)) &* UInt32(word(a2))) &<< 4) >> 16)
        let period = bentPeriod(v, UInt32(d0))
        setWord(a1 &+ 0x18, period)
        noteRun(a1, period: period)
        let level = word(a2 &+ 2)
        if byte(a1 &+ 10) != 0 {
            if level != 0xFF00 {
                var next: UInt16 = 0xFF00
                let up = UInt64(UInt32(word(a2 &+ 4)) &* rate) &* 2
                if up <= 0xFFFF_FFFF {
                    let (sum, carry) = level.addingReportingOverflow(UInt16(truncatingIfNeeded: up >> 16))
                    if !carry, sum < 0xFF00 { next = sum }
                }
                setWord(a2 &+ 2, next)
                if next == 0 { setLong(a1 &+ 0x1C, 0) }
            }
        } else {
            var next: UInt16 = 0
            if level != 0 {
                let down = UInt64(UInt32(word(a2 &+ 6)) &* rate) &* 2
                if down <= 0xFFFF_FFFF {
                    let d = UInt16(truncatingIfNeeded: down >> 16)
                    if level >= d { next = level &- d }
                }
            }
            setWord(a2 &+ 2, next)
            if next == 0 { setLong(a1 &+ 0x1C, 0) }
        }
        let ramped = (UInt32(rampedVolume(v, a1)) &+ 1) & 0xFFFF
        let heard = UInt16(truncatingIfNeeded: (ramped &* UInt32(word(a2 &+ 2))) >> 16) &+ 1
        setWord(a1 &+ 0x1A, heard >> 2)
    }
}
