// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from fmdrv, Copyright 2024 Sergei "x0r" Kolzun, used under the Apache License,
// Version 2.0 (see THIRD-PARTY.md). Changed from the original: carried over from C to Swift, made
// to stop at the end of a file's music where the original reads on, and to leave a tune of no
// instruments alone where the original divides by nothing.

/// SBFMDRV, the driver that came with a Sound Blaster and played CMF files on its FM chip.
///
/// A CMF file's music is MIDI, and the driver is a small MIDI player with nine voices to give out:
/// a note takes a voice its channel has let go of, or one never used, or one anybody has let go of,
/// or failing all those the one that has been sounding longest. A file may ask for the chip's drums,
/// which leaves six voices for notes and gives channels 12 to 16 a drum each.
///
/// This follows the driver and not the MIDI it was given: a note's loudness is the instrument's
/// own with the key's speed worked in, pitch bends are passed over, and the only controllers it
/// knows are its own four. What the driver did oddly it does oddly here too, since tunes were
/// written to how it sounded. The names are the reference's.
final class SBFMDriver {
    private struct Voice {
        /// The MIDI channel playing on this voice; with the top bit set, the one that last did and
        /// has let go; 0xFF for none.
        var midi_chn: UInt8 = 0
        var block_note: UInt8 = 0
        var midi_note: UInt8 = 0
        var KSL: UInt8 = 0
        var level: UInt8 = 0
        var fnum: UInt16 = 0
        var start: UInt16 = 0
    }

    private struct Channel {
        var inst: UInt8 = 0
        var transp: Int16 = 0
        var mute: UInt8 = 0
    }

    private static let opl_reg_offs: [UInt8] = [0x00, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x10, 0x11, 0x12]
    private static let init_inst: [UInt8] = [0x01, 0x11, 0x4F, 0x00, 0xF1, 0xF2, 0x53, 0x74, 0x00, 0x00, 0x08]
    private static let opl_perc_offs: [UInt8] = [0x10, 0x14, 0x12, 0x15, 0x11]
    private static let opl_perc_mask: [UInt8] = [16, 8, 4, 2, 1]
    private static let opl_perc_voice: [UInt8] = [6, 7, 8, 8, 7]

    /// The whole file: the instruments and the music are places in it.
    private let data: [UInt8]
    private let card: OPLCard?

    private var g_num_inst = 16
    private var g_inst_table = 0
    private var g_opl_chan_num = 0
    private var g_opl_perc_mode: UInt8 = 0
    private var g_opl_BD: UInt8 = 0
    private var g_midi_cmd: UInt8 = 0
    private var g_midi_chn: UInt8 = 0
    private var g_music_blk = 0
    /// 1 while a tune plays, 0 once it has stopped.
    private(set) var g_status: UInt8 = 0
    private var g_transp: Int16 = 0
    private var g_events: UInt16 = 0
    private var g_delay: UInt32 = 0
    private var g_opl_voices = [Voice](repeating: Voice(), count: 11)
    private var g_midi_channels = [Channel](repeating: Channel(), count: 16)

    /// Whether the tune has asked for the chip's drums at any time.
    private(set) var usedDrums = false

    /// Starts the driver and a tune, as the program that came with it did.
    /// - Parameters:
    ///   - card: the card to play on, or none to run the tune through in silence.
    ///   - instruments: where in the file its instruments are, sixteen bytes each, and how many.
    ///   - music: where in the file its music is.
    init(_ data: [UInt8], instruments: Int, count: Int, music: Int, card: OPLCard?) {
        self.data = data
        self.card = card
        // sbfm_init
        adlib_write(0x01, 0x20)
        adlib_write(0x08, 0x00)
        sbfm_reset()

        sbfm_reset()
        sbfm_instrument(instruments, count)
        sbfm_play_music(music)
    }

    @inline(__always) private func adlib_write(_ reg: UInt8, _ value: UInt8) {
        card?.write(Int(reg), value)
    }

    @inline(__always) private func byte(_ at: Int) -> UInt8 {
        at < data.count ? data[at] : 0
    }

    /// The next byte of the music.
    @inline(__always) private func next() -> UInt8 {
        let value = byte(g_music_blk)
        g_music_blk += 1
        return value
    }

    private func read_vlq() -> UInt32 {
        var vlq: UInt32 = 0
        var b: UInt8
        repeat {
            b = next()
            vlq = (vlq << 7) | UInt32(b & 0x7F)
        } while b & 0x80 != 0
        return vlq
    }

