// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after UADE's Paula (src/audio.c, `audio_handler`, `AUDxDAT`, `AUDxPER`; src/custom.c, `DMACON`
// and `hsync_handler`), whose timing of her interrupts the reference recordings have.

/// When Paula's voices ask for their interrupts, which Ben Daglish's driver needs and siday's Amiga
/// (`AmigaMachine`) does not give: a voice asks for one as it starts (on the second line of the beam
/// after its DMA is turned on), and again each time it starts the last word of what it is playing, as it
/// goes round to its start again; and one whose DMA is off and that is not asking already asks as it
/// finishes the word it is on, or once given a word by hand (AUDxDAT). The interrupts are asked for in
/// the machine's INTREQ (`AmigaChips`), where the driver clears them and enables them, and where whoever
/// answers them (`DaglishPlayer`) finds them.
///
/// A voice's time goes by her period, a byte at a time, and her DMA fetches words at the start of each
/// line of the beam; only what the timing of her interrupts needs is kept, not what she plays.
struct DaglishPaula {
    private struct Voice {
        /// UADE's states: 0 silent, 1 and 5 starting, 2 and 3 playing a word's first and second byte.
        var state: UInt8 = 0
        /// When the state is next stepped.
        var due: UInt64 = 0
        /// Her period and length as last written (her period as UADE takes it: none is 65,535, and none
        /// less than 16).
        var period: UInt16 = 0xFFFF
        var length: UInt16 = 0
        /// The words left to fetch of what she plays, as her counter has it (nought for 65,536).
        var wordsLeft: UInt16 = 0
        /// Her last word fetched: she asks for an interrupt as she starts it.
        var lastWordFetched = false
        /// A word is to be fetched at the start of the next line.
        var fetchDue = false
        var dmaOn = false
    }

    private var voices = InlineArray<4, Voice>(repeating: Voice())
    private var dmacon: UInt16 = 0
    /// How far her time has been taken, in Paula's clocks since the machine was switched on.
    private(set) var time: UInt64 = 0
    private let chips: AmigaChips

    init(_ chips: AmigaChips) {
        self.chips = chips
    }

    /// As the machine is switched on: every voice silent.
    mutating func reset() {
        voices = InlineArray(repeating: Voice())
        dmacon = 0
        time = 0
    }

    // MARK: Writes

    /// A write to her registers or the DMA's, at its time (which, for one made earlier than her time has
    /// been taken, is taken as now). Returns the time a voice asked for an interrupt on the way to it, if
    /// one did, before which the write is not yet made: answer it, and make the write again.
    mutating func write(_ register: UInt16, _ value: UInt16, at: UInt64) -> UInt64? {
        if let asked = run(to: at) { return asked }
        switch register {
        case 0x096:
            dmacon = value & 0x8000 != 0 ? dmacon | value & 0x7FFF : dmacon & ~value
            for v in 0 ..< 4 {
                voices[v].dmaOn = dmacon & 0x200 != 0 && dmacon & (1 << UInt16(v)) != 0
                if voices[v].dmaOn {
                    if voices[v].state == 0 {
                        // (custom.c's DMACON: started at the next line, the first of the two.)
                        voices[v].state = 1
                        voices[v].wordsLeft = voices[v].length
                        voices[v].fetchDue = true
                        voices[v].due = (time / UInt64(AmigaChips.lineClocks) + 1) * UInt64(AmigaChips.lineClocks)
                    }
                } else if voices[v].state == 1 || voices[v].state == 5 {
                    voices[v].state = 0
                }
            }
        case 0x0A0 ..< 0x0E0:
            let v = Int(register - 0xA0) >> 4
            switch register & 0xF {
            case 0x4:
                voices[v].length = value
            case 0x6:
                voices[v].period = value == 0 ? 0xFFFF : max(16, value)
            case 0xA:
                // A word given by hand, to a voice that is silent and not asking: she plays it, and asks.
                if voices[v].state == 0, chips.intreq & Self.bit(v) == 0 {
                    voices[v].state = 2
                    voices[v].due = time &+ UInt64(voices[v].period)
                    ask(v)
                    return time
                }
            default:
                break
            }
        default:
            break
        }
        return nil
    }

