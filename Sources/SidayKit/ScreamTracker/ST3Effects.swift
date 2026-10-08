// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from st3play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

// Scream Tracker's effects. A command is a letter, A to Z, counted from 1.

extension ST3Player {
    /// The effects of the first tick of a row, and the cutting of channels left at no volume.
    func docmd1() {
        let oldKxyLxxVolslideType = KxyLxxVolslideType
        for i in 0 ... min(Self.ACHANNELS - 1, max(0, Int(lastachannelused))) {
            let ch = zchn[i]
            guard ch.achannelused != 0 else { continue }
            // "Optimise channels at no volume": one that does nothing for three rows is shut down.
            if masterflags & 8 != 0 {
                if ch.cmd != 0 || ch.avol != 0 || ch.vol != 255 || ch.ins != 0 || ch.note != 255 {
                    ch.a0volcut = 3
                } else {
                    ch.a0volcut &-= 1
                    if ch.a0volcut == 0 {
                        ch.m_end = 0
                        ch.m_pos = 65535
                        ch.achannelused = 0
                        continue
                    }
                }
            }
            if ch.info > 0 { ch.alastnfo = ch.info }

            if ch.cmd > 0 {
                ch.achannelused |= 0x80
                if ch.cmd == 4 { // D
                    ch.atrigcnt = 0
                    // A slide to a note that did not get there is put back.
                    if ch.aspd != ch.aorgspd {
                        ch.aspd = ch.aorgspd
                        setspd(ch)
                    }
                } else {
                    if ch.cmd != 9 { // I
                        ch.atremor = 0
                        ch.atreon = true
                    }
                    if ch.cmd != 8, ch.cmd != 21, ch.cmd != 11, ch.cmd != 18 { ch.avibcnt |= 128 } // H, U, K, R
                }
                if ch.cmd < 27 {
                    KxyLxxVolslideType = 0
                    once(ch)
                }
            } else {
                ch.atrigcnt = 0
                if ch.aspd != ch.aorgspd {
                    ch.aspd = ch.aorgspd
                    setspd(ch)
                }
                // (No command is command 0, which does nothing.)
            }
        }
        KxyLxxVolslideType = oldKxyLxxVolslideType
    }

    /// The effects of the ticks after the first.
    func docmd2() {
        let oldKxyLxxVolslideType = KxyLxxVolslideType
        for i in 0 ... min(Self.ACHANNELS - 1, max(0, Int(lastachannelused))) {
            let ch = zchn[i]
            guard ch.achannelused != 0, ch.cmd > 0 else { continue }
            ch.achannelused |= 0x80
            if ch.cmd < 27 {
                KxyLxxVolslideType = 0
                other(ch)
            }
        }
        KxyLxxVolslideType = oldKxyLxxVolslideType
    }

    private func once(_ ch: ST3Channel) {
        switch ch.cmd {
        case 1: setspeed(ch.info) // A
        case 2: s_jmpto(ch) // B
        case 3: s_break(ch) // C
        case 4: s_volslide(ch) // D
        case 5: s_slidedown(ch) // E
        case 6: s_slideup(ch) // F
        case 9: s_tremor(ch) // I
        case 10: s_arp(ch) // J
        case 17: s_retrig(ch) // Q
        case 19: s_scommand1(ch) // S
        case 20: if musiccount == 0 { settempo(ch.info) } // T
        default: break
        }
    }

    private func other(_ ch: ST3Channel) {
        switch ch.cmd {
        case 4: s_volslide(ch) // D
        case 5: s_slidedown(ch) // E
        case 6: s_slideup(ch) // F
        case 7: s_toneslide(ch) // G
        case 8: s_vibrato(ch) // H
        case 9: s_tremor(ch) // I
        case 10: s_arp(ch) // J
        case 11: // K
            KxyLxxVolslideType = 2
            s_volslide(ch)
        case 12: // L
            KxyLxxVolslideType = 1
            s_volslide(ch)
        case 17: s_retrig(ch) // Q
        case 18: s_tremolo(ch) // R
        case 19: s_scommand2(ch) // S
        case 21: s_finevibrato(ch) // U
        case 22: s_setgvol(ch) // V
        default: break
        }
    }

