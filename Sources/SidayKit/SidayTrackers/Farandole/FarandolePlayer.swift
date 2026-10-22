// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written for siday. What each command does is from the description that came with Farandole
// Composer; how much it does, and how the program kept time, is as libxmp has it, whose authors
// set their player beside the program itself (see THIRD-PARTY.md). No code here is taken from it.

/// Plays a FAR file, a tick at a time, on `SampleMixer`.
///
/// Farandole Composer is like no other tracker in how it keeps time. It has a tempo from 0 to 15,
/// which is how many thirty-seconds of a second a row lasts, and a fine tempo that is added to it
/// or taken from it; from the two it works out how many ticks a second there are to be, sets the
/// PC's timer to that, and plays four ticks to a row, or more where the timer cannot count so
/// slowly. And it played on a Gravis Ultrasound and nothing else, and counted its slides of pitch
/// in the steps of that card's frequency register: so a slide is so many samples a second, as in a
/// 669 file, and not so much of a period. Those two things are why it has a player of its own here.
///
/// Its commands:
/// - 1 and 2 put the pitch up or down by a little, once, on their row;
/// - 3, beside a note, slides to that note over so many rows and does not strike it, and goes on
///   by itself until it is there;
/// - 4 strikes the note so many times in its row, and C strikes it once more, so many ticks in;
/// - 5 says how deep vibratos are, for every channel; 6 is a vibrato for its row, so fast; and 9
///   one that goes on until it is given a speed of nought;
/// - 7 and 8 put the volume up or down, once; A slides it to the volume beside it, over so many
///   half rows, and goes on by itself until it is there;
/// - B puts the channel at one of sixteen places between the speakers;
/// - F sets the tempo, and D and E take from the fine tempo and add to it.
struct FarandolePlayer: ~Copyable {
    private struct Channel {
        var sample = -1
        /// Samples a second.
        var rate: Double = 0
        /// From 0 to 240: sixteen for each of the file's fifteen steps.
        var volume = 0
        var side: Float = 0
        var heard = true
        // A slide to a note, and one to a volume, which go on until they are there.
        var sliding = false, slideTo: Double = 0, slideBy: Double = 0
        var fading = false, fadeTo = 0, fadeBy = 0
        // A vibrato: for this row, or held until it is let go.
        var vibrato = false, vibratoHeld = false, vibratoKept = false
        var vibratoRate = 0, phase = 0
        // What is done once, after the row's first tick.
        var bend: Double = 0, nudge = 0
        // Striking the note again: ticks until the next, ticks apart, and how many are left (nought for no end to them).
        var again = false, untilNext = 0, apart = 0, left = 0
    }

    let module: FarandoleModule
    var mixer: SampleMixer
    private var channels: [Channel]
    private(set) var order: Int
    private(set) var row = 0
    private var tick = 0
    var tickNow: Int { tick }
    private var started = false

    // The tempo, and what it comes to.
    private var coarse: Int, fine = 0
    private var newTempo = true
    private var ticksToARow = 4
    /// How long a tick lasts, in counts of the PC's timer: see `timerRate`.
    private(set) var tickLength = 37414
    /// How deep a vibrato goes, on every channel.
    private var vibratoDepth = 4

    /// For telling the file's songs apart: see `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>?
    private let songNumber: UInt8
    private(set) var ordersPlayed: [Bool]
    private(set) var playedNote = false
    private(set) var ledIntoEarlierSong = false
    private(set) var struck: [Bool]

    /// How many times a second the PC's timer counts.
    static let timerRate = 1_193_182
    /// What Farandole Composer took that number to be, when it worked out what to set the timer to.
    private static let reckonedRate = 1_197_255
    /// Ticks a second for each tempo, before the fine tempo: 128 over the tempo, and 256 for nought.
    private static let tempos = [256, 128, 64, 42, 32, 25, 21, 18, 16, 14, 12, 11, 10, 9, 9, 8]
    /// One step of the Ultrasound's frequency register in samples a second, with the seventeen
    /// voices Farandole Composer had it play.
    private static let frequencyStep = 36317.65 / 1024
    private static let sine = [
        0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253, 255, 253, 250, 244, 235, 224, 212, 197,
        180, 161, 141, 120, 97, 74, 49, 24, 0, -24, -49, -74, -97, -120, -141, -161, -180, -197, -212, -224, -235, -244, -250, -253,
        -255, -253, -250, -244, -235, -224, -212, -197, -180, -161, -141, -120, -97, -74, -49, -24,
    ]

