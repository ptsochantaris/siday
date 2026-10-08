// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from st3play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md): his C port of the replayer of Scream Tracker 3.21, made from that tracker's
// own assembly and C. The names are the original's, as in the other ports here.

/// A channel as Scream Tracker keeps it.
final class ST3Channel {
    var aorgvol: Int8 = 0, avol: Int8 = 0
    var atreon = false
    var channelnum: UInt8 = 0, achannelused: UInt8 = 0, aglis: UInt8 = 0, atremor: UInt8 = 0, atrigcnt: UInt8 = 0
    var anotecutcnt: UInt8 = 0, anotedelaycnt: UInt8 = 0, a0volcut: UInt8 = 0
    var avibtretype: UInt8 = 0, note: UInt8 = 0, ins: UInt8 = 0, vol: UInt8 = 0, cmd: UInt8 = 0, info: UInt8 = 0
    var lastins: UInt8 = 0, lastnote: UInt8 = 0, alastnfo: UInt8 = 0, alasteff: UInt8 = 0, alasteff1: UInt8 = 0
    var avibcnt: Int16 = 0, asldspd: Int16 = 0, aspd: Int16 = 0, aorgspd: Int16 = 0
    var astartoffset: UInt16 = 0, astartoffset00: UInt16 = 0, ac2spd: UInt16 = 0
    // For the mixer and the GUS.
    var amixtype: Int8 = 0, aguschannel: Int8 = 0
    var apanpos: UInt8 = 0
    /// Where the sample it plays is in the module's samples; -1 for none.
    var m_base = -1
    var m_vol: UInt8 = 0, m_oldvol: UInt8 = 0
    var m_pos: UInt32 = 0, m_poslow: UInt32 = 0, m_oldpos: UInt32 = 0, m_end: UInt32 = 0, m_loop: UInt32 = 0, m_speed: UInt32 = 0

    init(_ number: Int) {
        channelnum = UInt8(number)
        achannelused = 128
        aguschannel = -1
        m_oldvol = 255
        m_oldpos = 0xFFFF_FFFF
    }
}

/// The sound card a tune is played on. Scream Tracker played the same tune quite differently on each.
public enum ST3Card: String, Sendable, CaseIterable {
    /// The Gravis Ultrasound: the card mixes the voices itself, smoothly, each where it is placed.
    case gus
    /// The Sound Blaster Pro: Scream Tracker mixes the voices itself, into eight bits at 22 kHz in
    /// stereo, eight channels hard to each side.
    case sb
}

/// Scream Tracker 3's replayer, playing a module on one of its two sound cards.
public final class ST3Player {
    static let C2FREQ: UInt32 = 8363
    /// The player this is ported from goes wrong in a few places where Scream Tracker did not: slips
    /// of C arithmetic, not of the tracker. They are not repeated, except when the two players are
    /// being compared sample for sample, which this is for.
    public nonisolated(unsafe) static var repeatsReferenceSlips = false
    /// Sixteen channels of samples; the rest were the AdLib card's.
    static let ACHANNELS = 48

    let module: ST3Module
    let card: ST3Card
    let zchn: [ST3Channel]
    let cards: ST3Cards

    var oldstvib = false, fastvolslide = false, amigalimits = false, stereomode = false
    var np_patseg: [UInt8]?
    var np_patoff: Int16 = -1, aspdmin: Int16 = 0, aspdmax: Int16 = 0, np_ord: Int16 = 0, np_row: Int16 = 0, np_pat: Int16 = 0, globalvol: Int16 = 0
    var masterflags: UInt16 = 0
    var patterndelay: Int8 = 0, patloopcount: Int8 = 0, lastachannelused: Int8 = 1
    var musicmax: UInt8 = 6, breakpat: UInt8 = 0, startrow: UInt8 = 0, musiccount: UInt8 = 0
    var jmptoord: Int16 = -1, patloopstart: Int16 = 0, jumptorow: Int16 = -1
    var useglobalvol: UInt16 = 0, patmusicrand: UInt16 = 0
    var KxyLxxVolslideType: UInt8 = 0

    var notemixingspeed: UInt16 = 0
    /// How long a tick is at the tempo that is set, in samples and 2^-32s of one.
    private(set) var samplesPerTick: UInt64 = 0
    private var tickTable = [UInt64](repeating: 0, count: 256)

