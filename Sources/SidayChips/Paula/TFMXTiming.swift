// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// How long a TFMX player's ticks are, in Paula's clocks.
///
/// A player of four voices runs as often as the song's tempo says: fifty times a second unless it
/// says otherwise, or two fifths of its beats a minute. (libtfmxaudiodecoder keeps that as a rate in
/// 256ths of a tick a second, `TFMXDecoder.rate`, and so is it kept here; but fifty a second is
/// played each frame, as Chris Hülsbeck's players and Jochen Hippel's COSO ran a song that sets no timer
/// (TFMX Pro's `installtimer` leaves "vbi" running; "CALL h_replay each vbi", says Hippel's), and a
/// tempo the player sets as a timer, as they did.)
///
/// The player of TFMX 7V runs as often as Paula's fourth voice comes to the end of the buffer it mixes
/// the four voices of that one into: as Chris Hülsbeck's player of it, kept in Wanted Team's player for
/// EaglePlayer ("TFMX 7V player module V1.1", carried by UADE as `TFMX-7V`), has it, a buffer of
/// 320 bytes at its rate of mixing of 16 kHz, made longer or shorter by the song's 7VOICE command, and
/// played at a period of 224, from its table of periods for each thousand mixed a second (3,580
/// divided by the thousands).
package struct TFMXTiming {
    package init() {}

    /// The part of a clock over from the ticks before, in 256ths of a tick a second.
    private var carry: UInt64 = 0

    /// The period Paula's fourth voice plays the mixed buffers at in Chris Hülsbeck's TFMX 7V.
    static let sevenVoicePeriod = TFMXSevenVoices.Style.huelsbeck.period

    /// The length of a tick of a player of four voices: the CIA's timer counts down from `timer` at a
    /// fifth of Paula's clock, and takes one more count than it is set to to come round (as the 8520
    /// does, and UADE's `cia.c` has it: the timer runs out when a count would take it below nought).
    /// With none, at fifty ticks a second, the player is run by the frame (`frame`), if its own players
    /// were (`fiftyIsTheFrame`); otherwise by the timer DeliTracker and UADE set for it, $376B (UADE's
    /// `score.s`). At any other rate, at the rate the library has (in 256ths of a tick a second).
    package mutating func fourVoiceTick(rate: UInt32, timer: UInt16?, fiftyIsTheFrame: Bool = false) -> Int {
        if let timer { return (Int(timer) + 1) * 5 }
        if rate == 50 << 8 { return fiftyIsTheFrame ? Self.frame : Self.fiftyTimes }
        let whole = UInt64(Paula.clockHz) * 256 + carry
        let rate = UInt64(max(rate, 1))
        carry = whole % rate
        return Int(whole / rate)
    }

    /// A tick of the timer DeliTracker and UADE run a player by, fifty times a second and a little
    /// less: 14,188 counts of the CIA's, each five of Paula's clocks.
    package static let fiftyTimes = (0x376B + 1) * 5
    /// A frame of a PAL Amiga that has started its Kickstart, by whose interrupt (the vertical blank) many
    /// players were run: 313 lines of 227 of Paula's clocks, 49.92 times a second.
    package static let frame = 313 * 227

    /// The timer a song's tempo sets as it starts: a tempo of 16 or more is beats a minute, which TFMX
    /// Professional's player takes as $1B51F8 over them, and the first player, from 32, as $1C00 over
    /// them, in its timer's upper byte. (The 68000's division, when it would come to more than a word,
    /// leaves what was to be divided, of which the lower word is taken.)
    package static func timerAtStart(speed: Int, old: Bool) -> UInt16? {
        if old {
            guard speed > 31 else { return nil }
            return UInt16(truncatingIfNeeded: (0x1C00 / speed) << 8)
        }
        guard speed >= 0x10 else { return nil }
        return proTimer(speed)
    }

    /// The timer after the song's Speed command: its second word, unless it is below nought or nought,
    /// as beats a minute (of its lower nine bits). TFMX Professional's player sets the whole timer
    /// (its `speedsong`). The first player puts its division into the upper byte of CIA B's timer B
    /// only, leaving the lower as it was: nought after a tempo the song started with, or $F0 from the
    /// $37F0 its TIMERINIT starts the timer at for a song that set none (Chris Hülsbeck's code, which
    /// Wanted Team's player keeps as comments where it sets DeliTracker's timer in its place). With no
    /// beats a minute, a song that started with no timer is run by the frame again (TFMX 1.x, $fe0 to
    /// $1024: $4A(a6), whether the timer runs the player, is set to $5C(a6), whether the song's start
    /// set a timer, and then to one if a timer is set). `startedWithTimer` is whether it did.
    package static func timer(afterSpeed word: UInt16, was: UInt16?, old: Bool, startedWithTimer: Bool = true) -> UInt16? {
        guard word & 0x8000 == 0, word & 0x1FF != 0 else { return old && !startedWithTimer ? nil : was }
        let bpm = Int(word & 0x1FF)
        if old { return UInt16(truncatingIfNeeded: (0x1C00 / bpm) & 0xFF) << 8 | (was ?? 0x37F0) & 0xFF }
        return proTimer(bpm)
    }

    private static func proTimer(_ bpm: Int) -> UInt16 {
        let quotient = 0x1B51F8 / bpm
        return UInt16(truncatingIfNeeded: quotient > 0xFFFF ? 0x1B51F8 : quotient)
    }

    /// The length of a tick of TFMX 7V's player, with the change to its tempo the song asks for.
    package mutating func sevenVoiceTick(tempo: Int) -> Int {
        TFMXSevenVoices.Style.huelsbeck.tickClocks(tempo: tempo)
    }

    /// How many bytes TFMX 7V's player mixes for each tick: twenty for each thousand a second it mixes
    /// at, times the tempo in hundredths, and one more, made even. (A tempo is never below -32.)
    static func sevenVoiceBytes(tempo: Int) -> Int {
        TFMXSevenVoices.Style.huelsbeck.mixedBytes(tempo: tempo)
    }
}
