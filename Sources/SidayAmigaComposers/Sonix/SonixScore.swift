// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the 68000 code of Mark Riley's Sonix Music Driver 2.0b and 2.0f, as Wanted Team's player
// for EaglePlayer carries them for TINY and SMUS scores (see `SonixPlayer`). The labels given are that
// player's source's: TINY's first, SMUS's after them.

/// The players of TINY scores (Sonix Music Driver 2.0b, from Melbourne House's Magic Johnson's
/// Basketball) and SMUS ones (2.0f, from Synergistic's Vengeance of Excalibur): one player, its
/// variables at other places, its instruments' fields at other offsets (SMUS's being those of the
/// files Sonix saved, TINY's of a game's own, shorter), and its score the TINY file itself or the one
/// SMUS's `LoadSCORE` makes of the IFF one.
///
/// The score: 0 its volume, 2 its tempo (twice its entry's place in `SonixTables.tempos`), 4 its transpose
/// ($80, none, in 16ths), 6 its pitch ($80, none), 12 its instrument if a track has none, at $12 a
/// word for each track (its volume), at $20 a long for each (whether it plays its notes: one played
/// at full volume, any other but nought at half), at $30 each track's place (for TINY an offset in
/// the file), and at $40 the instruments (TINY's 64 longs, SMUS's 64 numbers of its registers' places
/// in the table, one more).
///
/// A track's events are words: a note ($nnll: note nn for ll of the score's ticks, let go after
/// three quarters of them), a rest ($80ll), the instrument ($81), or $FFFF, the end.
extension SonixPlayer {
    /// Where TINY's and SMUS's player keeps each of its variables, as offsets from `Sonix`; and its
    /// instruments' fields' offsets less TINY's.
    struct ScoreLayout {
        var countdown: UInt32, lastTempo: UInt32, rate: UInt32, ticks: UInt32, flags: UInt32
        var enabled: UInt32, rampNow: UInt32, rampTarget: UInt32, rampStep: UInt32
        var voices: UInt32, instrument: UInt32, release: UInt32, wait: UInt32, start: UInt32, reading: UInt32
        var chip: UInt32, synthesised: UInt32, sampled: UInt32, iff: UInt32
        var synthesisedDelta: UInt32, sampledDelta: UInt32, iffDelta: UInt32

        static let tiny = ScoreLayout(
            countdown: 0x1E, lastTempo: 0x20, rate: 0x22, ticks: 0x24, flags: 0x1C,
            enabled: 0x26, rampNow: 0x38, rampTarget: 0x3A, rampStep: 0x3C,
            voices: 0x3E, instrument: 0x96, release: 0xA6, wait: 0xB6, start: 0xC6, reading: 0xE6,
            chip: 0x106, synthesised: 0x10A, sampled: 0x172, iff: 0x1C2,
            synthesisedDelta: 0, sampledDelta: 0, iffDelta: 0)

        static let smus = ScoreLayout(
            countdown: 0x32, lastTempo: 0x34, rate: 0x36, ticks: 0x38, flags: 0x30,
            enabled: 0x3A, rampNow: 0x1CC, rampTarget: 0x1CE, rampStep: 0x1D0,
            voices: 0x1D2, instrument: 0x22A, release: 0x23A, wait: 0x24A, start: 0x25A, reading: 0x27A,
            chip: 0x29A, synthesised: 0x3FC, sampled: 0x464, iff: 0x4B4,
            synthesisedDelta: 0x1C, sampledDelta: 0x40, iffDelta: 0x20)
    }

    private var layout: ScoreLayout { kind == .tiny ? .tiny : .smus }
    /// The score: the TINY file itself, SMUS's in `Buffer2`.
    private var scorePlace: UInt32 { kind == .tiny ? moduleAt : scoreAt }
    /// A voice ($16 bytes): 0 what it is told (1 a note, 2 let go, 3 stop), 1 what it does (1 plays,
    /// 2 let go), 3 the note, 4 the instrument, 8 the volume, 10 a count for its sample's start (for a
    /// synthesised one, a mark to turn it on), 12 and $10 where Paula plays from and how long, $12 the
    /// period and $14 the volume.
    private func scoreVoice(_ v: Int) -> UInt32 { sonixAt &+ layout.voices &+ 0x16 &* UInt32(v & 0xFFFF) }

    // MARK: SMUS's score (`LoadSCORE`)