    private func getLastNfo(_ ch: ST3Channel) {
        if ch.info == 0 { ch.info = ch.alastnfo }
    }

    private func s_jmpto(_ ch: ST3Channel) {
        if ch.info == 0xFF {
            breakpat = 255
        } else {
            breakpat = 1
            jmptoord = Int16(ch.info)
        }
    }

    private func s_break(_ ch: ST3Channel) {
        let hi = ch.info >> 4, lo = ch.info & 0x0F
        if hi <= 9, lo <= 9 {
            startrow = hi * 10 + lo
            breakpat = 1
        }
    }

    private func s_slideup(_ ch: ST3Channel) {
        if ch.aorgspd == 0 { return }
        getLastNfo(ch)
        if musiccount > 0 {
            if ch.info >= 0xE0 { return } // the fine slides are not for these ticks
            ch.aspd &-= Int16(ch.info) << 2
        } else {
            if ch.info <= 0xE0 { return } // and only they are for this one
            ch.aspd &-= ch.info <= 0xF0 ? Int16(ch.info & 0x0F) : Int16(ch.info & 0x0F) << 2
        }
        if ch.aspd < 0 { ch.aspd = 0 }
        ch.aorgspd = ch.aspd
        setspd(ch)
    }

    private func s_slidedown(_ ch: ST3Channel) {
        if ch.aorgspd == 0 { return }
        getLastNfo(ch)
        if musiccount > 0 {
            if ch.info >= 0xE0 { return }
            ch.aspd &+= Int16(ch.info) << 2
        } else {
            if ch.info <= 0xE0 { return }
            ch.aspd &+= ch.info <= 0xF0 ? Int16(ch.info & 0x0F) : Int16(ch.info & 0x0F) << 2
        }
        if UInt16(bitPattern: ch.aspd) > 32767 { ch.aspd = 32767 }
        ch.aorgspd = ch.aspd
        setspd(ch)
    }

    private func s_volslide(_ ch: ST3Channel) {
        getLastNfo(ch)
        let infohi = Int(ch.info >> 4), infolo = Int(ch.info & 0x0F)
        var avol = Int(ch.avol)
        if infolo == 0x0F {
            if infohi == 0 {
                avol -= infolo
            } else if musiccount == 0 {
                avol += infohi
            }
        } else if infohi == 0x0F {
            if infolo == 0 {
                avol += infohi
            } else if musiccount == 0 {
                avol -= infolo
            }
        } else if fastvolslide || musiccount > 0 {
            if infolo == 0 {
                avol += infohi
            } else {
                avol -= infolo
            }
        } else {
            return // not a slide
        }
        ch.avol = Int8(max(0, min(63, avol)))
        setvol(ch)
        if KxyLxxVolslideType == 1 {
            s_toneslide(ch)
        } else if KxyLxxVolslideType == 2 {
            s_vibrato(ch)
        }
    }

    private func s_toneslide(_ ch: ST3Channel) {
        let toneinfo: UInt8
        if KxyLxxVolslideType == 1 { // from L, a slide with a volume slide
            toneinfo = ch.alasteff1
        } else {
            if ch.aorgspd == 0 {
                if ch.asldspd == 0 { return }
                ch.aorgspd = ch.asldspd
                ch.aspd = ch.asldspd
            }
            if ch.info == 0 {
                ch.info = ch.alasteff1
            } else {
                ch.alasteff1 = ch.info
            }
            toneinfo = ch.info
        }
        guard ch.aorgspd != ch.asldspd else { return }
        if ch.aorgspd < ch.asldspd {
            ch.aorgspd &+= Int16(toneinfo) << 2
            if UInt16(bitPattern: ch.aorgspd) > UInt16(bitPattern: ch.asldspd) { ch.aorgspd = ch.asldspd }
        } else {
            ch.aorgspd &-= Int16(toneinfo) << 2
            if ch.aorgspd < ch.asldspd { ch.aorgspd = ch.asldspd }
        }
        ch.aspd = ch.aglis != 0 ? Int16(bitPattern: roundspd(ch, UInt16(bitPattern: ch.aorgspd))) : ch.aorgspd
        setspd(ch)
    }

