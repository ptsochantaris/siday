// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayChips

// Where Chris Hülsbeck's players of TFMX did otherwise than libtfmxaudiodecoder does, as UADE runs
// them: Wanted Team's players for EaglePlayer, which keep his players' code, "TFMX player module V1.3"
// (`TFMX`, of TFMX 1.x), "TFMX Pro player module V1.3" (`TFMX-Pro`) and the player of TFMX 7V
// (`TFMX-7V`), whose 68000 code was read for it. Each place in them is given by its address in its
// player file's code (for example "TFMX Pro, $2146").
//
// A module is played as one of them when the decoder follows them (`followsOriginalPlayers`), and
// then which one is chosen as UADE chooses: not by the library's reading of the header and its
// checksums of known modules, which are for players the games themselves had.

extension TFMXDecoder {
    /// Sets the module to be played as `player` plays it.
    mutating func setOriginalPlayer(_ player: OriginalPlayer) {
        switch player {
        case .tfmx:
            // As the library's TFMX 1.5 is, but for these.
            setTFMXv1()
            // The vibrato's time is as the macro gives it ($1454); SetNote keeps the voice's detune
            // ($13d8, by way of $13e0); the tracks' mutes in the header are not read (nothing in the
            // player sets 8(a0), which it tests).
            variant.vibratoTimeMask = false
            variant.setNoteV1 = false
            variant.noTrackMute = true
            // The macros it has that the library's TFMX 1.5 has not, by its table at $1592: AddVolume
            // with a note first ($136e), WaitOnDMA ($1266), SplitKey ($12ca), SplitVolume ($12e0) and
            // SetPrevNote ($13c4).
            macroTable[0x0D] = .addVolNote
            macroTable[0x1A] = .waitOnDMA
            macroTable[0x1C] = .splitKey
            macroTable[0x1D] = .splitVolume
            macroTable[0x1F] = .setPrevNote
        case .pro:
            format = .pro
            // UADE configures the player to wait for Paula as Chris Hülsbeck's did ("DMA", its
            // EP-TFMX_Pro.cfg, against Wanted Team's "VBI"): a voice is started at once ($192a), and
            // the commands that end a macro's tick always do ($1840 to $184e).
            variant.noDelayedDMAon = true
            variant.extraWaitV1 = true
        default:
            // The player of TFMX 7V waits as the library's TFMX Pro does: a voice is started at the end
            // of the tick ($fc2), and stopped then too if the DMAoff asks ($1672). It has no WaitOnDMA
            // (its table at $1542 has nothing for $1A), and reads no tracks' mutes ($fdc).
            format = .pro
            macroTable[0x1A] = .nop
            variant.noTrackMute = true
        }
        variant.original = player == .none ? .pro : player
    }

    /// Wanted Team's players mend a few modules as they read them, and so UADE plays them so: in
    /// TFMX 1.x's, song 3 of one ends a step sooner and song 6 of another three ($740, $778); in TFMX
    /// Pro's, song 9 of one ends where it begins ($c2a), song 4 of a few begins a step sooner ($d98),
    /// and a wait in Turrican 2's world 1 is a tick shorter ($ea6). Each module is known by the words
    /// mended and by where its macros end (or, packed, where the place of its last macro is).
    mutating func mendAsWantedTeam() {
        let h = offsets.header
        func w(_ at: UInt32) -> UInt16 { word(h &+ at) }
        let packed = long(h &+ 0x1D0) != 0
        switch variant.original {
        case .tfmx:
            guard !packed, let end = macrosEnd() else { return }
            if end == 0x29C0, w(0x146) == 0x2B {
                setWord(h &+ 0x146, 0x2A)
            } else if end == 0x21D4, w(0x14A) == 0x1D, w(0x14C) == 0x20 {
                setWord(h &+ 0x14C, 0x1D)
            }
        case .pro:
            if w(0x0E) == 0x0A40, w(0x112) == 0x26, w(0x152) == 0 { setWord(h &+ 0x152, 0x26) }
            let end = packed ? lastMacroPlaceEnd() : macrosEnd()
            if packed, end == 0x32E0, long(h &+ 12068) == 0x0400_0027 { setByte(h &+ 12071, 0x26) }
            if let end, end >= 0x9C40, w(0x108) == 0x28 { setWord(h &+ 0x108, 0x27) }
        default:
            break
        }
    }

    /// Where an unpacked module's macros end, as the players find it (TFMX, $722; TFMX Pro, $cc8): the
    /// first Stop as a long from the last macro's place, and past it.
    private func macrosEnd() -> UInt32? {
        let h = offsets.header, end = h &+ input.mdatSize
        var at = h &+ long(h &+ 0x7FC)
        while at < end {
            let found = long(at) == 0x0700_0000
            at &+= 4
            if found { return at &- h }
        }
        return nil
    }