    // MARK: Time

    /// When one of the voices whose interrupts are enabled (their bits of INTENA in `enabled`) is next
    /// stepped, the soonest she may ask for one; nil if none of them is playing.
    func nextStep(of enabled: UInt16) -> UInt64? {
        var next: UInt64?
        for v in 0 ..< 4 where voices[v].state != 0 && enabled & Self.bit(v) != 0 {
            next = min(next ?? .max, voices[v].due)
        }
        return next
    }

    /// Takes her time on to `to`, stepping each voice as it comes due and fetching words as each line
    /// begins. Stops early, at the time, as a voice asks for an interrupt; nil if none did.
    mutating func run(to: UInt64) -> UInt64? {
        let line = UInt64(AmigaChips.lineClocks)
        while true {
            // (Loops of their own rather than over ranges, which the compiler had left as calls.)
            var next = UInt64.max
            var v = 0
            while v < 4 {
                if voices[v].state != 0 { next = min(next, voices[v].due) }
                if voices[v].fetchDue { next = min(next, (time + line - 1) / line * line) }
                v += 1
            }
            guard next <= to else {
                time = max(time, to)
                return nil
            }
            time = max(time, next)
            // (As hsync_handler has it: the voices' steps that fall now first, then the fetches.)
            var asked = false
            v = 0
            while v < 4 {
                if voices[v].state != 0, voices[v].due <= time, step(v) { asked = true }
                v += 1
            }
            if time % line == 0 {
                v = 0
                while v < 4 {
                    if voices[v].fetchDue { fetch(v) }
                    v += 1
                }
            }
            if asked { return time }
        }
    }

    @inline(__always) private static func bit(_ v: Int) -> UInt16 { 0x80 << UInt16(v) }

    private func ask(_ v: Int) {
        chips.write16(AmigaChips.custom + 0x9C, 0x8000 | Self.bit(v))
    }

    /// audio.c's `audio_handler`. True if the voice asked for an interrupt.
    private mutating func step(_ v: Int) -> Bool {
        let now = voices[v].due
        switch voices[v].state {
        case 1:
            voices[v].due = now + UInt64(AmigaChips.lineClocks)
            voices[v].state = 5
            if voices[v].wordsLeft != 1 { voices[v].wordsLeft &-= 1 }
            ask(v)
            return true
        case 5:
            voices[v].due = now + UInt64(voices[v].period)
            voices[v].state = 2
            voices[v].fetchDue = true
        case 2:
            voices[v].due = now + UInt64(voices[v].period)
            voices[v].state = 3
        case 3:
            voices[v].due = now + UInt64(voices[v].period)
            if chips.intreq & Self.bit(v) != 0, !voices[v].dmaOn {
                voices[v].state = 0
                return false
            }
            voices[v].state = 2
            let asks = voices[v].lastWordFetched || !voices[v].dmaOn
            voices[v].lastWordFetched = false
            if voices[v].dmaOn { voices[v].fetchDue = true }
            if asks {
                ask(v)
                return true
            }
        default:
            voices[v].state = 0
        }
        return false
    }

    /// custom.c's `hsync_handler`: a word fetched; the last of what she plays, and she goes round to
    /// its start.
    private mutating func fetch(_ v: Int) {
        voices[v].fetchDue = false
        guard voices[v].state == 2 || voices[v].state == 3 else { return }
        if voices[v].wordsLeft == 1 {
            voices[v].wordsLeft = voices[v].length
            voices[v].lastWordFetched = true
        } else {
            voices[v].wordsLeft &-= 1
        }
    }
}