    // Coming round: which rows have been played.
    private let visited: UnsafeMutablePointer<Bool>
    private(set) var cameRound = false
    /// True for a module with no pattern to play.
    var silent: Bool { np_pat == 255 }

    init(_ module: ST3Module, card: ST3Card) {
        self.module = module
        self.card = card
        zchn = (0 ..< Self.ACHANNELS).map { ST3Channel($0) }
        visited = .allocate(capacity: 256 * 64)
        visited.initialize(repeating: false, count: 256 * 64)

        stereomode = module.mastermul & 128 != 0
        // (Scream Tracker's 22000 is not quite what it sets the card to.)
        notemixingspeed = card == .gus ? 38587 : stereomode ? 22000 : 43478
        let rate = Double(outputSampleRate)
        for i in 0 ... 255 {
            let bpm = i == 0 ? 1 : i
            let hz: Double
            if card == .gus {
                // The timer the tracker used, which cannot go slower than 19 times a second.
                let wanted = max(19, bpm * 50 / 125)
                hz = (157_500_000.0 / 132.0) / Double(1_193_180 / wanted)
            } else {
                hz = Double(notemixingspeed) / Double(Int(notemixingspeed) * 125 / (bpm * 50))
            }
            tickTable[i] = UInt64((rate / hz) * 4_294_967_296.0 + 0.5)
        }
        cards = ST3Cards(card: card, module: module, stereo: stereomode)

        // The header's settings.
        oldstvib = module.flags & 1 != 0
        settempo(module.inittempo != 0 ? module.inittempo : 125)
        setspeed(module.initspeed != 255 ? module.initspeed : 6)
        setglobalvol(Int8(bitPattern: module.globalvol != 255 ? module.globalvol : 64))
        if module.flags != 255 {
            masterflags = module.flags
            fastvolslide = masterflags & 64 != 0
            amigalimits = masterflags & 16 != 0
            aspdmin = amigalimits ? 453 : 64
            aspdmax = amigalimits ? 3424 : 32767
        }
        for i in 0 ..< 32 where module.defaultpan[i] & 32 != 0 {
            zchn[i].apanpos = 0xF0 | (module.defaultpan[i] & 0xF) // the top part says the channel has a place set
        }
        np_ord = 0
        _ = neworder()
        musiccount = 0
    }

    deinit {
        visited.deallocate()
    }

    // MARK: Settings

    func settempo(_ bpm: UInt8) {
        // With a Sound Blaster, Scream Tracker takes no notice of a tempo of 32 or less.
        if card == .sb, bpm <= 0x20 { return }
        samplesPerTick = tickTable[Int(bpm)]
    }

    func setspeed(_ value: UInt8) {
        if value > 0 { musicmax = value }
    }

    func setglobalvol(_ vol: Int8) {
        globalvol = Int16(vol)
        useglobalvol = UInt16(min(64, UInt8(bitPattern: vol))) << 2
    }

    // MARK: Notes into rates

    /// For a slide that goes by semitones: the rate of the note nearest a rate.
    func roundspd(_ ch: ST3Channel, _ spd: UInt16) -> UInt16 {
        var newspd = UInt32(spd) &* UInt32(ch.ac2spd)
        if newspd >> 16 >= Self.C2FREQ { return spd }
        newspd /= Self.C2FREQ

        var octa: Int8 = 0
        var lastspd = UInt16(truncatingIfNeeded: (Int(st3NoteSpd[12]) + Int(st3NoteSpd[11])) >> 1)
        while UInt32(lastspd) >= newspd {
            octa &+= 1
            lastspd >>= 1
            if lastspd == 0, newspd == 0 { break }
        }
        var newnote: Int8 = 0
        var notemin: Int16 = 32767
        for i in 0 ..< 11 {
            var note = st3NoteSpd[i]
            if octa > 0 { note >>= Int16(octa) }
            note &-= Int16(truncatingIfNeeded: newspd)
            if note < 0 { note = 0 &- note }
            if note < notemin {
                notemin = note
                newnote = Int8(i)
            }
        }
        newspd = UInt32(stnote2herz(UInt8(truncatingIfNeeded: (Int(octa) << 4) | (Int(newnote) & 0x0F)))) &* Self.C2FREQ
        if newspd >> 16 >= UInt32(ch.ac2spd) { return spd }
        newspd /= UInt32(ch.ac2spd)
        return UInt16(truncatingIfNeeded: newspd)
    }

