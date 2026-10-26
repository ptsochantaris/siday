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
struct AmigaAudioDMA: Equatable {
    private struct Voice: Equatable {
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
    /// Whether a voice playing a word written by hand (AUDxDAT) whose DMA is turned on takes up its
    /// location and length at its next fetch, its length left taken as run out (see
    /// `AmigaChips.manualWordStartsBlock`). Off, it goes on through the length it had left, as the rest
    /// of this model has it.
    var manualWordStartsBlock = false


    static func == (a: Self, b: Self) -> Bool {
        // (Not by when they are next to be looked at, which only one of them keeps.)
        a.nextLine == b.nextLine && (0 ..< 4).allSatisfy { a.voices[$0] == b.voices[$0] }
    }

    /// Moves the voices on to `time`, asking in `intreq` for the interrupts that come due on the way.
    ///
    /// Each voice goes on by itself, since none of them changes another, what it does at the start of a
    /// line coming before what falls due for it with the line: as `runByStepping` moves them on, together
    /// and a step at a time, as UAE does, which this is checked against. A voice playing its block as it
    /// was given goes the same way at every word, and so many of its words are gone over at once
    /// (`skipWords`), as far as the next interrupt it asks for.
    mutating func run(to time: UInt64, intreq: inout UInt16, adkcon: UInt16) {
        let line = UInt64(AmigaChips.lineClocks)
        if time >= quietUntil {
            var v = 0
            while v < 4 {
                if voices[v].state != 0 || voices[v].fetch {
                    Self.advance(&voices[v], bit: UInt16(0x80) << UInt16(v), to: time, lineAt: nextLine, &intreq,
                                 modulatesVolume: adkcon & (1 << UInt16(v)) != 0, modulatesPeriod: adkcon & (0x10 << UInt16(v)) != 0)
                }
                v += 1
            }
            if nextLine <= time { nextLine = (time / line + 1) * line }
            // (Until the soonest a voice next does anything, nothing need be looked at.)
            var soonest = UInt64.max
            v = 0
            while v < 4 {
                if voices[v].state != 0 { soonest = min(soonest, voices[v].due) }
                if voices[v].fetch { soonest = min(soonest, nextLine) }
                v += 1
            }
            quietUntil = soonest
        } else if nextLine <= time {
            nextLine = (time / line + 1) * line
        }
    }

    /// Before when no voice does anything (see `run(to:)`): what the voices are told sets it back.
    private var quietUntil: UInt64 = 0

    /// One voice's part of `run(to:)`: its fetches at the starts of lines (the first line not yet gone by
    /// being `first`) and its steps, in time, until `time`; or, to find when it next asks for its
    /// interrupt (`stopsAtRequest`), until the step that does, whose time is returned.
    @discardableResult
    private static func advance(_ voice: inout Voice, bit: UInt16, to time: UInt64, lineAt first: UInt64, _ intreq: inout UInt16,
                                modulatesVolume: Bool, modulatesPeriod: Bool, stopsAtRequest: Bool = false) -> UInt64?
    {
        let line = UInt64(AmigaChips.lineClocks)
        var lineAt = first
        while true {
            let stepping = voice.state != 0
            if voice.fetch, lineAt <= time, !stepping || lineAt <= voice.due {
                fetchWord(&voice)
                lineAt += line
                continue
            }
            guard stepping, voice.due <= time else { return nil }
            if !modulatesPeriod, voice.dma, !voice.reloaded, voice.state == 2 || voice.state == 3, time - voice.due > 8 * voice.period,
               skipWords(&voice, bit: bit, to: time, lineAt: &lineAt, intreq)
            {
                continue
            }
            let at = voice.due
            step(&voice, bit: bit, at: at, &intreq, modulatesVolume: modulatesVolume, modulatesPeriod: modulatesPeriod)
            if stopsAtRequest, intreq & bit != 0 { return at }
            // (A fetch asked for now is done at the next line; the lines before it had none to do.)
            if lineAt <= at { lineAt = (at / line + 1) * line }
        }
    }