    init(_ module: FarandoleModule, order: Int = 0, firstPlayedBy: UnsafeMutablePointer<UInt8>? = nil, songNumber: UInt8 = 0) {
        self.module = module
        self.order = order
        self.firstPlayedBy = firstPlayedBy
        self.songNumber = songNumber
        coarse = module.tempo
        mixer = SampleMixer(channels: FarandoleModule.channels)
        channels = (0 ..< FarandoleModule.channels).map { Channel(side: Self.side(module.pans[$0]), heard: module.heard[$0]) }
        ordersPlayed = [Bool](repeating: false, count: max(1, module.orders.count))
        struck = [Bool](repeating: false, count: FarandoleModule.channels)
        setTempo(fineMovedBy: 0)
    }

    /// How many samples a second a note is played at: 16,726 for the C of the third octave of its
    /// six, and twice as many for each octave above.
    static func rate(ofNote note: Int) -> Double {
        16726 * pow(2.0, Double(note - 25) / 12)
    }

    private static func side(_ place: UInt8) -> Float { (Float(place & 15) - 7.5) / 7.5 }

    /// Works out the ticks from the tempo and the fine tempo, as the program did, oddities and all.
    private mutating func setTempo(fineMovedBy change: Int) {
        // (A fine tempo that has gone too far is put back, but not to where it went too far from.)
        if change < 0, Self.tempos[coarse] + fine <= 0 {
            fine = 0
        } else if change > 0, Self.tempos[coarse] + fine >= 100 {
            fine = 100
        }
        if newTempo {
            let tempo = Self.tempos[coarse] + fine
            guard tempo != 0 else { return }
            // What the timer is set to count to has sixteen bits: a tick too long for that is
            // halved, and halved again, and the row given more ticks to make up for it. (A tempo
            // of less than nothing is read as a very great number, and comes out very slow.)
            var divisor = UInt32(truncatingIfNeeded: Self.reckonedRate / tempo)
            var more = 0
            while divisor > 0xFFFF {
                divisor >>= 1
                more += 1
            }
            if more >= 2 { more += 1 }
            ticksToARow = 4 + more
            tickLength = max(1, Int(divisor))
        } else {
            // The older way: four ticks to a row whatever the tempo, and the fine tempo counts double.
            let tempo = Self.tempos[coarse] + fine * 2
            guard tempo > 0 else { return }
            ticksToARow = 4
            tickLength = Self.reckonedRate / tempo
        }
    }

    /// How many ticks apart a note is struck, to be struck so many times in its row.
    private func ticksApart(_ times: Int) -> Int? {
        guard times >= 1 else { return nil }
        let delay = (Self.tempos[coarse] + fine) / times
        if newTempo { return ((delay >> 2) + 1) >> 1 }
        let ticks = ((delay >> 1) + 1) >> 1
        return ticks >= 4 ? nil : max(1, ticks)
    }

    /// The pattern at the place in the list that is being played.
    private var pattern: Int { order < module.orders.count ? Int(module.orders[order]) : 0 }

    private mutating func strike(_ c: Int) {
        // (A note of a sample the file has not got is the end of what the channel was playing.)
        guard channels[c].sample >= 0, channels[c].sample < module.bank.sounds.count, let sound = module.bank.sounds[channels[c].sample] else {
            mixer.stop(c)
            return
        }
        mixer.play(c, sound)
        struck[c] = true
        playedNote = true
    }