    private func opl_reset1() {
        g_opl_chan_num = 9
        g_opl_perc_mode = 0
        g_opl_BD = 0xC0
        adlib_write(0xBD, g_opl_BD)
    }

    private func opl_reset2() {
        for i in 0 ..< 16 { g_midi_channels[i].inst = 0 }
        for i in 0 ..< 11 { g_opl_voices[i].midi_chn = 0xFF }

        for i in 0 ..< 9 {
            adlib_write(0xBD, 0x00)
            adlib_write(0x08, 0x00)

            var at = 0
            var reg = Self.opl_reg_offs[i]
            for _ in 0 ..< 4 {
                reg &+= 0x20
                adlib_write(reg, Self.init_inst[at])
                adlib_write(reg &+ 3, Self.init_inst[at + 1])
                at += 2
            }
            reg &+= 0x60
            adlib_write(reg, Self.init_inst[at])
            adlib_write(reg &+ 3, Self.init_inst[at + 1])

            // The driver means the register that says how a voice's two operators are joined, and
            // misses it: this is one of the chip's first few, which have nothing to do with a voice.
            adlib_write(Self.opl_reg_offs[i] &+ UInt8(i), Self.init_inst[at + 2])
        }
    }

    private func midi_panic() {
        for i in 0 ..< g_opl_chan_num {
            // Meant for each voice in turn, to make it die away quickly, and set for the first alone.
            adlib_write(0x83, 0x13)

            if g_opl_voices[i].midi_chn <= 0x7F {
                adlib_write(0xA0 + UInt8(i), UInt8(truncatingIfNeeded: g_opl_voices[i].fnum))
                adlib_write(0xB0 + UInt8(i), UInt8(truncatingIfNeeded: g_opl_voices[i].fnum >> 8))
            }
        }
        g_opl_BD &= 0xE0
        adlib_write(0xBD, g_opl_BD)
    }

    private func stop_music() {
        if g_status == 0 { return }
        g_status = 0
        midi_panic()
    }

    private func process_events() {
        g_events &+= 1

        repeat {
            // (The driver has no notion of where the music ends, and reads on through whatever is
            // in memory after it.)
            if g_music_blk >= data.count {
                stop_music()
                return
            }
            let event = byte(g_music_blk)
            if event & 0x80 != 0 {
                g_midi_chn = event & 0x0F
                g_midi_cmd = (event >> 4) - 8
                g_music_blk += 1
            }

            switch g_midi_cmd {
            case 0, 1: note()
            case 2: g_music_blk += 2
            case 3: process_controllers()
            case 4: prg_change()
            case 5: g_music_blk += 1
            case 6: g_music_blk += 2 // a bend of pitch, which the driver does not do
            default: sysmsg()
            }

            if g_status == 0 { return }
            g_delay = read_vlq()
        } while g_delay == 0

        g_delay &-= 1
    }

    private func find_opl_voice(_ midi_chn: UInt8) -> Int {
        for i in 0 ..< g_opl_chan_num where g_opl_voices[i].midi_chn == (midi_chn | 0x80) { return i }
        for i in 0 ..< g_opl_chan_num where g_opl_voices[i].midi_chn == 0xFF { return i }
        for i in 0 ..< g_opl_chan_num where g_opl_voices[i].midi_chn > 0x7F { return i }

        var m = 0
        var max: UInt16 = 0
        for i in 0 ..< g_opl_chan_num {
            let tmp = g_events &- g_opl_voices[i].start
            if tmp > max {
                max = tmp
                m = i
            }
        }

        adlib_write(0xA0 + UInt8(m), UInt8(truncatingIfNeeded: g_opl_voices[m].fnum))
        adlib_write(0xB0 + UInt8(m), UInt8(truncatingIfNeeded: g_opl_voices[m].fnum >> 8))
        return m
    }

    private func calc_block_fnum(_ n: Int, _ block_note: UInt8) -> UInt16 {
        var block = Int((block_note & 0x70) >> 2)
        var note = Int(block_note & 0x0F) << 6

        note += Int(g_midi_channels[Int(g_midi_chn)].transp)

        if note < 0 {
            note += 768
            block -= 4
            if block < 0 {
                note = 0
                block = 0
            }
        }

        if note >= 768 {
            note -= 768
            block += 4
            if block > 28 {
                note = 767
                block = 28
            }
        }

        let fnum = (UInt16(block) << 8) | sbfmFnum[note]

        g_opl_voices[n].fnum = fnum
        g_opl_voices[n].start = g_events
        return fnum
    }