    /// `LoadSCORE`: the IFF SMUS read into the score at `Buffer2`, chunk by chunk. SHDR gives the tempo
    /// (the first of the table's not slower than it), the volume (doubled, if less than 128) and how
    /// many tracks play; SNX1 the transpose and pitch, and which tracks play; each of the first four
    /// TRAKs is a track, its events moved down two bytes, over the chunk's size, ended with $FFFF (over
    /// its last), its notes' and rests' lengths turned into ticks (`SonixTables.durations`), its
    /// volume ($84) and time ($82) taken out.
    mutating func loadScore(size: Int) {
        let a5 = scoreAt
        let end = moduleAt &+ UInt32(size)
        for t in 0 ..< UInt32(4) { setWord(a5 &+ 0x10 &+ 4 &* t &+ 2, 0xFF) }
        var a2 = moduleAt &+ 4
        var left = Int64(Int32(bitPattern: long(a2))) &- 4
        a2 &+= 8
        var tracks: UInt32 = 0
        // (The player reads on while its count of what is left is not nought, which a chunk's size can
        // take past; here it stops at the file's end too.)
        while left != 0, a2 &+ 8 <= end {
            let id = long(a2)
            var chunk = Int64(long(a2 &+ 4))
            a2 &+= 8
            chunk = (chunk &+ 1) & ~1
            left &-= chunk &+ 8
            var skip = chunk
            switch id {
            case 0x5348_4452:
                // SHDR: the tempo, in 128ths of a quarter note a minute.
                let tempo = word(a2)
                var index: UInt16 = 0
                if tempo >= 0xE11 {
                    let d1 = UInt16(truncatingIfNeeded: 0xE10_0000 / UInt32(tempo))
                    var d0: UInt16 = 0
                    while d0 < 0x100, d1 < SonixTables.tempos[Int(d0 / 2)] { d0 &+= 2 }
                    if d0 >= 0x100 { d0 &-= 1 }
                    index = d0
                }
                setWord(a5 &+ 2, index)
                var volume = UInt16(byte(a2 &+ 2))
                if volume < 0x80 { volume <<= 1 }
                setWord(a5, volume)
                var count = byte(a2 &+ 3)
                if count >= 5 { count = 4 }
                for t in 0 ..< UInt32(count) { setLong(a5 &+ 0x20 &+ 4 &* t, 1) }
                skip &-= 4
                a2 &+= 4
            case 0x534E_5831 ... 0x534E_5839:
                setWord(a5 &+ 4, word(a2))
                setWord(a5 &+ 6, word(a2 &+ 2))
                for t in 0 ..< UInt32(4) { setLong(a5 &+ 0x20 &+ 4 &* t, long(a2 &+ 8 &+ 4 &* t)) }
                skip &-= 0x18
                a2 &+= 0x18
            case 0x5452_414B where tracks < 4:
                let track = a5 &+ 4 &* tracks
                tracks &+= 1
                let into = a2 &- 2
                setLong(track &+ 0x30, into)
                // (A chunk of nought bytes the player would copy for ever: here nothing.)
                let count = UInt32(max(0, min(chunk, a2 <= end ? Int64(end - a2) : 0)))
                for i in 0 ..< count { setByte(into &+ i, byte(a2 &+ i)) }
                setWord(into &+ count, 0xFFFF)
                a2 &+= count
                skip = 0
                var a0 = into
                while word(a0) != 0xFFFF {
                    var d0 = word(a0)
                    let d1 = d0 & 0xFF00
                    if d1 == 0x8100 {
                        // (Kept.)
                    } else if d1 < 0x8100 {
                        let ticks = SonixTables.durations[Int(d0 & 15)]
                        d0 = ticks & 0x80 != 0 ? 0 : d1 | UInt16(ticks)
                    } else {
                        if d1 == 0x8200 {
                            setWord(a5 &+ 8, (d0 >> 3 & 0x1F) &+ 1)
                            setWord(a5 &+ 10, 1 << (d0 & 7))
                        } else if d1 == 0x8400 {
                            setWord(track &+ 0x12, (d0 & 0x7F) << 1)
                        }
                        d0 = 0
                    }
                    setWord(a0, d0)
                    a0 &+= 2
                }
            default: break
            }
            if skip > 0 { a2 &+= UInt32(truncatingIfNeeded: skip) }
        }
    }

    // MARK: Playing the score

    /// `PLAYSCORE` / `PlaySCORE` (for `InitSound`, from nought to -1, for ever): the score's tracks'
    /// marks taken, its state at the start found and taken, its tempo and pitch, and its volume at once.
    mutating func playScore() {
        let l = layout
        stopScore()
        let score = scorePlace
        setS(12, long: 0)
        setS(0x14, long: 0xFFFF_FFFF)
        for t in 0 ..< UInt32(4) { setS(l.enabled &+ 4 &* t, long: long(score &+ 0x20 &+ 4 &* t)) }
        findScoreStart(score)
        beginScoreAgain(score)
        setS(l.countdown, word: 0)
        setS(6, long: score)
        setS(0, word: 0)
        setS(2, word: word(score &+ 2))
        setS(4, word: word(score &+ 6))
        rampScoreVolume(ticks: 0, to: word(score))
        setS(10, word: 0xFFFF)
    }

    /// `STOPSCORE` / `StopSCORE` (`lbC00CF50`): if it plays, the notes of the tracks that play let go.
    private mutating func stopScore() {
        let l = layout
        setS(l.flags, byte: sByte(l.flags) & 0xFE)
        stopPlaying()
    }

    private mutating func stopPlaying() {
        let l = layout
        guard sWord(10) != 0 else { return }
        setS(10, word: 0)
        for v in 0 ..< 4 where sLong(l.enabled &+ 4 &* UInt32(v)) != 0 { releaseScoreNote(v) }
    }

    /// `lbC00CF7A` / `lbC0006E4`: what each track is at the score's start (here its first event): where
    /// it reads, its instrument plus one ($10) and how much of a note it is into ($11).
    private func findScoreStart(_ score: UInt32) {
        let l = layout
        let start = Int32(bitPattern: sLong(12))
        for v in 0 ..< UInt32(4) {
            let a1 = sonixAt &+ l.start &+ 4 &* v
            setLong(a1, 0)
            setByte(a1 &+ 0x10, 0)
            setByte(a1 &+ 0x11, 0)
            var place = long(score &+ 0x30 &+ 4 &* v)
            guard place != 0 else { continue }
            if kind == .tiny { place &+= score }
            var a2 = place
            var d5 = start
            var count = 0
            while count < 0x10_0000 {
                count &+= 1
                setLong(a1, a2)
                if d5 <= 0 { break }
                let d0 = word(a2)
                a2 &+= 2
                if d0 == 0 { continue }
                if d0 == 0xFFFF { break }
                if d0 >= 0x8200 { continue }
                if d0 >= 0x8100 {
                    setByte(a1 &+ 0x10, UInt8(truncatingIfNeeded: d0) &+ 1)
                    continue
                }
                d5 = d5 &- Int32(d0 & 0xFF)
                if d5 < 0 { setByte(a1 &+ 0x11, UInt8(truncatingIfNeeded: 0 &- d5)) }
            }
        }
    }