    func scalec2spd(_ ch: ST3Channel, _ spd: UInt16) -> UInt16 {
        var tmpspd = UInt32(spd) &* Self.C2FREQ
        if tmpspd >> 16 >= UInt32(ch.ac2spd) { return 32767 }
        tmpspd /= UInt32(ch.ac2spd)
        return UInt16(min(32767, tmpspd))
    }

    func setspd(_ ch: ST3Channel) {
        ch.achannelused |= 128
        let limited = masterflags & 16 != 0
        if limited {
            if UInt16(bitPattern: ch.aorgspd) > UInt16(bitPattern: aspdmax) { ch.aorgspd = aspdmax }
            if ch.aorgspd < aspdmin { ch.aorgspd = aspdmin }
        }
        var tmpspd = ch.aspd
        if UInt16(bitPattern: tmpspd) > UInt16(bitPattern: aspdmax) {
            tmpspd = aspdmax
            if limited { ch.aspd = tmpspd }
        }
        if tmpspd == 0 {
            ch.m_speed = 0
            return
        }
        if tmpspd < aspdmin {
            tmpspd = aspdmin
            if limited { ch.aspd = tmpspd }
        }
        let hz = 14_317_056 / UInt32(UInt16(bitPattern: tmpspd))
        let mixing = UInt32(notemixingspeed)
        if hz < 65536 {
            ch.m_speed = (hz << 16) / mixing
        } else {
            let quotient = UInt32(UInt16(truncatingIfNeeded: hz / mixing)), remainder = UInt32(UInt16(truncatingIfNeeded: hz % mixing))
            if Self.repeatsReferenceSlips {
                ch.m_speed = (quotient << 16) | UInt32(bitPattern: Int32(bitPattern: remainder << 16) / Int32(mixing))
            } else {
                ch.m_speed = (quotient << 16) | ((remainder << 16) / mixing)
            }
        }
    }

    func setvol(_ ch: ST3Channel) {
        ch.achannelused |= 128
        ch.m_vol = UInt8(truncatingIfNeeded: (Int(UInt8(bitPattern: ch.avol)) * Int(useglobalvol)) >> 8)
    }

    func stnote2herz(_ note: UInt8) -> UInt16 {
        if note == 254 { return 0 }
        var noteVal = UInt16(bitPattern: st3NoteSpd[Int(note & 0x0F)])
        let shiftVal = st3OctaveDiv[Int(note >> 4)]
        if shiftVal > 0 { noteVal >>= UInt16(shiftVal & 0x1F) }
        return noteVal
    }

    // MARK: The ticker

    /// One tick of the song, and what it changes told to the sound card.
    func tick() {
        cameRound = false
        dorow()
        for ch in zchn {
            ch.achannelused &= 127
            if card == .gus { cards.gusUpdate(ch, stereo: stereomode) }
        }
        if card == .gus { cards.gusTrigger() }
    }

    func dorow() {
        if np_pat == 255 { return } // a song with no patterns
        patmusicrand = UInt16(truncatingIfNeeded: ((UInt32(patmusicrand) &* 0xCDEF) >> 16) &+ 0x1727)

        if musiccount == 0 {
            if patterndelay > 0 {
                np_row -= 1
                docmd1()
                patterndelay -= 1
            } else {
                donotes()
                docmd1()
            }
        } else {
            docmd2()
        }

        musiccount &+= 1
        if musiccount >= musicmax {
            np_row += 1
            if jumptorow != -1 {
                np_row = jumptorow
                jumptorow = -1
            }
            if np_row >= 64 || (patloopcount == 0 && breakpat > 0) {
                if breakpat == 255 {
                    breakpat = 0
                    return
                }
                breakpat = 0
                if jmptoord != -1 {
                    np_ord = jmptoord
                    jmptoord = -1
                }
                np_row = neworder()
            }
            musiccount = 0
        }
    }