    /// Goes over as many whole words of a voice playing its block as can be gone over at once, as stepping
    /// through them would: to just after the end of the last word that ends by `time` before the voice
    /// would ask for its interrupt (or the last that ends by then at all, if it has asked already, and so
    /// asking again changes nothing). The voice is playing a word, its DMA on and its period modulating no
    /// other's, and nothing was taken up at its last fetch.
    ///
    /// Its words end every two periods, each asking for a fetch at the next line. Words that last a line or
    /// more each have a line of their own for it; shorter ones leave a fetch waiting at every line. Every
    /// fetch but the one that takes up the block again counts a word off; that one, and the end of the
    /// next word, which asks for the interrupt, are left to be stepped through.
    /// False, and nothing changed, where there are too few to go over.
    private static func skipWords(_ voice: inout Voice, bit: UInt16, to time: UInt64, lineAt: inout UInt64, _ intreq: UInt16) -> Bool {
        let line = UInt64(AmigaChips.lineClocks)
        let word = 2 * voice.period
        // The end of the word being played.
        let firstEnd = voice.state == 3 ? voice.due : voice.due + voice.period
        guard time >= firstEnd else { return false }
        let longWords = word >= line
        let waiting = voice.fetch
        // (A fetch left waiting from before is done before the word being played ends, and for short words
        // within a line of its end: otherwise this is not the voice described, and it is stepped through.)
        if waiting, lineAt > firstEnd || !longWords && firstEnd - lineAt >= line { return false }
        // The line of the first fetch.
        let firstFetch = waiting ? lineAt : (firstEnd / line + 1) * line
        // Fetches until the block is taken up again, that one included.
        let toReload = UInt64(voice.wordsLeft == 0 ? 65536 : Int(voice.wordsLeft))
        var j = (time - firstEnd) / word
        if intreq & bit == 0 {
            // No further than the last word whose fetches stop short of taking it up again.
            guard toReload > 1 else { return false }
            if longWords {
                let most = toReload - 1 - (waiting ? 1 : 0)
                j = min(j, most)
            } else {
                // The word that ends before the line of the fetch that takes it up.
                let reloadLine = firstFetch + (toReload - 1) * line
                guard reloadLine > firstEnd else { return false }
                j = min(j, (reloadLine - 1 - firstEnd) / word)
            }
        }
        guard j >= 2 else { return false }
        // The fetches done by the end of the word `j` words on, that end included (its own is done after it).
        let end = firstEnd + j * word
        let done = longWords ? (waiting ? 1 : 0) + j : end >= firstFetch ? (end - firstFetch) / line + 1 : 0
        if done < toReload {
            voice.wordsLeft = UInt16(truncatingIfNeeded: toReload - done)
        } else {
            // (Only once the interrupt has been asked for: the block taken up again every `block` fetches.)
            let block = UInt64(voice.length == 0 ? 65536 : Int(voice.length))
            voice.wordsLeft = UInt16(truncatingIfNeeded: block - (done - toReload) % block)
        }
        voice.state = 2
        voice.due = end + voice.period
        voice.fetch = true
        voice.reloaded = false
        lineAt = (end / line + 1) * line
        return true
    }