    /// `lbC00CFEC` / `lbC000754`: the score begun again from its start as `findScoreStart` found it,
    /// each track's note let go. (TINY's player finds a track's instrument at the start at twice its
    /// number, not four times, where the instruments' longs are; from the start of a score it never
    /// has one.)
    private mutating func beginScoreAgain(_ score: UInt32) {
        let l = layout
        for i in 0 ..< UInt32(32) { setS(l.reading &+ i, byte: sByte(l.start &+ i)) }
        setS(0x10, long: sLong(12))
        for v in 0 ..< UInt32(4) {
            if sLong(l.enabled &+ 4 &* v) != 0 { releaseScoreNote(Int(v)) }
            setS(l.release &+ 4 &* v, long: 0)
            setS(l.wait &+ 4 &* v, long: UInt32(sByte(l.reading &+ 0x11 &+ 4 &* v) &+ 1))
            var instrument: UInt32 = 0
            let number = sByte(l.reading &+ 0x10 &+ 4 &* v)
            if number != 0 {
                if kind == .tiny {
                    instrument = long(score &+ 0x40 &+ 2 &* UInt32(number &- 1))
                } else {
                    let n = byte(score &+ 0x40 &+ UInt32(number &- 1))
                    if n != 0 { instrument = sonixAt &+ 0x4A &+ 6 &* UInt32(n &- 1) }
                }
            }
            setS(l.instrument &+ 4 &* v, long: instrument)
        }
    }

    /// The interrupt (`PlayTINY`, `PlaySMUS`): the volume ramped, the score's tick, the instruments'.
    mutating func playScoreTick() {
        scoreRampTick()
        scoreSequence()
        scoreInstruments()
    }

    /// `lbC00D070` / `lbC000846`: the tempo, if changed, set (`lbC0007F2`); then every `ticks` of the
    /// player's ticks the score's: each track counts down to letting its note go, then its wait; when
    /// done, its events are read up to the next note or rest. When all four have ended, the song has
    /// come to its end and is begun again.
    private mutating func scoreSequence() {
        let l = layout
        if sWord(l.countdown) != 0 {
            setS(l.countdown, word: sWord(l.countdown) &- 1)
            if sWord(l.countdown) != 0 { return }
        }
        let index = sWord(2) >> 1
        if index != sWord(l.lastTempo) {
            setS(l.lastTempo, word: index)
            let tempo = Self.scoreTimer(index: index)
            setS(l.ticks, word: tempo.ticks)
            setS(l.rate, word: tempo.rate)
            if let timer = tempo.timer { latch = timer }
        }
        guard sWord(10) != 0 else { return }
        setS(l.countdown, word: sWord(l.ticks))
        let score = sLong(6)
        var ended: UInt16 = 0
        var rounds = 0
        while true {
            rounds &+= 1
            for v in 0 ..< 4 { if trackTick(v, score: score) { ended &+= 1 } }
            let position = sLong(0x10)
            setS(0x10, long: position &+ 1)
            let end = sLong(0x14)
            if Int32(bitPattern: end) >= 0 {
                guard position == end else { return }
            } else {
                guard ended == 4 else { return }
            }
            songEnded()
            beginScoreAgain(score)
            ended &+= 1
            if rounds > 1 { return }
        }
    }

    /// A track's part of the score's tick. Returns true if it has ended, or has none.
    private mutating func trackTick(_ v: Int, score: UInt32) -> Bool {
        let l = layout
        let o = 4 &* UInt32(v)
        let release = sLong(l.release &+ o)
        if release != 0 {
            setS(l.release &+ o, long: release &- 1)
            if release &- 1 == 0, sLong(l.enabled &+ o) != 0 { releaseScoreNote(v) }
            return false
        }
        let wait = sLong(l.wait &+ o)
        if wait != 0 {
            setS(l.wait &+ o, long: wait &- 1)
            if wait &- 1 != 0 { return false }
        }
        let place = sLong(l.reading &+ o)
        if place == 0 { return true }
        var a0 = place
        var events = 0
        while true {
            var d2: UInt16 = 0
            repeat {
                d2 = word(a0)
                a0 &+= 2
                events &+= 1
            } while d2 == 0 && events < Self.mostEvents
            // (The end is not kept: it is read again on every tick. A track read through more than
            // `mostEvents` in a tick is taken to have ended, as at its end.)
            if d2 == 0xFFFF || events >= Self.mostEvents { return true }
            setS(l.reading &+ o, long: a0)
            let command = UInt8(d2 >> 8)
            var d3 = d2 & 0xFF
            if command & 0x80 == 0 {
                // A note, if the track plays its notes; its length a wait either way.
                if sLong(l.enabled &+ o) != 0 {
                    var instrument = sLong(l.instrument &+ o)
                    if instrument == 0 { instrument = long(score &+ 12) }
                    if instrument != 0 {
                        let note = UInt16(bitPattern: Int16(bitPattern: word(score &+ 4)) >> 4) &- 8 &+ UInt16(command)
                        var volume = word(score &+ 0x12 &+ o)
                        if sWord(l.enabled &+ 2 &+ o) != 1 { volume >>= 1 }
                        startScoreNote(instrument, voice: v, note: UInt8(truncatingIfNeeded: note), volume: volume)
                        let held = UInt16(truncatingIfNeeded: (UInt32(d3) &* 0xC000) >> 16)
                        setS(l.release &+ 2 &+ o, word: held)
                        d3 &-= held
                    }
                }
                setS(l.wait &+ 2 &+ o, word: d3)
                return false
            }
            if command == 0x80 {
                setS(l.wait &+ 2 &+ o, word: d3)
                return false
            }
            if command == 0x81 {
                var instrument: UInt32 = 0
                if kind == .tiny {
                    instrument = long(score &+ 0x40 &+ UInt32(d3 << 2))
                } else {
                    let n = byte(score &+ 0x40 &+ UInt32(d3))
                    if n != 0 { instrument = sonixAt &+ 0x4A &+ 6 &* UInt32(n &- 1) }
                }
                setS(l.instrument &+ o, long: instrument)
            }
        }
    }

