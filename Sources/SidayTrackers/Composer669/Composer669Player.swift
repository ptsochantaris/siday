// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written for siday. What each command does is from the descriptions that came with Composer 669
// and UNIS 669; how much it does, in cycles a second, is as OpenMPT has it, whose authors set
// their player beside Composer 669 itself, and as libxmp has it, which agrees (see THIRD-PARTY.md).
// No code here is taken from either.

import SidayFoundation

/// Plays a 669 file, a tick at a time, on `SampleMixer`.
///
/// Composer 669 is unlike the trackers that came from the Amiga in one thing above all. They count
/// a note's pitch as a period, the time between one sample and the next, and slide it by adding to
/// that; so a slide of a given size is a wider step the higher the note. Composer 669 counts in
/// samples a second, and slides by adding to that: its slides are widest on the lowest notes. That
/// is why it has a player of its own here, and is not turned into some other tracker's module.
///
/// A command goes on working, row after row, until the channel has another command or another
/// note: so a slide need be written once. Its commands are few:
/// - a and b slide the pitch up and down, by 80 samples a second for each one of the command's
///   value, on every tick;
/// - c, beside a note, slides to that note and does not strike it, by 40 for each one, and stops there;
/// - d plays the note a little sharp, by 80 for each one;
/// - e is a trill more than a vibrato: every other tick the note is 668 samples a second higher
///   for each one of the value;
/// - f sets how many ticks a row lasts, for every channel, until the next pattern begins.
/// UNIS 669 added g, which moves the channel a little to the left or the right on every row, and
/// h, which strikes the note again and again through its row.
///
/// A tick is one seventy-eighth of two and a half seconds, about a thirty-second of a second.
struct Composer669Player: ~Copyable {
    private enum Command {
        case none
        case slide(Int)
        case slideTo(Int)
        case trill(Int)
        case drift(Float)
    }

    private struct Channel {
        var sample = -1
        /// Samples a second: what it is at, and what it is sliding to.
        var rate = 0, target = 0
        /// What d has added to it, which lasts as long as the note does.
        var sharp = 0
        var volume = 0
        var side: Float = 0
        var command = Command.none
        /// How many ticks the trill has gone on for.
        var trilled = 0
        /// How many ticks apart the note is struck again, on this row; nought if it is not.
        var again = 0
    }

    let module: Composer669Module
    var mixer: SampleMixer
    private var channels: [Channel]
    private(set) var order: Int
    private(set) var row = 0
    private var tick = 0
    var tickNow: Int { tick }
    private(set) var speed = 4
    private var started = false

    /// For telling the file's songs apart: see `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>?
    private let songNumber: UInt8
    private(set) var ordersPlayed: [Bool]
    private(set) var playedNote = false
    private(set) var ledIntoEarlierSong = false
    /// What each channel is playing, for the pictures.
    private(set) var struck: [Bool]

    /// A tick is so many samples of output over so many: 2.5 seconds over 78.
    static let tickFrames = (whole: outputSampleRate * 5 / 156, over: outputSampleRate * 5 % 156, of: 156)
    /// Where the channels sit, the first on the left. Composer 669 had them all the way to one
    /// side or the other, which is all a Sound Blaster Pro could do, and is hard on the ears in
    /// headphones; they are brought in here as far as OpenMPT brings them, to five eighths of the way.
    private static let sides: [Float] = [-0.625, 0.625, -0.625, 0.625, -0.625, 0.625, -0.625, 0.625]
    /// The lowest pitch a note is played at, in samples a second.
    private static let lowest = 112
    /// How far g moves a channel on each row, of the whole way from one side to the other.
    private static let drift: Float = 4.0 / 256.0 * 2

    init(_ module: Composer669Module, order: Int = 0, firstPlayedBy: UnsafeMutablePointer<UInt8>? = nil, songNumber: UInt8 = 0) {
        self.module = module
        self.order = order
        self.firstPlayedBy = firstPlayedBy
        self.songNumber = songNumber
        mixer = SampleMixer(channels: Composer669Module.channels)
        channels = (0 ..< Composer669Module.channels).map { Channel(side: Self.sides[$0]) }
        ordersPlayed = [Bool](repeating: false, count: max(1, module.orders.count))
        struck = [Bool](repeating: false, count: Composer669Module.channels)
    }

    /// How many samples a second a note is played at: 8,363 for the C of its third octave, and
    /// twice as many for each octave above.
    static func rate(ofNote note: Int) -> Int {
        Int(8363 * pow(2.0, Double(note - 24) / 12))
    }

    /// The pattern at the place in the list that is being played; nil if there is none there.
    private var pattern: Int? {
        guard order < module.orders.count else { return nil }
        let pattern = Int(module.orders[order])
        return pattern < module.patternCount ? pattern : nil
    }