    /// Where a wave has got to, and the wave's height there: for vibrato and tremolo.
    private func wave(_ type: UInt8, _ counter: Int16) -> (dat: Int32, cnt: Int16) {
        var cnt = counter
        if type >= 4 {
            cnt &= 0x7F
        } else if cnt & 0x80 != 0 {
            cnt = 0
        }
        let at = Int(cnt >> 1) & 63
        switch type & 3 {
        case 0: return (Int32(st3VibSin[at]), cnt)
        case 1: return (Int32(st3VibRamp[at]), cnt)
        case 2: return (Int32(st3VibSqu[at]), cnt)
        default: return (Int32(st3VibSin[at]), cnt &+ Int16(patmusicrand & 0x1E)) // the "random" one
        }
    }

    private func s_vibrato(_ ch: ST3Channel) {
        let vibinfo: UInt8
        if KxyLxxVolslideType == 2 { // from K, a vibrato with a volume slide
            vibinfo = ch.alasteff
        } else {
            if ch.info == 0 { ch.info = ch.alasteff }
            if ch.info & 0xF0 == 0 { ch.info = (ch.alasteff & 0xF0) | (ch.info & 0x0F) }
            ch.alasteff = ch.info
            vibinfo = ch.info
        }
        if ch.aorgspd == 0 { return }
        let (dat, cnt) = wave((ch.avibtretype & 0x0E) >> 1, ch.avibcnt)
        let depth = Int16(truncatingIfNeeded: dat &* Int32(vibinfo & 0x0F))
        ch.aspd = ch.aorgspd &+ (depth >> (oldstvib ? 4 : 5))
        setspd(ch)
        ch.avibcnt = (cnt &+ Int16((vibinfo >> 4) << 1)) & 126
    }

    private func s_finevibrato(_ ch: ST3Channel) {
        if ch.info == 0 { ch.info = ch.alasteff }
        if ch.info & 0xF0 == 0 { ch.info = (ch.alasteff & 0xF0) | (ch.info & 0x0F) }
        ch.alasteff = ch.info
        if ch.aorgspd == 0 { return }
        let (dat, cnt) = wave((ch.avibtretype & 0x0E) >> 1, ch.avibcnt)
        let depth = Int16(truncatingIfNeeded: dat &* Int32(ch.info & 0x0F))
        ch.aspd = ch.aorgspd &+ (depth >> (oldstvib ? 6 : 7))
        setspd(ch)
        ch.avibcnt = (cnt &+ Int16((ch.info >> 4) << 1)) & 126
    }

    private func s_tremolo(_ ch: ST3Channel) {
        getLastNfo(ch)
        if ch.info & 0xF0 == 0 { ch.info = (ch.alastnfo & 0xF0) | (ch.info & 0x0F) }
        ch.alastnfo = ch.info
        if ch.aorgvol <= 0 { return }
        let (wave, cnt) = wave(ch.avibtretype >> 5, ch.avibcnt)
        let dat = Int16(truncatingIfNeeded: wave)
        let swing = Int8(truncatingIfNeeded: (Int32(dat) &* Int32(ch.info & 0x0F)) >> 7)
        ch.avol = Int8(max(0, min(63, Int(ch.aorgvol) + Int(swing))))
        setvol(ch)
        ch.avibcnt = (cnt &+ Int16((ch.info & 0xF0) >> 3)) & 126
    }

    private func s_tremor(_ ch: ST3Channel) {
        getLastNfo(ch)
        if ch.atremor > 0 {
            ch.atremor -= 1
            return
        }
        if ch.atreon {
            ch.atreon = false
            ch.avol = 0
            setvol(ch)
            ch.atremor = ch.info & 0x0F
        } else {
            ch.atreon = true
            ch.avol = ch.aorgvol
            setvol(ch)
            ch.atremor = ch.info >> 4
        }
    }