    /// Where, in a packed module's table of macros' places, the place of its last macro ends, as TFMX
    /// Pro's player finds it ($e38): the last macro being found back from the patterns' places, from
    /// the Stop before them to the one before that (or, past four spaces, to a long whose first byte
    /// has its top bit).
    private func lastMacroPlaceEnd() -> UInt32? {
        let h = offsets.header, end = h &+ input.mdatSize
        var at = h &+ long(h &+ 0x1D4)
        var steps = 0
        func back() -> Bool {
            steps += 1
            guard steps < 0x10000, at >= h &+ 4 else { return false }
            at &-= 4
            return true
        }
        repeat { guard back() else { return nil } } while long(at) != 0x0700_0000
        let stop = at
        while true {
            if long(at) == 0x2020_2020 {
                at = stop
                while byte(at) < 0x80 { guard back() else { return nil } }
                break
            }
            guard back() else { return nil }
            if long(at) == 0x0700_0000 { break }
        }
        let last = at &+ 4 &- h
        var place = h &+ long(h &+ 0x1D8)
        while place < end {
            let macro = long(place)
            place &+= 4
            if macro == 0 || macro >= 0x8000_0000 { return nil }
            if macro == last { return place &- h }
        }
        return nil
    }

    /// The period of note `n` (from -128 to 127) for a macro, as the players have it. TFMX Pro keeps
    /// the note below 64 ($1c9e). TFMX 1.x reads its table of periods (at $1dee) with the note as it
    /// is: below nought, the octave below the first, for which the library's table has one period
    /// twice, and then the words before it (nought from 13 below, but for two, and the player's
    /// own state further down, taken here as nought); at 64 the table's last word, nought, and past
    /// it the end of the player, which is taken here as the library takes it.
    func originalNoteToPeriod(_ n: Int) -> UInt16 {
        if variant.original != .tfmx { return Self.periods[13 + (n & 0x3F)] }
        switch n {
        case 0 ..< 64, -7 ..< 0: return Self.periods[13 + n]
        case -12 ..< -7: return Self.periods[12 + n]
        case 64: return 0
        case -14: return 0xF000
        case -16: return 0xF400
        case ..<0: return 0
        default: return Self.periods[13 + (n & 0x3F)]
        }
    }

    /// Paula's volume for the voice, as the players set it: the voice's volume as a byte, brought
    /// down by the fade (TFMX 1.x, $112a, unless it is 64; TFMX Pro, $2404, unless it has its bit of 64,
    /// nor, with `lockHeeded`, while the voice is locked, $23fe), of which the register keeps seven
    /// bits ($976; $f9a).
    func originalVolume(_ v: Int, lockHeeded: Bool) -> UInt16 {
        let volume = Int(UInt8(bitPattern: voices[v].volume))
        let f = Int(fade.volume)
        let faded = variant.original == .tfmx ? f != 0x40 : f & 0x40 == 0 && !(lockHeeded && voices[v].lockCount >= 0)
        return UInt16((faded ? ((volume * 4 * f) & 0xFFFF) >> 8 : volume) & 0x7F)
    }

    /// Whether the voice is one of the four TFMX 7V mixes onto Paula's fourth.
    func isMixedVoice(_ v: Int) -> Bool { voiceCount == 8 && v >= 3 && v <= 6 }

    // MARK: WaitOnDMA

    // Chris Hülsbeck's players wait on Paula with her audio interrupt, which she asks for each time a
    // voice begins a block: as it is started, and as it goes round. WaitOnDMA lets the voice's
    // interrupt through, and the macro goes on, on the tick after, once so many have come (TFMX Pro,
    // $1a9e, the count and one more, by its handler at $1ab4; TFMX 1.x, $1266, one, by its handler at
    // $1276). An interrupt asked for before it was let through is not lost, unless the player cleared
    // it: so a voice started, and not yet gone round, has one waiting. (libtfmxaudiodecoder counts
    // the times the voice goes round instead, which is one more.)

    /// The voice's audio interrupts since the tick before: one for each time it has gone round.
    mutating func audioInterrupts<Output: TFMXOutput>(_ out: inout Output) {
        for v in 0 ..< voiceCount where voices[v].dmaOn {
            let loops = loopCount(v, &out)
            var count = Int(loops &- voices[v].loopsSeen)
            voices[v].loopsSeen = loops
            while count > 0 {
                audioInterrupt(v)
                count = voices[v].interruptEnabled ? count - 1 : 0
            }
        }
    }

    /// Paula asks for the voice's interrupt: it is taken if let through, and otherwise left asked for.
    mutating func audioInterrupt(_ v: Int) {
        guard voices[v].interruptEnabled else {
            voices[v].interruptAsked = true
            return
        }
        voices[v].interruptAsked = false
        // (A word, as the handler's: $8000 goes round to $7FFF.)
        voices[v].waitOnDMACount &-= 1
        if voices[v].waitOnDMACount < 0 {
            voices[v].interruptEnabled = false
            voices[v].macroState = -1
        }
    }