    private mutating func readRow() {
        for c in 0 ..< FarandoleModule.channels {
            let cell = module.cell(pattern: pattern, row: row, channel: c)
            let command = Int(cell.command >> 4), value = Int(cell.command & 15)
            // What is for one row is over.
            channels[c].vibrato = false
            channels[c].bend = 0
            channels[c].nudge = 0
            channels[c].again = false

            let note = Int(cell.note)
            let slidesToIt = command == 3
            if note >= 1, note <= 72, !slidesToIt {
                // (A sample's number counts only beside a note.)
                channels[c].sample = Int(cell.sample)
                channels[c].rate = Self.rate(ofNote: note)
                // (And there is no note to slide to any more, until a slide names one.)
                channels[c].sliding = false
                channels[c].slideTo = 0
                channels[c].phase = 0
                strike(c)
            }
            // A volume: from 1 to 16 in the file, for 0 to 15. A note without one, or with one
            // that is no volume, is silent; and beside A it is where to slide to.
            let volume = Int(cell.volume)
            if command != 0xA {
                if volume >= 1, volume <= 16 {
                    channels[c].volume = (volume - 1) * 16
                    channels[c].fading = false
                } else if note != 0 || volume != 0 {
                    channels[c].volume = 0
                    channels[c].fading = false
                }
            }

            switch command {
            case 0x0:
                switch value {
                case 3: mixer.stop(c)
                case 4, 5:
                    newTempo = value == 5
                    setTempo(fineMovedBy: 0)
                default: break
                }
            case 0x1, 0x2:
                channels[c].bend = Double(value * 4) * Self.frequencyStep * (command == 1 ? 1 : -1)
                channels[c].sliding = false
            case 0x3:
                guard channels[c].sample >= 0 else { break }
                if note >= 1, note <= 72 { channels[c].slideTo = Self.rate(ofNote: note) }
                guard channels[c].slideTo > 0 else { break }
                // So much a tick as gets it there in as many rows as the command says, at the
                // tempo of four; at another tempo, in more or fewer.
                let distance = Int(abs(channels[c].slideTo - channels[c].rate))
                let tempo = max(1, Self.tempos[coarse] + fine)
                channels[c].slideBy = Double(max(1, distance * 8 / (tempo * max(1, value))))
                channels[c].sliding = true
            case 0x4:
                if note != 0, value > 1, let apart = ticksApart(value), apart <= ticksToARow {
                    channels[c].again = true
                    channels[c].apart = max(1, apart)
                    channels[c].untilNext = apart + 1
                    channels[c].left = value - 1
                }
            case 0x5:
                vibratoDepth = value
            case 0x6, 0x9:
                if !channels[c].vibratoHeld {
                    channels[c].vibratoHeld = command == 9
                    if !channels[c].vibratoHeld { channels[c].vibrato = true }
                }
                channels[c].vibratoRate = value
                if value == 0 {
                    channels[c].vibratoHeld = false
                    channels[c].vibratoKept = false
                } else if channels[c].vibratoHeld {
                    channels[c].vibratoKept = true
                }
            case 0x7: channels[c].nudge = value * 16
            case 0x8: channels[c].nudge = -value * 16
            case 0xA:
                guard volume >= 1, volume <= 16 else { break }
                let target = (volume - 1) * 16
                let tempo = max(1, Self.tempos[coarse] + fine)
                let distance = target - channels[c].volume
                var step = distance * 16 / (tempo * max(1, value))
                if step == 0 { step = distance > 0 ? 1 : -1 }
                channels[c].fadeTo = target
                channels[c].fadeBy = step
                channels[c].fading = distance != 0
            case 0xB:
                channels[c].side = Self.side(UInt8(value))
            case 0xC:
                if note != 0 {
                    // (With nought it is struck on every tick, which cannot have been meant.)
                    channels[c].again = true
                    channels[c].apart = max(1, value)
                    channels[c].untilNext = value + 1
                    channels[c].left = value != 0 ? 1 : 0
                }
            case 0xD:
                if value != 0 { fine -= value } else { fine = 0 }
                setTempo(fineMovedBy: -value)
            case 0xE:
                if value != 0 { fine += value } else { fine = 0 }
                setTempo(fineMovedBy: value)
            case 0xF:
                coarse = value
                setTempo(fineMovedBy: 0)
            default: break
            }
        }
    }