    /// `STARTNOTE` / `StartNOTE`, for a track's voice: the instrument (TINY's its file, SMUS's an entry of
    /// the table) given to it, what it played stopped if that was of another kind; its note and volume
    /// kept, and the note to be begun.
    private mutating func startScoreNote(_ instrument: UInt32, voice v: Int, note: UInt8, volume: UInt16) {
        var info = instrument
        if kind == .smus {
            info = long(instrument)
            guard info != 0 else { return }
        }
        let a1 = scoreVoice(v)
        if byte(a1 &+ 1) != 0, long(info) != long(long(a1 &+ 4)) { stopScoreNote(v) }
        setLong(a1 &+ 4, info)
        setByte(a1 &+ 3, note)
        setWord(a1 &+ 8, volume & 0xFF)
        setByte(a1, 1)
    }

    /// `RELEASENOTE` / `ReleaseNOTE`.
    private func releaseScoreNote(_ v: Int) {
        let a1 = scoreVoice(v)
        setByte(a1, 0)
        if byte(a1 &+ 1) == 1 { setByte(a1, 2) }
    }

    /// `STOPNOTE` / `StopNOTE`: the voice told to stop, which its instrument does, and stopped.
    private mutating func stopScoreNote(_ v: Int) {
        let a1 = scoreVoice(v)
        setByte(a1, 0)
        guard byte(a1 &+ 1) != 0 else { return }
        setByte(a1, 3)
        if long(a1 &+ 4) != 0 { _ = instrumentTick(v) }
        setByte(a1 &+ 1, 0)
        setByte(a1, 0)
    }

    /// `lbC00D28E` / `lbC000A60`: the voice's DMA turned off, and its period set to 2.
    private mutating func silenceScoreVoice(_ v: Int) {
        pokeDMA(1 << UInt16(v))
        pokePeriod(v, 2)
    }

    /// `RAMPVOLUME` / `RampVOLUME`: the score's volume, at once (as it is only ever asked here).
    private func rampScoreVolume(ticks: UInt16, to: UInt16) {
        let l = layout
        setS(l.rampStep, word: 0)
        if ticks == 0 {
            setS(0, word: to)
            return
        }
        let now = sWord(0) << 8
        setS(l.rampNow, word: now)
        let target = to << 8
        let apart = now >= target ? now &- target : target &- now
        var step = UInt16(truncatingIfNeeded: UInt32(apart) / UInt32(ticks))
        if step == 0 { step = 1 }
        setS(l.rampTarget, word: target)
        setS(l.rampStep, word: step)
    }

    /// `lbC00D430` / `lbC000C12`: the volume ramped a step; when there, and it is nought, the score
    /// stopped if it was being let go.
    private mutating func scoreRampTick() {
        let l = layout
        let step = UInt32(sWord(l.rampStep))
        guard step != 0 else { return }
        let doubled = UInt64(step &* UInt32(sWord(l.rate))) &* 2
        var now = sWord(l.rampNow)
        var done = doubled > 0xFFFF_FFFF
        if !done {
            let d0 = UInt16(truncatingIfNeeded: doubled >> 16)
            var d3 = d0
            let target = sWord(l.rampTarget)
            var d2 = target &- now
            if target < now {
                d3 = 0 &- d3
                d2 = 0 &- d2
            }
            if d0 >= d2 {
                done = true
            } else {
                now = now &+ d3
                setS(l.rampNow, word: now)
            }
        }
        if done {
            now = sWord(l.rampTarget)
            if now == 0, sByte(l.flags) & 1 != 0 {
                setS(l.flags, byte: sByte(l.flags) & 0xFE)
                stopPlaying()
            }
            setS(l.rampStep, word: 0)
        }
        setS(0, word: now >> 8)
    }

    /// `lbC00D1DE` / `lbC0009B0`: each voice's instrument run for the tick, the voices whose samples
    /// begin turned off, the voice then playing or let go as it was told; then each that plays told
    /// Paula what it is to play, and those begun turned on.
    private mutating func scoreInstruments() {
        var off: UInt16 = 0
        for v in 0 ..< 4 {
            let a1 = scoreVoice(v)
            if byte(a1) != 0 || byte(a1 &+ 1) != 0 {
                if long(a1 &+ 4) == 0 {
                    setByte(a1 &+ 1, 0)
                    setByte(a1, 0)
                    continue
                }
                if instrumentTick(v) { off |= 1 << UInt16(v) }
            }
            let command = byte(a1)
            if command == 1 || command == 2 { setByte(a1 &+ 1, command) }
            setByte(a1, 0)
        }
        pokeDMA(off)
        var on: UInt16 = 0x8000
        for v in 0 ..< 4 {
            let a1 = scoreVoice(v)
            guard byte(a1 &+ 1) != 0 else { continue }
            if instrumentRegisters(v) { on |= 1 << UInt16(v) }
        }
        pokeDMA(on)
    }