    /// The player turns the voice's interrupt off and clears what was asked for.
    mutating func clearAudioInterrupt(_ v: Int) {
        voices[v].interruptEnabled = false
        voices[v].interruptAsked = false
    }

    /// WaitOnDMA: the macro stops until `count` and one more of the voice's interrupts have come.
    mutating func waitForAudioInterrupts(_ v: Int, count: Int16) {
        voices[v].waitOnDMACount = count
        voices[v].macroState = 0
        voices[v].interruptEnabled = true
        if voices[v].interruptAsked { audioInterrupt(v) }
    }

    /// TFMX Pro's lock of a voice, each tick before its macro ($1700): counted down, and gone once the
    /// count is below nought.
    mutating func countDownLock(_ v: Int) {
        if voices[v].lockCount >= 0 {
            voices[v].lockCount -= 1
        } else {
            voices[v].lock = 0
        }
    }

    /// The player UADE plays the module with, as its `amifilemagic.c` (`tfmxtest`) chooses one from the
    /// module's first bytes: a TFHD file says; a module with the header of TFMX before its first
    /// release, or with "(Empty)" or one of a few other texts as its first line, and not packed, is
    /// TFMX 1.x, but for four modules of TFMX Pro known by a word of theirs; one with the track
    /// command 7VOICE in a song (or one of three titles known by their first steps) is TFMX 7V; and
    /// any other is TFMX Pro. (UADE does not know the files holding both halves but TFHD; the module
    /// in one is looked at as it would be in a file of its own.)
    func uadePlayer() -> OriginalPlayer {
        if input.versionHint & 0x7F == 1 { return .tfmx }
        if input.versionHint & 0x7F == 2 { return .pro }
        if input.versionHint & 0x7F == 3 { return .sevenVoices }
        let h = offsets.header
        // What UADE is given is the module's file, as long as it is.
        let count = Int(input.mdatSize)
        func b(_ at: Int) -> UInt8 { at >= 0 && at < count ? byte(h &+ UInt32(at)) : 0 }
        func w(_ at: Int) -> Int { Int(b(at)) << 8 | Int(b(at + 1)) }
        func l(_ at: Int) -> UInt32 { UInt32(w(at)) << 16 | UInt32(w(at + 2)) }
        func text(_ at: Int, _ s: StaticString) -> Bool {
            for i in 0 ..< s.utf8CodeUnitCount where b(at + i) != s.utf8Start[i] { return false }
            return true
        }
        guard count > 0x208 else { return .pro }
        let oldHeader = text(0, "TFMX ") && b(5) == 0 && b(6) == 0 && b(7) == 1
        guard text(0, "TFMX-SONG ") || text(0, "TFMX_SONG ") || oldHeader || (text(0, "tfmxsong") && w(8) == 0 && w(10) == 2)
        else { return .pro }
        if text(16, "(Empty)         ") || text(16, "0/SB Absolute! (") || text(16, "0=endgegner     ")
            || text(16, "                ") || text(16, "Date : 17.10.90 ") || text(16, "Date : 14.10.90 ") || b(4) == 0x20 {
            guard l(464) == 0 else { return .pro }
            let x = w(14)
            // Z-Out's title, Metal Law, Bug Bomber and Metal Law's preview.
            if x == 0x0E60 || (x == 0x0860 && count > 4645 && w(4644) == 0x090C) || (x == 0x0B20 && count > 5121 && w(5120) == 0x8C26)
                || (x == 0x0920 && count > 3977 && w(3876) == 0x9305) {
                return .pro
            }
            return .tfmx
        }
        // BMW Interactive's, and BC Kid's title in two copies.
        if (w(0x0E) == 0x08B0 && w(0x140) == 0x000B && w(0x1D2) == 0x0200 && l(0x200) == 0xFF00_0000 && l(0x204) == 0x01F4_FF00)
            || (((w(0x0E) == 0x0AB0 && w(0x140) == 0x0015) || (w(0x0E) == 0x0B00 && w(0x140) == 0x0016))
                && w(0x1D2) == 0x0200 && l(0x200) == 0xEFFE_0003 && l(0x204) == 0x000D_0000) {
            return .sevenVoices
        }
        // Each song's steps, from its first to its last, looked through a word at a time.
        let steps = l(0x1D0) == 0 ? 0x800 : Int(min(l(0x1D0), UInt32(count)))
        for song in 0 ..< 31 where w(0x140 + 2 * song) != 0 {
            var t = w(0x100 + 2 * song) * 16 + steps
            let e = w(0x140 + 2 * song) * 16 + steps
            guard e < count else { continue }
            while t < e, t + 6 < count {
                if w(t) == 0xEFFE, l(t + 2) == 0x0003_FF00, b(t + 6) == 0 { return .sevenVoices }
                t += 2
            }
        }
        return .pro
    }
}