    /// One tick of a channel: what moves, and then what is heard.
    private mutating func carryOn(_ c: Int) {
        if channels[c].again {
            channels[c].untilNext -= 1
            if channels[c].untilNext == 0 {
                strike(c)
                channels[c].untilNext = channels[c].apart
                if channels[c].left > 0 {
                    channels[c].left -= 1
                    if channels[c].left == 0 { channels[c].again = false }
                }
            }
        }

        // The slides move on every tick, the row's first among them, and what is done once is done
        // on the first.
        if channels[c].sliding {
            if channels[c].rate < channels[c].slideTo {
                channels[c].rate = min(channels[c].slideTo, channels[c].rate + channels[c].slideBy)
            } else {
                channels[c].rate = max(channels[c].slideTo, channels[c].rate - channels[c].slideBy)
            }
            if channels[c].rate == channels[c].slideTo { channels[c].sliding = false }
        }
        if channels[c].fading {
            channels[c].volume += channels[c].fadeBy
            if channels[c].fadeBy > 0 ? channels[c].volume >= channels[c].fadeTo : channels[c].volume <= channels[c].fadeTo {
                channels[c].volume = channels[c].fadeTo
                channels[c].fading = false
            }
        }
        if tick == 0 {
            channels[c].rate = max(1, channels[c].rate + channels[c].bend)
            channels[c].volume = max(0, min(240, channels[c].volume + channels[c].nudge))
        }

        var heard = channels[c].rate
        if channels[c].vibrato || channels[c].vibratoKept {
            let depth = Int(Double(vibratoDepth * 2) * Self.frequencyStep)
            if channels[c].vibratoRate != 0 { heard += Double(Self.sine[channels[c].phase] * depth / 512) }
            channels[c].phase = (channels[c].phase + channels[c].vibratoRate * 3) & 63
        }
        mixer.setRate(c, max(1, heard))
        mixer.setVolume(c, channels[c].heard ? Float(channels[c].volume) / 240 : 0, side: channels[c].side)
    }

    /// Plays one tick: what the mixer is to play until the next is settled.
    /// - Returns: false if the tune came round on this tick, to a row it had already played or by
    ///   running off the end of its list.
    mutating func runTick() -> Bool {
        var more = true
        if !started {
            started = true
            if order >= module.orders.count {
                order = 0
                more = false
            }
        } else {
            tick += 1
            if tick >= ticksToARow {
                tick = 0
                if row >= module.patterns[pattern].lastRow {
                    row = 0
                    order += 1
                    if order >= module.orders.count {
                        order = module.restart
                        more = false
                    }
                } else {
                    row += 1
                }
            }
        }
        if tick == 0 {
            if order < ordersPlayed.count { ordersPlayed[order] = true }
            // Whose row this is: a row some song has played already is the end of this one.
            if let firstPlayedBy, order < module.orders.count {
                let at = order * FarandoleModule.mostRows + row
                if firstPlayedBy[at] == ModuleSongs.unplayed {
                    firstPlayedBy[at] = songNumber
                } else {
                    if firstPlayedBy[at] != songNumber { ledIntoEarlierSong = true }
                    more = false
                }
            }
            readRow()
        }
        for c in 0 ..< FarandoleModule.channels { carryOn(c) }
        return more
    }

    /// The pitch each channel has now, and whether a note was started on it since this was last asked.
    mutating func takeNotes(into notes: inout TickNotes) {
        for c in 0 ..< FarandoleModule.channels {
            notes.pitches[c] = mixer.isPlaying(c) && mixer.volume(of: c) > 0 ? ChannelPitch.note(ofRate: mixer.rate(of: c)) : 0
            if struck[c] { notes.struck[c] = true }
            struck[c] = false
        }
    }
}