    private func s_arp(_ ch: ST3Channel) {
        getLastNfo(ch)
        let tick = musiccount % 3
        var noteadd: Int8 = 0
        if tick == 1 {
            noteadd = Int8(ch.info >> 4)
        } else if tick == 2 {
            noteadd = Int8(ch.info & 0x0F)
        }
        var octa = Int8(bitPattern: ch.lastnote & 0xF0)
        var note = Int8(ch.lastnote & 0x0F) &+ noteadd
        while note >= 12 {
            note -= 12
            octa &+= 16
        }
        ch.aspd = Int16(bitPattern: scalec2spd(ch, stnote2herz(UInt8(bitPattern: octa | note))))
        setspd(ch)
    }

    private func s_retrig(_ ch: ST3Channel) {
        getLastNfo(ch)
        let infohi = Int(ch.info >> 4)
        if ch.info & 0x0F == 0 || ch.info & 0x0F > ch.atrigcnt {
            ch.atrigcnt &+= 1
            return
        }
        ch.atrigcnt = 0
        ch.m_pos = 0
        ch.m_oldpos = 0xFFFF_FFFF // which makes a GUS start the note afresh
        if st3RetrigVolAdd[infohi + 16] == 0 {
            ch.avol &+= st3RetrigVolAdd[infohi]
        } else {
            ch.avol = Int8(truncatingIfNeeded: (Int(ch.avol) * Int(st3RetrigVolAdd[infohi + 16])) >> 4)
        }
        ch.avol = max(0, min(63, ch.avol))
        setvol(ch)
        ch.atrigcnt &+= 1
    }

    // MARK: The S commands

    private func s_scommand1(_ ch: ST3Channel) {
        getLastNfo(ch)
        let value = ch.info & 0xF
        switch ch.info >> 4 {
        case 0x1: ch.aglis = value
        case 0x2:
            // Meant to retune the note. In Scream Tracker 3.21 the note stays as it is, and only the
            // rate the channel reckons with is changed, which slides and later notes then go by.
            ch.ac2spd = st3FineTuneAmiga[Int(value)]
        case 0x3: ch.avibtretype = (ch.avibtretype & 0xF0) | ((ch.info << 1) & 0x0F)
        case 0x4: ch.avibtretype = ((ch.info << 5) & 0xF0) | (ch.avibtretype & 0x0F)
        case 0x8:
            ch.apanpos = 0xF0 | value
            ch.m_oldpos = 0xFFFF_FFFF // a GUS starts the note again from where it was, with a click
        case 0xA:
            // Which side a channel goes to on a Sound Blaster Pro: as it is, the other, or both.
            if value <= 7 { ch.amixtype = Int8(value) }
        case 0xB: s_patloop(ch)
        case 0xC: ch.anotecutcnt = value
        case 0xD: ch.anotedelaycnt = value
        case 0xE:
            if patterndelay == 0 { patterndelay = Int8(value) }
        default: break
        }
    }

    private func s_scommand2(_ ch: ST3Channel) {
        getLastNfo(ch)
        switch ch.info >> 4 {
        case 0xC:
            if ch.anotecutcnt > 0 {
                ch.anotecutcnt -= 1
                if ch.anotecutcnt == 0 { ch.m_speed = 0 } // which a slide can bring back
            }
        case 0xD:
            if ch.anotedelaycnt > 0 {
                ch.anotedelaycnt -= 1
                if ch.anotedelaycnt == 0 { donewnote(ch.channelnum, true) }
            }
        default: break
        }
    }

    private func s_setgvol(_ ch: ST3Channel) {
        if ch.info <= 64 { setglobalvol(Int8(ch.info)) }
    }

    private func s_patloop(_ ch: ST3Channel) {
        if ch.info & 0xF == 0 {
            patloopstart = np_row
            return
        }
        if patloopcount == 0 {
            patloopcount = Int8(ch.info & 0xF) + 1
            if patloopstart == -1 { patloopstart = 0 }
        }
        if patloopcount > 1 {
            patloopcount -= 1
            jumptorow = patloopstart
            np_patoff = -1
            rowsWillRepeat(from: patloopstart)
        } else {
            patloopcount = 0
            patloopstart = np_row + 1
        }
    }
}