    /// On to the next order that is a pattern: a 254 in the list is only a mark, and a 255 its end.
    func neworder() -> Int16 {
        var patt: UInt8 = 0
        var numSep = 0
        while true {
            np_ord += 1
            patt = module.order[Int(np_ord) - 1]
            if patt == 254 {
                numSep += 1
                if numSep >= module.ordnum { return 0 }
                continue
            }
            if patt == 255 {
                np_ord = 0
                if module.order[0] == 255 { return 0 }
                continue
            }
            break
        }
        np_pat = Int16(patt)
        np_patoff = -1
        np_row = Int16(startrow)
        startrow = 0
        patmusicrand = 0
        patloopstart = -1
        jumptorow = -1
        return np_row
    }

    /// The row about to be read: has it been played before?
    private func rowIsRead() {
        guard np_ord >= 1, np_ord <= 256, np_row >= 0, np_row < 64 else { return }
        let at = (Int(np_ord) - 1) * 64 + Int(np_row)
        if visited[at] {
            cameRound = true
            visited.update(repeating: false, count: 256 * 64)
        }
        visited[at] = true
    }

    /// A loop inside a pattern goes back: the rows it plays again have not been played for the last time.
    func rowsWillRepeat(from row: Int16) {
        guard np_ord >= 1, np_ord <= 256 else { return }
        var again = max(0, Int(row))
        while again <= min(63, Int(np_row)) {
            visited[(Int(np_ord) - 1) * 64 + again] = false
            again += 1
        }
    }

    private func pattern(_ at: Int) -> UInt8 {
        guard let np_patseg, at >= 0, at < np_patseg.count else { return 0 }
        return np_patseg[at]
    }

    private func seekpat() {
        if np_patoff != -1 { return }
        np_patseg = np_pat >= 0 && Int(np_pat) < module.patp.count ? module.patp[Int(np_pat)] : nil
        guard np_patseg != nil else { return }
        var j = 0
        var i = Int(np_row)
        while i > 0, j < (np_patseg?.count ?? 0) {
            let dat = pattern(j)
            j += 1
            if dat == 0 {
                i -= 1
            } else {
                if dat & 0x20 != 0 { j += 2 }
                if dat & 0x40 != 0 { j += 1 }
                if dat & 0x80 != 0 { j += 2 }
            }
        }
        np_patoff = Int16(truncatingIfNeeded: j)
    }

    /// The next note of the row, read into its channel. 255 at the row's end.
    private func getnote1() -> UInt8 {
        guard np_patseg != nil, Int(np_pat) < module.patnum else { return 255 }
        var channel: UInt8 = 0
        var i = Int(np_patoff)
        var dat: UInt8
        while true {
            dat = pattern(i)
            i += 1
            if dat == 0 {
                np_patoff = Int16(truncatingIfNeeded: i)
                return 255
            }
            let tmpChannel = module.channel[Int(dat & 0x1F)]
            if tmpChannel & 128 == 0 {
                channel = tmpChannel
                break
            }
            // The channel is switched off: past its note.
            if dat & 32 != 0 { i += 2 }
            if dat & 64 != 0 { i += 1 }
            if dat & 128 != 0 { i += 2 }
        }
        let ch = zchn[Int(channel) % Self.ACHANNELS]
        if dat & 32 != 0 {
            ch.note = pattern(i)
            ch.ins = pattern(i + 1)
            i += 2
            if ch.note != 255 { ch.lastnote = ch.note }
            if ch.ins > 0 { ch.lastins = ch.ins }
        }
        if dat & 64 != 0 {
            ch.vol = pattern(i)
            i += 1
        }
        if dat & 128 != 0 {
            ch.cmd = pattern(i)
            ch.info = pattern(i + 1)
            i += 2
        }
        np_patoff = Int16(truncatingIfNeeded: i)
        return channel
    }

    private func donotes() {
        rowIsRead()
        for ch in zchn {
            ch.note = 255
            ch.vol = 255
            ch.ins = 0
            ch.cmd = 0
            ch.info = 0
        }
        seekpat()
        while true {
            let channel = getnote1()
            if channel == 255 { break }
            donewnote(channel, false)
        }
    }