    /// Goes to a place in the list that has a pattern, from the one given: on over what is not a
    /// pattern, and round from the end.
    /// - Returns: false if the end of the list was come to on the way.
    private mutating func settle(at place: Int) -> Bool {
        var place = place, round = false
        for _ in 0 ... module.orders.count {
            if place >= module.orders.count {
                place = module.restart
                round = true
            }
            if place < module.orders.count, module.orders[place] < module.patternCount { break }
            place += 1
        }
        order = min(place, max(0, module.orders.count - 1))
        row = 0
        if let pattern { speed = max(1, Int(module.speeds[pattern])) }
        return !round
    }

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

    /// Reads a row: its notes, its volumes and its commands.
    private mutating func readRow(_ pattern: Int) {
        for c in 0 ..< Composer669Module.channels {
            let (first, second, third) = module.cell(pattern: pattern, row: row, channel: c)
            let hasNote = first < 0xFE
            let hasCommand = third != 0xFF
            let kind = Int(third >> 4), value = Int(third & 0x0F)
            channels[c].again = 0
            if hasNote {
                let rate = Self.rate(ofNote: Int(first >> 2))
                // (Beside c a note is where to slide to, and is not struck: unless nothing is
                // sounding to slide from.)
                if hasCommand, kind == 2, mixer.isPlaying(c), channels[c].rate > 0 {
                    channels[c].target = rate
                } else {
                    channels[c].sample = Int(first & 3) << 4 | Int(second >> 4)
                    channels[c].rate = rate
                    channels[c].target = rate
                    channels[c].sharp = 0
                    channels[c].trilled = 0
                    channels[c].command = .none
                    strike(c)
                }
            }
            if first <= 0xFE { channels[c].volume = Int(second & 0x0F) }
            guard hasCommand else { continue }
            // Another command is the end of the one before it, whatever either is.
            channels[c].command = .none
            switch kind {
            case 0: if value != 0 { channels[c].command = .slide(80 * value) }
            case 1: if value != 0 { channels[c].command = .slide(-80 * value) }
            case 2: if value != 0 { channels[c].command = .slideTo(40 * value) }
            case 3: channels[c].sharp = 80 * value
            case 4:
                if value != 0 { channels[c].command = .trill(668 * value) }
            case 5: if value != 0 { speed = value }
            case 6:
                guard module.extended else { break }
                if value == 0 { channels[c].command = .drift(-Self.drift) } else if value == 1 { channels[c].command = .drift(Self.drift) }
            case 7: if module.extended, hasNote, value != 0 { channels[c].again = value }
            default: break
            }
        }
    }

    /// What every tick does to a channel: its command carried on, and the mixer told the outcome.
    private mutating func carryOn(_ c: Int) {
        var rate = channels[c].rate
        var heard = 0
        switch channels[c].command {
        case .none: break
        case let .slide(by):
            if rate > 0 { rate = max(1, rate + by) }
        case let .slideTo(by):
            if rate > 0, channels[c].target > 0 {
                rate = rate < channels[c].target ? min(channels[c].target, rate + by) : max(channels[c].target, rate - by)
            }
        case let .trill(by):
            if channels[c].trilled % 2 == 1 { heard = by }
            channels[c].trilled += 1
        case let .drift(by):
            if tick == 0 { channels[c].side = max(-1, min(1, channels[c].side + by)) }
        }
        channels[c].rate = rate
        if channels[c].again > 0, tick > 0, tick % channels[c].again == 0 { strike(c) }
        mixer.setRate(c, Double(max(Self.lowest, rate + heard + channels[c].sharp)))
        mixer.setVolume(c, Float(channels[c].volume) / 15, side: channels[c].side)
    }

    /// Plays one tick: what the mixer is to play until the next is settled.
    /// - Returns: false if the tune came round on this tick, to a row it had already played or by
    ///   running off the end of its list.
    mutating func runTick() -> Bool {
        var more = true
        if !started {
            started = true
            more = settle(at: order)
            tick = 0
        } else {
            tick += 1
            if tick >= speed {
                tick = 0
                let last = pattern.map { Int(module.lastRows[$0]) } ?? 0
                if row >= last || row >= Composer669Module.rows - 1 {
                    more = settle(at: order + 1)
                } else {
                    row += 1
                }
            }
        }
        if tick == 0, let pattern {
            if order < ordersPlayed.count { ordersPlayed[order] = true }
            // Whose row this is: a row some song has played already is the end of this one.
            if let firstPlayedBy {
                let at = order * Composer669Module.rows + row
                if firstPlayedBy[at] == ModuleSongs.unplayed {
                    firstPlayedBy[at] = songNumber
                } else {
                    if firstPlayedBy[at] != songNumber { ledIntoEarlierSong = true }
                    more = false
                }
            }
            readRow(pattern)
        }
        for c in 0 ..< Composer669Module.channels { carryOn(c) }
        return more
    }

    /// The pitch each channel has now, and whether a note was started on it since this was last asked.
    mutating func takeNotes(into notes: inout TickNotes) {
        for c in 0 ..< Composer669Module.channels {
            notes.pitches[c] = mixer.isPlaying(c) && mixer.volume(of: c) > 0 ? ChannelPitch.note(ofRate: mixer.rate(of: c)) : 0
            if struck[c] { notes.struck[c] = true }
            struck[c] = false
        }
    }
}