    /// The instrument's first routine: its tick. Returns true for a sample just begun.
    private mutating func instrumentTick(_ v: Int) -> Bool {
        switch Tech(rawValue: long(long(scoreVoice(v) &+ 4))) {
        case .synthesised: scoreSynthesised(v)
        case .sampled: return scoreSampled(v)
        case .iff: return scoreIFF(v)
        case .aiff, nil: break
        }
        return false
    }

    /// The instrument's second routine (`lbC00D5D4`, `lbC00DAC0`, `lbC00DD3A`): what Paula is to play.
    /// Returns true for a voice to be turned on.
    private mutating func instrumentRegisters(_ v: Int) -> Bool {
        let a1 = scoreVoice(v)
        switch Tech(rawValue: long(long(a1 &+ 4))) {
        case .synthesised:
            pokeAddress(v, long(a1 &+ 12))
            pokeLength(v, word(a1 &+ 0x10))
            pokePeriod(v, word(a1 &+ 0x12))
            pokeVolume(v, word(a1 &+ 0x14))
            let start = word(a1 &+ 10)
            setWord(a1 &+ 10, 0)
            return start != 0
        case .sampled, .iff:
            var on = false
            let count = word(a1 &+ 10)
            if count != 0 {
                setWord(a1 &+ 10, count &- 1)
                if count &- 1 != 0 {
                    // The sample's start, the voice to be turned on.
                    pokeLength(v, word(a1 &+ 0x10))
                    pokeAddress(v, long(a1 &+ 12))
                    on = true
                } else {
                    // The tick after, its loop.
                    let loop = Tech(rawValue: long(long(a1 &+ 4))) == .sampled
                        ? sonixAt &+ layout.sampled &+ 0x14 &* UInt32(v) : sonixAt &+ layout.iff &+ 10 &* UInt32(v)
                    pokeLength(v, word(loop &+ 4))
                    pokeAddress(v, long(loop))
                }
            }
            pokePeriod(v, word(a1 &+ 0x12))
            pokeVolume(v, word(a1 &+ 0x14))
            return on
        case .aiff, nil: return false
        }
    }

    // MARK: The synthesised instrument

