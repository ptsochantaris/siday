// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the audio state machine of UADE's UAE (src/audio.c, `audio_handler`; src/custom.c, `DMACON`
// and `hsync_handler`), GPL-2.0-or-later, so that a player's audio interrupts come when they come in UADE.

/// When Paula's voices ask for their interrupts: as each takes up the location and the length a player
/// has written for it, and so is ready for the next. A player that feeds its voices from the audio
/// interrupts (level 4, as Rob Hubbard's do) is called then; one that waits for a voice to have started
/// reads the request in INTREQR.
///
/// Only the timing is kept here, not the sound, which `PaulaTickRenderer` plays from the same writes.
/// A voice goes as UAE's does: its DMA turned on, it starts at the next line of the beam and asks for its
/// interrupt there; a line later it plays its first word, each byte for its period; each word it plays
/// asks for the next to be fetched, which is done at the start of the next line; and the fetch of the
/// block's last word takes up the location and length again, whose interrupt is asked for as that last
/// word begins to be heard.
struct AmigaAudioDMA {
    private struct Voice {
        /// UAE's states: 0 stopped; 1 started, waiting for the line; 5 a line later; 2 and 3 playing the
        /// first and the second byte of a word.
        var state = 0
        /// When the state is next moved on, in Paula's clocks.
        var due: UInt64 = 0
        var location: UInt32 = 0
        var length: UInt16 = 0
        var period: UInt64 = 65535
        /// The words left of the block being fetched, and whether a fetch is waiting for the next line.
        var wordsLeft: UInt16 = 0
        var fetch = false
        /// The block was taken up again at the last fetch: its interrupt is asked for with the next word.
        var reloaded = false
        var dma = false
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// When the next line of the beam starts, in Paula's clocks.
    private var nextLine = UInt64(AmigaChips.lineClocks)

    /// Moves the voices on to `time`, asking in `intreq` for the interrupts that come due on the way.
    mutating func run(to time: UInt64, intreq: inout UInt16, adkcon: UInt16) {
        let line = UInt64(AmigaChips.lineClocks)
        while true {
            var soonest = nextLine
            var idle = true
            for v in 0 ..< 4 where voices[v].state != 0 || voices[v].fetch {
                idle = false
                if voices[v].state != 0 { soonest = min(soonest, voices[v].due) }
            }
            if idle {
                // (Nothing to do on any line until a voice is started.)
                if nextLine <= time { nextLine = (time / line + 1) * line }
                return
            }
            if soonest > time { return }
            // (At the start of a line, its fetches come before what falls due with it: so UADE's voices
            // go, whose first block lasts as long as the rest, a line for each of its words when they
            // are played faster than the lines come.)
            if soonest == nextLine {
                fetchWords()
                nextLine += line
            }
            for v in 0 ..< 4 where voices[v].state != 0 && voices[v].due == soonest {
                step(v, at: soonest, &intreq, adkcon)
            }
        }
    }

    /// The soonest a voice could next ask for its interrupt: nil while none is playing.
    var nextEvent: UInt64? {
        var soonest: UInt64?
        for v in 0 ..< 4 where voices[v].state != 0 {
            let voice = voices[v]
            let t: UInt64
            switch voice.state {
            case 1, 5:
                t = voice.due
            default:
                // A word's second byte ends it, and asks for the interrupt once the block has been taken
                // up again (or with each word, once its DMA is off); otherwise a fetch at the next line
                // may take it up.
                let wordEnds = voice.state == 3 ? voice.due : voice.due + voice.period
                t = voice.reloaded || !voice.dma ? wordEnds : min(wordEnds, nextLine)
            }
            soonest = min(soonest ?? t, t)
        }
        return soonest
    }

    /// UAE's `audio_handler`.
    private mutating func step(_ v: Int, at time: UInt64, _ intreq: inout UInt16, _ adkcon: UInt16) {
        let bit = UInt16(0x80) << UInt16(v)
        // A voice whose volume or period modulates another's plays nothing of its own.
        let modulatesVolume = adkcon & (1 << UInt16(v)) != 0
        let modulatesPeriod = adkcon & (0x10 << UInt16(v)) != 0
        let plain = !modulatesPeriod || modulatesVolume
        switch voices[v].state {
        case 1:
            voices[v].due = time + UInt64(AmigaChips.lineClocks)
            voices[v].state = 5
            intreq |= bit
            if voices[v].wordsLeft != 1 { voices[v].wordsLeft &-= 1 }
        case 5:
            voices[v].due = time + voices[v].period
            voices[v].state = 2
            if plain { voices[v].fetch = true }
        case 2:
            voices[v].due = time + voices[v].period
            voices[v].state = 3
            if modulatesPeriod {
                if voices[v].reloaded, voices[v].dma { intreq |= bit }
                voices[v].reloaded = false
                if voices[v].dma { voices[v].fetch = true }
            }
        case 3:
            voices[v].due = time + voices[v].period
            if intreq & bit != 0, !voices[v].dma {
                voices[v].state = 0
                return
            }
            voices[v].state = 2
            if (voices[v].reloaded && voices[v].dma && plain) || (plain && !voices[v].dma) { intreq |= bit }
            voices[v].reloaded = false
            if voices[v].dma, plain { voices[v].fetch = true }
        default:
            voices[v].state = 0
        }
    }

    /// UAE's fetching of the words asked for, at the start of a line.
    private mutating func fetchWords() {
        for v in 0 ..< 4 where voices[v].fetch {
            voices[v].fetch = false
            guard voices[v].state == 2 || voices[v].state == 3 else { continue }
            if voices[v].wordsLeft == 1 {
                voices[v].wordsLeft = voices[v].length
                voices[v].reloaded = true
            } else {
                voices[v].wordsLeft &-= 1
            }
        }
    }

    /// A write to DMACON, as the DMA now stands (`dmacon`, with its master bit), at `time`.
    mutating func setDMA(_ dmacon: UInt16, at time: UInt64) {
        let line = UInt64(AmigaChips.lineClocks)
        for v in 0 ..< 4 {
            let on = dmacon & 0x200 != 0 && dmacon & (1 << UInt16(v)) != 0
            voices[v].dma = on
            if on {
                if voices[v].state == 0 {
                    voices[v].state = 1
                    voices[v].wordsLeft = voices[v].length
                    voices[v].fetch = true
                    voices[v].due = (time / line + 1) * line
                }
            } else if voices[v].state == 1 || voices[v].state == 5 {
                voices[v].state = 0
            }
        }
    }

    /// A write to one of a voice's registers (its offset from AUDxLCH), at `time`.
    mutating func write(_ v: Int, _ register: UInt16, _ value: UInt16, at time: UInt64, _ intreq: inout UInt16) {
        switch register {
        case 0x0: voices[v].location = voices[v].location & 0xFFFF | UInt32(value) << 16
        case 0x2: voices[v].location = voices[v].location & 0xFFFF_0000 | UInt32(value & 0xFFFE)
        case 0x4: voices[v].length = value
        case 0x6:
            // (UAE plays a period of nought as the longest, and none shorter than 16.)
            voices[v].period = value == 0 ? 65535 : UInt64(max(16, value))
        case 0xA:
            // A word written by hand to a voice that is stopped plays it, and asks for the next.
            let bit = UInt16(0x80) << UInt16(v)
            if voices[v].state == 0, intreq & bit == 0 {
                voices[v].state = 2
                intreq |= bit
                voices[v].due = time + voices[v].period
            }
        default:
            break
        }
    }
}