    private func note2fnum(_ n: Int, _ note: UInt8) -> UInt16 {
        g_opl_voices[n].midi_note = note

        let note_transp = max(0, min(127, Int(note) + Int(g_transp)))
        let block_note = sbfmBlockNote[note_transp]
        g_opl_voices[n].block_note = block_note

        return calc_block_fnum(n, block_note)
    }

    private func set_instrument(_ n: Int, _ insnum: UInt8) {
        guard Int(insnum) < g_num_inst else { return }
        var at = g_inst_table + (Int(insnum) << 4)

        g_opl_voices[n].KSL = byte(at + 3) & 0xC0
        g_opl_voices[n].level = 63 - (byte(at + 3) & 0x3F)

        if g_opl_perc_mode == 0 || n <= 6 {
            var reg = Self.opl_reg_offs[n]
            for _ in 0 ..< 4 {
                reg &+= 0x20
                adlib_write(reg, byte(at))
                adlib_write(reg &+ 3, byte(at + 1))
                at += 2
            }
            reg &+= 0x60
            adlib_write(reg, byte(at))
            adlib_write(reg &+ 3, byte(at + 1))
            adlib_write(0xC0 + UInt8(n), byte(at + 2))
        } else {
            // A drum that is one operator of a voice: the instrument's first is what it gets.
            var reg = Self.opl_perc_offs[n - 6]
            for _ in 0 ..< 4 {
                reg &+= 0x20
                adlib_write(reg, byte(at))
                at += 2
            }
            reg &+= 0x60
            adlib_write(reg, byte(at))
            adlib_write(0xC0 + Self.opl_perc_voice[n - 6], byte(at + 2) | 1)
        }
    }

    private func note() {
        let note = next()
        let vel = next()

        if g_midi_cmd == 0 || vel == 0 {
            note_off(note)
        } else {
            note_on(note, vel)
        }
    }

    private func note_off(_ note: UInt8) {
        if g_opl_chan_num > 6 || g_midi_chn < 11 {
            for i in 0 ..< g_opl_chan_num where g_opl_voices[i].midi_chn == g_midi_chn && g_opl_voices[i].midi_note == note {
                g_opl_voices[i].midi_chn |= 0x80
                adlib_write(0xA0 + UInt8(i), UInt8(truncatingIfNeeded: g_opl_voices[i].fnum))
                adlib_write(0xB0 + UInt8(i), UInt8(truncatingIfNeeded: g_opl_voices[i].fnum >> 8))
            }
        } else {
            g_opl_BD &= ~Self.opl_perc_mask[Int(g_midi_chn) - 5 - 6]
            adlib_write(0xBD, g_opl_BD)
        }
    }

    /// How loud a voice is to be for a key struck at a speed, as the chip is told it.
    private func loudness(_ voice: Int, _ vel: UInt8) -> UInt8 {
        let tmp = UInt16(vel | 0x80) * UInt16(g_opl_voices[voice].level)
        return (63 - UInt8(truncatingIfNeeded: tmp >> 8)) | g_opl_voices[voice].KSL
    }

    private func note_on(_ note: UInt8, _ vel: UInt8) {
        if g_midi_channels[Int(g_midi_chn)].mute == 0 { return }

        if g_opl_perc_mode == 0 || g_midi_chn < 11 {
            let opl_voice = find_opl_voice(g_midi_chn)
            let midi_chn = g_opl_voices[opl_voice].midi_chn & 0x7F
            g_opl_voices[opl_voice].midi_chn = g_midi_chn

            if g_midi_chn != midi_chn {
                set_instrument(opl_voice, g_midi_channels[Int(g_midi_chn)].inst)
            }

            adlib_write(0x43 + Self.opl_reg_offs[opl_voice], loudness(opl_voice, vel))

            let tmp = note2fnum(opl_voice, note)
            adlib_write(0xA0 + UInt8(opl_voice), UInt8(truncatingIfNeeded: tmp))
            adlib_write(0xB0 + UInt8(opl_voice), 0x20 | UInt8(truncatingIfNeeded: tmp >> 8))
        } else {
            let opl_voice = Int(g_midi_chn) - 5
            g_opl_BD |= Self.opl_perc_mask[opl_voice - 6]

            // The bass drum is a whole voice, and its second operator is the one heard.
            let reg: UInt8 = opl_voice == 6 ? 0x43 : 0x40
            adlib_write(reg &+ Self.opl_perc_offs[opl_voice - 6], loudness(opl_voice, vel))

            // (For the cymbal and the hi-hat these are registers the chip has not got: the two
            // take their pitch from the tom-tom's voice and the snare's.)
            let tmp = note2fnum(opl_voice, note)
            adlib_write(0xA0 + UInt8(opl_voice), UInt8(truncatingIfNeeded: tmp))
            adlib_write(0xB0 + UInt8(opl_voice), UInt8(truncatingIfNeeded: tmp >> 8))
            adlib_write(0xBD, g_opl_BD)
        }
    }