    /// `lbC00D5FE` / `lbC000E4E`: as SNX's (`snxSynthesised`), its state at `synthesised` and $1A bytes
    /// each, but for these: no note marked to begin in its envelope; the vibrato, played once, stops
    /// where it would pass its table's end; stopping the voice turns it off; the volume is the
    /// score's times the note's, and its pitch the score's; and it has no bend, held period or length.
    private mutating func scoreSynthesised(_ v: Int) {
        let l = layout
        let a1 = scoreVoice(v)
        let a3 = long(a1 &+ 4)
        let d = l.synthesisedDelta
        let a2 = sonixAt &+ l.synthesised &+ 0x1A &* UInt32(v)
        let rate = UInt32(sWord(l.rate))
        let command = byte(a1)
        if command == 1 {
            let note = UInt16(byte(a1 &+ 3))
            if note < 0x24 || note >= 0x6C {
                setByte(a1, 0)
                if byte(a1 &+ 1) == 0 { return }
            } else {
                let d1 = note &- 0x24
                if byte(a1 &+ 1) == 0 { setLong(a2 &+ 12, 0) }
                if byte(a1 &+ 1) != 1 { setWord(a2 &+ 10, 0) }
                let octave = UInt32(d1 / 12), step = Int(d1 % 12)
                var d0 = (UInt32(0xD5C8) &* UInt32(SonixTables.semitones[step])) >> ((octave &+ 0x11) & 31)
                if word(a2) == 0 {
                    setWord(a2 &+ 2, 0)
                } else {
                    let d1s = Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: d0) &- word(a2)))
                    var ticks = Self.divide(UInt32(word(a3 &+ 0x196 &+ d)) << 15, by: rate)
                    ticks = (ticks >> 3) &+ 1
                    setWord(a2 &+ 2, ticks)
                    let q = d1s / Int32(Int16(bitPattern: ticks))
                    let stepWord = q < -32768 || q > 32767 ? UInt16(truncatingIfNeeded: d1s) : UInt16(truncatingIfNeeded: q)
                    setWord(a2 &+ 4, stepWord)
                    let back = UInt32(stepWord) &* UInt32(ticks)
                    d0 = d0 & 0xFFFF_0000 | UInt32(UInt16(truncatingIfNeeded: d0) &- UInt16(truncatingIfNeeded: back))
                }
                setWord(a2, UInt16(truncatingIfNeeded: d0))
                setWord(a2 &+ 0x18, 1)
                if word(a3 &+ 0x1A6 &+ d) == 0 { setWord(a2 &+ 0x16, 0) }
                setWord(a2 &+ 0x12, 0)
                if word(a3 &+ 0x1A2 &+ d) != 0 {
                    setWord(a2 &+ 0x10, 0)
                    setWord(a2 &+ 0x12, Self.divide(UInt32(word(a3 &+ 0x1A4 &+ d)) << 15, by: rate) >> 2)
                    setWord(a2 &+ 0x14, UInt16(bitPattern: signedByte(a3 &+ 0x88 &+ d)))
                }
                setWord(a1 &+ 10, 0xFFFF)
            }
        } else if command == 2 {
            setWord(a2 &+ 10, 6)
        } else if command == 3 {
            silenceScoreVoice(v)
            return
        }
        let delay = Int16(bitPattern: word(a2 &+ 0x12))
        if delay > 0 {
            setWord(a2 &+ 0x12, word(a2 &+ 0x12) &- 1)
        } else if delay == 0 {
            let d1 = UInt16(truncatingIfNeeded: ((UInt32(word(a3 &+ 0x1A0 &+ d)) &* rate) &<< 6) >> 16)
            let (d0, carry) = word(a2 &+ 0x10).addingReportingOverflow(d1)
            if carry, Int16(bitPattern: word(a3 &+ 0x1A2 &+ d)) > 0 {
                setWord(a2 &+ 0x12, 0xFFFF)
            } else {
                setWord(a2 &+ 0x10, d0)
                setWord(a2 &+ 0x14, UInt16(bitPattern: signedByte(a3 &+ 0x88 &+ d &+ UInt32(d0 >> 8))))
            }
        }
        scoreEnvelopeStep(info: a3, phaseAt: a2 &+ 10, valueAt: a2 &+ 12, levels: 0x1AA &+ d, rates: 0x1B2 &+ d, rate: rate)
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
        var d1 = Self.mulsWordShift(word(a2 &+ 0x14), word(a3 &+ 0x198 &+ d), 7)
        d1 = d1 &- (sWord(4) &- 0x80)
        d1 = d1 &+ 0x1000
        setWord(a1 &+ 0x12, UInt16(truncatingIfNeeded: (UInt32(period) &* UInt32(d1)) >> 12))
        var volume = word(a3 &+ 0x190 &+ d)
        volume = volume &+ Self.mulsWordShift(0 &- word(a2 &+ 0x14), word(a3 &+ 0x194 &+ d), 8)
        if word(a3 &+ 0x192 &+ d) != 0 {
            volume = UInt16(truncatingIfNeeded: UInt32(volume) &* UInt32(word(a2 &+ 12))) >> 8
        } else if word(a2 &+ 10) == 6 {
            volume = 0
        }
        volume = (volume & 0xFF) &+ 1
        volume = UInt16(truncatingIfNeeded: UInt32(volume) &* UInt32(sWord(0))) >> 8 &+ 1
        volume = UInt16(truncatingIfNeeded: UInt32(volume) &* UInt32(word(a1 &+ 8))) >> 8 &+ 1
        setWord(a1 &+ 0x14, volume >> 2)
        let envelopePart = UInt16(truncatingIfNeeded: UInt32(word(a3 &+ 0x19C &+ d)) &* UInt32(word(a2 &+ 12))) >> 8
        var filter = (word(a3 &+ 0x19A &+ d) ^ 0xFF) &- envelopePart
        filter = filter &+ Self.mulsWordShift(word(a2 &+ 0x14), word(a3 &+ 0x19E &+ d), 8)
        var row = UInt32(((filter & 0xFF) >> 2) << 7)
        // The filtered waveforms: TINY's file keeps their place at 4, SMUS's just before its fields.
        var wave = kind == .tiny ? long(a3 &+ 4) : long(a3 &- 4)
        if wave == 0 {
            wave = a3 &+ 8 &+ d
            row = 0
        }
        wave &+= row
        let half = word(a2 &+ 6) ^ 0x80
        setWord(a2 &+ 6, half)
        let buffer = long(sonixAt &+ l.chip) &+ UInt32(half) &+ 0x100 &* UInt32(v)
        setLong(a1 &+ 12, buffer)
        writeWave(from: wave, into: buffer, octave: word(a2 &+ 8), length: word(a1 &+ 0x10), state: a2,
                  phaseRate: word(a3 &+ 0x1A6 &+ d), phaseDepth: word(a3 &+ 0x1A8 &+ d), rate: rate)
    }

    /// The envelope, as SNX's (`envelopeStep`), but ending nothing.
    private func scoreEnvelopeStep(info: UInt32, phaseAt: UInt32, valueAt: UInt32, levels: UInt32, rates: UInt32, rate: UInt32) {
        let phase = word(phaseAt)
        let a0 = info &+ UInt32(bitPattern: Int32(Int16(bitPattern: phase)))
        let d1 = UInt32(word(a0 &+ levels)) << 16
        var d2 = long(valueAt)
        let r = word(a0 &+ rates)
        let shift = UInt32((r >> 5 ^ 7) & 0x3F)
        let scaled = ((UInt32(r & 0x1F) &+ 0x21) &* rate) &<< 3
        let step = shift >= 32 ? 0 : scaled >> shift
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
    }

    /// A synthesised instrument's waveform for the tick, into its voice's buffer (`lbC01EEBA` on, in
    /// all three players): every 2^octave-th byte of the filtered waveform, `length` words of it; or,
    /// if the instrument moves its phase, that and the same moved on by where its phase is (each
    /// tick by `phaseRate` times the rate), mixed half and half; or, if it also has a depth, the
    /// waveform's first half squeezed into the buffer's first part and its second into the rest, the
    /// point between them swinging to and fro by the depth.
    ///
    /// (An octave past the player's five, from a period it could not halve into them, makes it count
    /// from nought, and write 65,536 bytes on through what follows the buffers, on every tick; here no
    /// more is written than the voice's two buffers, 256 bytes.)
    func writeWave(from wave: UInt32, into buffer: UInt32, octave: UInt16, length: UInt16, state a2: UInt32,
                   phaseRate: UInt16, phaseDepth: UInt16, rate: UInt32) {
        var a0 = wave, a4 = buffer
        var budget = 256
        let step = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: UInt32(1) << UInt32(octave & 31))))
        if phaseRate == 0 {
            var d4 = UInt16(0x80) >> (octave & 63)
            repeat {
                setByte(a4, byte(a0))
                a4 &+= 1
                a0 &+= step
                d4 &-= 1
                budget &-= 1
            } while d4 != 0 && budget > 0
            return
        }
        if phaseDepth == 0 {
            var d2 = (length << 1) &- 1
            var d4 = UInt16(truncatingIfNeeded: (UInt32(phaseRate) &* rate) >> 13) &+ word(a2 &+ 0x16)
            setWord(a2 &+ 0x16, d4)
            d4 >>= 9
            var a5 = a0 &+ UInt32(d4)
            d4 >>= (octave & 63)
            d2 &-= d4
            func mix() {
                let sum = Int16(Int8(bitPattern: byte(a0))) &+ Int16(Int8(bitPattern: byte(a5)))
                setByte(a4, UInt8(truncatingIfNeeded: sum >> 1))
                a4 &+= 1
                a0 &+= step
                a5 &+= step
                budget &-= 1
            }
            for _ in 0 ..< min(Int(d2) &+ 1, budget) { mix() }
            a5 &-= 0x80
            d4 &-= 1
            if Int16(bitPattern: d4) < 0 { return }
            for _ in 0 ..< min(Int(d4) &+ 1, max(0, budget)) { mix() }
            return
        }
        var d0 = UInt16(truncatingIfNeeded: (UInt32(phaseRate) &* rate) >> 11)
        let direction = word(a2 &+ 0x18)
        let product = Int32(Int16(bitPattern: d0)) &* Int32(Int16(bitPattern: direction))
        let low = UInt16(truncatingIfNeeded: product)
        let place = word(a2 &+ 0x16)
        let (sum, overflow) = Int16(bitPattern: low).addingReportingOverflow(Int16(bitPattern: place))
        d0 = UInt16(bitPattern: sum)
        if overflow {
            if d0 == 0x8000 { d0 = d0 &+ direction }
            setWord(a2 &+ 0x18, 0 &- direction)
            d0 = 0 &- d0
        }
        setWord(a2 &+ 0x16, d0)
        let swing = Int32(Int16(bitPattern: d0)) &* Int32(Int16(bitPattern: phaseDepth))
        let shift = UInt32((0x11 &+ octave) & 63)
        let moved = UInt16(truncatingIfNeeded: shift >= 32 ? (swing < 0 ? -1 : 0) : swing >> Int32(shift))
        let first = length &+ moved, second = length &- moved
        func squeeze(_ count: UInt16, from start: UInt16) {
            guard count != 0 else { return }
            var at = start, error: UInt16 = 0
            let whole = UInt16(0x40 / UInt32(count)), part = UInt16(0x40 % UInt32(count))
            var left = count
            repeat {
                setByte(a4, byte(a0 &+ UInt32(bitPattern: Int32(Int16(bitPattern: at)))))
                a4 &+= 1
                var x: UInt16 = 0
                let (less, borrow) = error.subtractingReportingOverflow(part)
                error = less
                if borrow {
                    let (more, carry) = error.addingReportingOverflow(count)
                    error = more
                    x = carry ? 1 : 0
                }
                at = at &+ whole &+ x
                left &-= 1
                budget &-= 1
            } while left != 0 && budget > 0
        }
        squeeze(first, from: 0)
        squeeze(second, from: 0x40)
    }

    // MARK: The sampled instrument

    /// `lbC00DB0A` / `lbC0014FE`: as SNX's (`snxSampled`), its state at `sampled` and $14 bytes each (0
    /// and 4 its loop, 6 its period, 8 its envelope's phase and 10 its value, 14 its vibrato's place,
    /// $10 the ticks before it starts, $12 its value), but its loop kept for the tick after its start,
    /// its start counted at 10 of the voice; no note marked to begin in its envelope; its volume the
    /// score's times the note's; stopping the voice turns it off. Returns true for a sample just begun.
    private mutating func scoreSampled(_ v: Int) -> Bool {
        let l = layout
        let a1 = scoreVoice(v)
        let a3 = long(a1 &+ 4) &+ l.sampledDelta
        let a2 = sonixAt &+ l.sampled &+ 0x14 &* UInt32(v)
        let rate = UInt32(sWord(l.rate))
        let command = byte(a1)
        if command == 1 {
            let a5 = long(a3 &+ 4)
            let note = UInt16(byte(a1 &+ 3))
            let q = note / 12, step = Int(note % 12)
            let octave = UInt8(truncatingIfNeeded: 10 &- q)
            let highest = Int8(bitPattern: byte(a5 &+ 5)), lowest = Int8(bitPattern: byte(a5 &+ 4))
            if Int8(bitPattern: octave) > highest || Int8(bitPattern: octave) < lowest {
                setByte(a1, 0)
                if byte(a1 &+ 1) == 0 { return word(a1 &+ 10) == 2 }
            } else {
                if byte(a1 &+ 1) == 0 { setLong(a2 &+ 10, 0) }
                if byte(a1 &+ 1) != 1 { setWord(a2 &+ 8, 0) }
                setWord(a2 &+ 6, UInt16(truncatingIfNeeded: (UInt32(0xD5C8) &* UInt32(SonixTables.semitones[step])) >> 15))
                let shift = UInt32(octave) & 63
                let d4: UInt32 = shift >= 32 ? 0 : 1 << shift
                let lowest = UInt32(byte(a5 &+ 4)) & 63
                let blocks = d4 &- (lowest >= 32 ? 0 : 1 << lowest)
                let start = a5 &+ 0x3E &+ (blocks & 0xFFFF) &* UInt32(word(a5))
                setLong(a1 &+ 12, start)
                setWord(a1 &+ 0x10, UInt16(truncatingIfNeeded: (UInt32(word(a5)) &* (d4 & 0xFFFF)) >> 1))
                var loop = long(sonixAt &+ l.chip) &+ 0x400
                var loopLength: UInt16 = 4
                if word(a5 &+ 2) != word(a5) {
                    loop = start &+ UInt32(word(a5 &+ 2)) &* (d4 & 0xFFFF)
                    loopLength = UInt16(truncatingIfNeeded: (UInt32(word(a5) &- word(a5 &+ 2)) &* (d4 & 0xFFFF)) >> 1)
                }
                setLong(a2, loop)
                setWord(a2 &+ 4, loopLength)
                setWord(a2 &+ 14, 0)
                setWord(a2 &+ 0x10, Self.divide(UInt32(word(a3 &+ 0x1E)) << 15, by: rate) >> 1)
                setWord(a1 &+ 10, 2)
                silenceScoreVoice(v)
            }
        } else if command == 2 {
            setWord(a2 &+ 8, 6)
        } else if command == 3 {
            silenceScoreVoice(v)
            return word(a1 &+ 10) == 2
        }
        vibrateTriangle(info: a3, delayAt: a2 &+ 0x10, placeAt: a2 &+ 14, valueAt: a2 &+ 0x12, speed: 0x1C, rate: rate)
        scoreEnvelopeStep(info: a3, phaseAt: a2 &+ 8, valueAt: a2 &+ 10, levels: 10, rates: 0x12, rate: rate)
        var d1 = Self.mulsWordShift(word(a2 &+ 0x12), word(a3 &+ 0x1A), 7)
        d1 = d1 &- (sWord(4) &- 0x80)
        d1 = d1 &+ 0x1000
        setWord(a1 &+ 0x12, UInt16(truncatingIfNeeded: (UInt32(word(a2 &+ 6)) &* UInt32(d1)) >> 19))
        var volume = UInt16(truncatingIfNeeded: (UInt32(sWord(0) &+ 1)) &* UInt32(word(a1 &+ 8))) >> 8 &+ 1
        volume = UInt16(truncatingIfNeeded: UInt32(volume) &* UInt32(word(a3 &+ 8))) >> 8
        volume = UInt16(truncatingIfNeeded: UInt32(volume) &* UInt32(word(a2 &+ 10))) >> 10
        setWord(a1 &+ 0x14, volume)
        return word(a1 &+ 10) == 2
    }

    // MARK: The 8SVX instrument

    /// `lbC00DD92` / `lbC00190A`: as SNX's (`snxIFF`), its state at `iff` and 10 bytes each (0 and 4 its
    /// loop, 6 its period, 8 whether it sounds), its loop kept for the tick after its start, its volume
    /// the score's times the note's, the octave's sample's place found from its start: TINY's own 8SVX
    /// keeps its sound at $1A of its file, the others at the place in their header (at $3A).
    private mutating func scoreIFF(_ v: Int) -> Bool {
        let l = layout
        let a1 = scoreVoice(v)
        let info = long(a1 &+ 4)
        let a3 = info &+ l.iffDelta
        let a2 = sonixAt &+ l.iff &+ 10 &* UInt32(v)
        let command = byte(a1)
        if command == 1 {
            let a5 = kind == .tiny ? info &+ 0x1A : long(info &+ 0x3A)
            let note = UInt16(byte(a1 &+ 3))
            let q = note / 12, step = Int(note % 12)
            setWord(a2 &+ 6, UInt16(truncatingIfNeeded: (UInt32(0xD5C8) &* UInt32(SonixTables.semitones[step])) >> 15))
            let octave = (10 &- q) &- word(a3 &+ 0x18)
            let octaves = Int8(bitPattern: byte(a3 &+ 0x12))
            if Int16(bitPattern: octave) < 0 || Int8(bitPattern: UInt8(truncatingIfNeeded: octave)) >= octaves {
                setByte(a1, 0)
                if byte(a1 &+ 1) == 0 { return word(a1 &+ 10) == 2 }
            } else {
                let shift = UInt32(octave) & 63
                func shifted(_ x: UInt32) -> UInt32 { shift >= 32 ? 0 : x << shift }
                let d4 = long(a3 &+ 4), d5 = long(a3 &+ 8)
                let both = d4 &+ d5
                var a0 = a5 &+ (shifted(both) &- both)
                let first = shifted(d4), loop = shifted(d5)
                var d0 = UInt16(truncatingIfNeeded: first)
                if d0 == 0 { d0 = UInt16(truncatingIfNeeded: loop) }
                setLong(a1 &+ 12, a0)
                setWord(a1 &+ 0x10, d0 >> 1)
                a0 &+= UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: first)))
                d0 = UInt16(truncatingIfNeeded: loop)
                if d0 == 0 {
                    a0 = long(sonixAt &+ l.chip) &+ 0x400
                    d0 = 8
                }
                setLong(a2, a0)
                setWord(a2 &+ 4, d0 >> 1)
                setWord(a1 &+ 10, 2)
                silenceScoreVoice(v)
                setWord(a2 &+ 8, 1)
            }
        } else if command == 2 {
            setWord(a2 &+ 8, 0)
        } else if command == 3 {
            silenceScoreVoice(v)
            return word(a1 &+ 10) == 2
        }
        setWord(a1 &+ 0x12, UInt16(truncatingIfNeeded: (UInt32(0x1080 &- sWord(4)) &* UInt32(word(a2 &+ 6))) >> 19))
        let scaled = UInt16(truncatingIfNeeded: UInt32(sWord(0) &+ 1) &* UInt32(word(a1 &+ 8))) >> 8
        let volume = UInt32(scaled &+ 1)
        let level = (long(a3 &+ 0x14) >> 1) & 0xFFFF
        let heard = UInt16(truncatingIfNeeded: (volume &* level) >> 17)
        setWord(a1 &+ 0x14, UInt16(truncatingIfNeeded: UInt32(heard) &* UInt32(word(a2 &+ 8))))
        return word(a1 &+ 10) == 2
    }
}