    func donewnote(_ channel: UInt8, _ fromNoteDelayEfx: Bool) {
        let ch = zchn[Int(channel) % Self.ACHANNELS]
        if fromNoteDelayEfx {
            ch.achannelused = 1 | 128
        } else {
            if Int(ch.channelnum) > Int(lastachannelused) { lastachannelused = Int8(truncatingIfNeeded: Int(ch.channelnum) + 1) }
            ch.achannelused = 1
            if ch.cmd == 19, ch.info & 0xF0 == 0xD0 { return } // a delayed note is not for now
        }
        if ch.ins > 101 { ch.ins = 0 }
        if ch.vol != 255, ch.vol > 63 { ch.vol = 63 }
        // Channels beyond the sixteenth are the AdLib card's, which is not played.
        if ch.channelnum <= 15 { doamiga(ch) }
    }

    /// A new note, instrument or volume on a channel of samples.
    private func doamiga(_ ch: ST3Channel) {
        if ch.ins > 0 {
            ch.astartoffset = 0
            if ch.ins < ST3Module.mostInstruments {
                ch.lastins = ch.ins
                let ins = module.ins[Int(ch.ins) - 1]
                if ins.type == 1 {
                    ch.ac2spd = UInt16(truncatingIfNeeded: ins.c2spd)
                    ch.avol = max(0, min(63, Int8(bitPattern: ins.vol)))
                    ch.aorgvol = ch.avol
                    setvol(ch)
                    ch.m_base = ins.baseptr
                    if module.beyondScreamTracker {
                        // A sample Scream Tracker could not have held: its lengths taken whole.
                        if ins.flags & 1 != 0, ins.lend != 0 {
                            ch.m_loop = ins.lbeg
                            ch.m_end = ins.lend
                        } else {
                            ch.m_end = ins.length &+ 32
                            ch.m_loop = 0xFFFF_FFFF
                        }
                    } else {
                        var lend = UInt16(truncatingIfNeeded: ins.lend)
                        if ins.flags & 1 != 0, lend != 0 {
                            // A loop of less than 500 is played as several of itself.
                            let lbeg = UInt16(truncatingIfNeeded: ins.lbeg)
                            ch.m_loop = UInt32(lbeg)
                            if lend <= 500 {
                                let a = Int16(bitPattern: lbeg &- lend)
                                repeat { lend &-= UInt16(bitPattern: a) } while lend < 500
                                lend &+= UInt16(bitPattern: a)
                            }
                            ch.m_end = UInt32(lend)
                        } else {
                            // A little more, for the sample to trail away in (and it can go right round).
                            ch.m_end = UInt32(UInt16(truncatingIfNeeded: ins.length) &+ 32)
                            ch.m_loop = 65535
                        }
                    }
                } else if ins.type != 0 {
                    ch.lastins = 0
                }
            }
        }
        if ch.lastins == 0 { return }

        if ch.cmd == 15 { // O: start somewhere into the sample
            if ch.info == 0 {
                ch.astartoffset = ch.astartoffset00
            } else {
                ch.astartoffset = UInt16(ch.info) << 8
                ch.astartoffset00 = ch.astartoffset
            }
        }

        if ch.note != 255 {
            if ch.note == 254 {
                // The note is ended.
                ch.m_pos = 1
                ch.m_poslow = 0
                ch.aspd = 0
                setspd(ch)
                ch.avol = 0
                setvol(ch)
                ch.m_end = 0
                ch.m_loop = module.beyondScreamTracker ? 0xFFFF_FFFF : 65535
                ch.asldspd = -1 // a slip in the original, kept
            } else {
                let sliding = ch.cmd == 7 || ch.cmd == 12 // G or L
                if !sliding {
                    ch.m_pos = UInt32(ch.astartoffset)
                    ch.m_poslow = 0
                    ch.m_oldpos = 0x1234_5678 // which makes a GUS start the note afresh
                }
                ch.lastnote = ch.note
                let newspd = Int16(bitPattern: scalec2spd(ch, stnote2herz(ch.note)))
                if ch.aorgspd == 0 || !sliding {
                    ch.aspd = newspd
                    setspd(ch)
                    ch.avibcnt = 0
                    ch.aorgspd = newspd
                }
                ch.asldspd = newspd
            }
        }

        if ch.vol != 255 {
            ch.avol = Int8(bitPattern: ch.vol)
            setvol(ch)
            ch.aorgvol = Int8(bitPattern: ch.vol)
        }
    }
}