    /// Moves the voices on to `time` together, a step at a time, as UAE does: what `run(to:)` does, and
    /// what it is checked against.
    mutating func runByStepping(to time: UInt64, intreq: inout UInt16, adkcon: UInt16) {
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
                for v in 0 ..< 4 where voices[v].fetch { Self.fetchWord(&voices[v]) }
                nextLine += line
            }
            for v in 0 ..< 4 where voices[v].state != 0 && voices[v].due == soonest {
                Self.step(&voices[v], bit: UInt16(0x80) << UInt16(v), at: soonest, &intreq,
                          modulatesVolume: adkcon & (1 << UInt16(v)) != 0, modulatesPeriod: adkcon & (0x10 << UInt16(v)) != 0)
            }
        }
    }

    /// When the first of the voices `wanted` (by their bits in INTREQ) whose request is clear in `intreq`
    /// next asks for its interrupt, if one does by `limit`: as `run(to:)` would find it. Nil for none.
    /// (No voice whose period modulates another's is to be among them: see `canTellRequests`.)
    ///
    /// (This and `nextEvent` are mutating, though they change nothing: asked of the chips' copy, a
    /// method that only reads it is handed a copy of all of it first.)
    mutating func nextRequest(of wanted: UInt16, intreq: UInt16, adkcon: UInt16, by limit: UInt64) -> UInt64? {
        var soonest: UInt64?
        for v in 0 ..< 4 {
            let bit = UInt16(0x80) << UInt16(v)
            guard wanted & bit != 0, intreq & bit == 0, voices[v].state != 0 else { continue }
            var voice = voices[v]
            var requests: UInt16 = 0
            if let t = Self.advance(&voice, bit: bit, to: soonest ?? limit, lineAt: nextLine, &requests,
                                    modulatesVolume: adkcon & (1 << UInt16(v)) != 0, modulatesPeriod: false, stopsAtRequest: true)
            {
                soonest = t
            }
        }
        return soonest
    }

    /// Whether `nextRequest` can say when the voices `wanted` ask: none of them modulating another's period.
    static func canTellRequests(of wanted: UInt16, adkcon: UInt16) -> Bool {
        (adkcon >> 4 & 0xF) & (wanted >> 7 & 0xF) == 0
    }

    /// The soonest a voice could next ask for its interrupt: nil while none is playing.
    var nextEvent: UInt64? {
        mutating get {
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
    }

    /// UAE's `audio_handler`. A voice whose volume or period modulates another's plays nothing of its own.
    private static func step(_ voice: inout Voice, bit: UInt16, at time: UInt64, _ intreq: inout UInt16,
                             modulatesVolume: Bool, modulatesPeriod: Bool)
    {
        let plain = !modulatesPeriod || modulatesVolume
        switch voice.state {
        case 1:
            voice.due = time + UInt64(AmigaChips.lineClocks)
            voice.state = 5
            intreq |= bit
            if voice.wordsLeft != 1 { voice.wordsLeft &-= 1 }
        case 5:
            voice.due = time + voice.period
            voice.state = 2
            if plain { voice.fetch = true }
        case 2:
            voice.due = time + voice.period
            voice.state = 3
            if modulatesPeriod {
                if voice.reloaded, voice.dma { intreq |= bit }
                voice.reloaded = false
                if voice.dma { voice.fetch = true }
            }
        case 3:
            voice.due = time + voice.period
            if intreq & bit != 0, !voice.dma {
                voice.state = 0
                return
            }
            voice.state = 2
            if (voice.reloaded && voice.dma && plain) || (plain && !voice.dma) { intreq |= bit }
            voice.reloaded = false
            if voice.dma, plain { voice.fetch = true }
        default:
            voice.state = 0
        }
    }

    /// UAE's fetching of a word asked for, at the start of a line.
    private static func fetchWord(_ voice: inout Voice) {
        voice.fetch = false
        guard voice.state == 2 || voice.state == 3 else { return }
        if voice.wordsLeft == 1 {
            voice.wordsLeft = voice.length
            voice.reloaded = true
        } else {
            voice.wordsLeft &-= 1
        }
    }

    /// A write to DMACON, as the DMA now stands (`dmacon`, with its master bit), at `time`.
    mutating func setDMA(_ dmacon: UInt16, at time: UInt64) {
        let line = UInt64(AmigaChips.lineClocks)
        quietUntil = 0
        for v in 0 ..< 4 {
            let on = dmacon & 0x200 != 0 && dmacon & (1 << UInt16(v)) != 0
            // (A word written by hand, being played as the DMA comes on: see `manualWordStartsBlock`.)
            if manualWordStartsBlock, on, !voices[v].dma, voices[v].state == 2 || voices[v].state == 3 { voices[v].wordsLeft = 1 }
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
        quietUntil = 0
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