    private func process_controllers() {
        let controller = next() &- 0x66
        let value = next()

        switch controller {
        case 0: break // a marker for the program playing the tune, and nothing to hear
        case 1: switch_mode(value)
        case 2: transpose(Int8(bitPattern: value))
        case 3: transpose(Int8(truncatingIfNeeded: -Int(Int8(bitPattern: value))))
        default: break
        }
    }

    /// With the chip's drums or without.
    private func switch_mode(_ v: UInt8) {
        g_opl_chan_num = 9
        g_opl_BD = 0xC0
        g_opl_perc_mode = v

        if g_opl_perc_mode != 0 {
            g_opl_chan_num = 6
            g_opl_BD = 0xE0
            usedDrums = true
        }

        g_opl_voices[6].midi_chn = 0xFF
        g_opl_voices[7].midi_chn = 0xFF
        g_opl_voices[8].midi_chn = 0xFF

        adlib_write(0xBD, g_opl_BD)
        opl_reset2()
    }

    /// Moves a channel's pitch by so many 256ths of a semitone, which the chip is told to the nearest 64th.
    private func transpose(_ v: Int8) {
        g_midi_channels[Int(g_midi_chn)].transp = Int16(v / 4)

        for i in 0 ..< g_opl_chan_num where g_opl_voices[i].midi_chn == g_midi_chn {
            let fnum = calc_block_fnum(i, g_opl_voices[i].block_note)
            adlib_write(0xA0 + UInt8(i), UInt8(truncatingIfNeeded: fnum))
            adlib_write(0xB0 + UInt8(i), 0x20 | UInt8(truncatingIfNeeded: fnum >> 8))
        }
    }

    private func prg_change() {
        var insnum = next()
        if g_num_inst > 0 { insnum = UInt8(Int(insnum) % g_num_inst) }

        g_midi_channels[Int(g_midi_chn)].inst = insnum

        if g_opl_perc_mode == 0 || g_midi_chn < 11 {
            for i in 0 ..< g_opl_chan_num where g_opl_voices[i].midi_chn == (g_midi_chn | 0x80) {
                g_opl_voices[i].midi_chn = 0xFF
            }
            for i in 0 ..< g_opl_chan_num where g_opl_voices[i].midi_chn == g_midi_chn {
                set_instrument(i, insnum)
            }
        } else {
            set_instrument(Int(g_midi_chn) - 5, insnum)
        }
    }

    private func sysmsg() {
        switch g_midi_chn {
        case 0, 7: g_music_blk += Int(read_vlq())
        case 2: g_music_blk += 2
        case 3: g_music_blk += 1
        case 12: stop_music()
        case 15:
            if next() == 0x2F { stop_music() }
            g_music_blk += Int(read_vlq())
        default: break
        }
    }

    private func sbfm_instrument(_ inst_table: Int, _ num_inst: Int) {
        g_num_inst = num_inst
        g_inst_table = inst_table
        opl_reset1()
        opl_reset2()
    }

    private func sbfm_play_music(_ cmf_music_blk: Int) {
        if g_status != 0 { return }

        g_music_blk = cmf_music_blk

        for i in 0 ..< 16 { g_midi_channels[i].transp = 0 }
        for i in 0 ..< 9 { g_opl_voices[i].midi_chn = 0xFF }

        g_delay = read_vlq()
        g_events = 0

        opl_reset1()

        g_status = 1
    }

    /// One tick of the tune's clock.
    func sbfm_tick() {
        if g_status == 1 {
            let due = g_delay == 0
            g_delay &-= 1
            if due { process_events() }
        }
    }

    private func sbfm_reset() {
        stop_music()
        opl_reset1()

        for i in 0 ..< 16 { g_midi_channels[i].mute = 1 }

        // (The driver has sixteen instruments of its own for a program that brings none. A CMF
        // file brings its own before a note is played, so they are never heard and are not here.)
        g_num_inst = 16
        g_inst_table = data.count

        opl_reset2()
        g_transp = 0
    }
}
