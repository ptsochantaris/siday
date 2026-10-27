// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from st2play, Copyright 2017 Sergei "x0r" Kolzun, used under the Apache License, Version
// 2.0 (see THIRD-PARTY.md): this is its `stmload.c`. The checks a file is held to before it is
// taken for one are OpenMPT's.

import SidayFoundation

/// An STM file: a module of Scream Tracker 2, which Sami Tammilehto of Future Crew wrote for the PC
/// in 1990, before the Scream Tracker 3 that S3M files are from.
///
/// There are four channels, 31 samples of eight bits, each of which may go round, up to 64 patterns
/// of 64 rows, and a list of which pattern to play when. A note is a pitch, a sample and a volume,
/// and beside it there may be one command.
final class ST2Module {
    static let channels = 4
    static let rows = 64
    private static let header = 48, sampleHeader = 32, samplesInAll = 31, patternSize = rows * channels * 4

    struct Sample {
        /// Where its sound is among the module's, and how much of it there is; none of it for a
        /// sample the file has no sound for.
        var base = -1, count = 0
        var length: UInt16 = 0
        var loopStart: UInt16 = 0
        /// 0xFFFF for a sample that does not go round.
        var loopEnd: UInt16 = 0xFFFF
        var volume: UInt8 = 0
        /// How many samples a second it is played at for the C of the third octave.
        var c2spd: UInt16 = 8192
    }

    let title: String
    /// The tune's first tempo: ticks to the row in its high half, and a factor in its low half.
    let tempo: UInt8
    let globalVolume: UInt8
    /// The list of patterns, all 128 places of it.
    let orders: [UInt8]
    /// Where the list first ends: Scream Tracker plays no further.
    let listEnd: Int
    let patternCount: Int
    /// The patterns as Scream Tracker holds them: four bytes to a channel's part of a row.
    private let cells: UnsafeMutablePointer<UInt8>
    private let cellCount: Int
    /// The sound of all the samples, one after another. Bytes with a sign.
    let sound: UnsafeMutablePointer<UInt8>
    /// What gives `cells` and `sound` back, also for a file that turns out not to be an STM.
    private let cellMemory: Memory<UInt8>, soundMemory: Memory<UInt8>
    /// The samples by their numbers, from 1; there is no sample 0.
    let samples: [Sample]
    let shortfalls: [String]

    /// In the list of patterns: the end of the list, to go round from where the tune was started,
    /// and to go round from the top.
    static let end: UInt8 = 99, endToTop: UInt8 = 98

    /// - Parameter asST2Play: true to read a sample that goes round past its own end as st2play
    ///   reads it, for setting this player beside that one: the end is brought in. Scream Tracker
    ///   went on into whatever lay after the sample, which in the file is the next sample.
    init(_ data: [UInt8], asST2Play: Bool = false) throws {
        let file = ByteReader(data)
        func refuse() -> TuneError { TuneError.malformed("not an STM file") }
        guard data.count >= Self.header + Self.samplesInAll * Self.sampleHeader + 64 else { throw refuse() }
        // (A name for the program that wrote it, which Scream Tracker did not check: but a file
        // has little else to be known by.)
        guard data[20 ..< 28].allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), data[28] == 0x1A || data[28] == 2 else { throw refuse() }
        guard data[29] == 2 else {
            throw data[29] == 1 ? TuneError.unsupported("an STM song, which is a tune without its samples") : refuse()
        }
        let minor = data[31]
        guard data[30] == 2, minor == 0 || minor == 10 || minor == 20 || minor == 21 else { throw refuse() }
        let patterns = Int(data[33])
        guard patterns <= 64, data[34] <= 64 || data[34] == 0x58 else { throw refuse() }
        title = file.dos(at: 0, length: 20)
        // Before 2.21 a tempo was written as it was typed, in tens and units.
        func asTyped(_ value: UInt8) -> UInt8 { minor < 21 ? (value / 10) << 4 &+ value % 10 : value }
        let tempo = asTyped(data[32])
        self.tempo = tempo == 0 ? 0x60 : tempo
        globalVolume = minor > 10 ? min(data[34], 64) : 64

        let ordersAt = Self.header + Self.samplesInAll * Self.sampleHeader
        let listed = minor == 0 ? 64 : 128
        var orders = [UInt8](repeating: Self.end, count: 128)
        for i in 0 ..< listed {
            let order = file[ordersAt + i]
            guard order <= 63 || order == Self.end || order == Self.endToTop || order == 255 else { throw refuse() }
            orders[i] = order
        }
        self.orders = orders
        listEnd = orders.firstIndex { $0 > 63 } ?? 128
        patternCount = patterns

        // The patterns. A cell is four bytes, or one byte that stands for four.
        var at = ordersAt + listed
        guard data.count >= at + patterns * Self.rows * Self.channels else { throw TuneError.malformed("an STM file that ends before its patterns do") }
        cellCount = patterns * Self.patternSize
        cellMemory = Memory(capacity: max(1, cellCount))
        cells = cellMemory.pointer
        for pattern in 0 ..< patterns {
            for cell in 0 ..< Self.rows * Self.channels {
                let to = cells + pattern * Self.patternSize + cell * 4
                let code = at < data.count ? data[at] : 0xFC
                at += 1
                switch code {
                case 0xFB: (to[0], to[1], to[2], to[3]) = (0, 0, 0, 0)
                case 0xFC: (to[0], to[1], to[2], to[3]) = (0xFF, 0x01, 0x80, 0)
                case 0xFD: (to[0], to[1], to[2], to[3]) = (0xFE, 0x01, 0x80, 0)
                default:
                    (to[0], to[1], to[2], to[3]) = (code, file[at], file[at + 1], file[at + 2])
                    at += 3
                    if to[2] & 0x0F == 1 { to[3] = asTyped(to[3]) }
                }
            }
        }
        let patternsEnd = at

        // The samples: those that have a volume and a length, as Scream Tracker loads them.
        var samples = [Sample](repeating: Sample(), count: 32)
        var cut = Shortfall.CutShort()
        var room = 0
        for number in 1 ... Self.samplesInAll {
            let at = Self.header + (number - 1) * Self.sampleHeader
            guard data[at + 12] == 0 || data[at + 12] == 46 else { throw refuse() }
            var sample = Sample()
            sample.length = UInt16(file.u16le(at + 16))
            sample.loopStart = UInt16(file.u16le(at + 18))
            sample.loopEnd = UInt16(file.u16le(at + 20))
            if sample.loopEnd == 0 { sample.loopEnd = 0xFFFF }
            sample.volume = data[at + 22]
            sample.c2spd = UInt16(file.u16le(at + 24))
            if asST2Play, sample.loopEnd != 0xFFFF, sample.loopEnd > sample.length { sample.loopEnd = sample.length }
            if sample.volume != 0, sample.length != 0 {
                sample.base = room
                sample.count = Int(sample.loopEnd != 0xFFFF ? max(sample.length, sample.loopEnd) : sample.length)
                room += sample.count
            }
            samples[number] = sample
        }
        // (Which of them the tune plays: many a file has the name of a sample and no more of it.)
        var used = [Bool](repeating: false, count: 32)
        for place in 0 ..< listEnd where Int(orders[place]) < patterns {
            for cell in 0 ..< Self.rows * Self.channels {
                used[Int(cells[Int(orders[place]) * Self.patternSize + cell * 4 + 1] >> 3)] = true
            }
        }
        soundMemory = Memory(capacity: max(1, room))
        sound = soundMemory.pointer
        sound.initialize(repeating: 0, count: max(1, room))
        for number in 1 ... Self.samplesInAll where samples[number].base >= 0 {
            let from = file.u16le(Self.header + (number - 1) * Self.sampleHeader + 14) << 4
            let there = max(0, min(samples[number].count, data.count - from))
            for i in 0 ..< there { sound[samples[number].base + i] = data[from + i] }
            if used[number] { cut.add(length: Int(samples[number].length), there: data.count - from) }
        }
        guard Shortfall.sounds(sound, count: room) else { throw Shortfall.nothingToHear }
        self.samples = samples
        // (What the file has lost of its patterns is rows with nothing in them.)
        var said = cut.sentence.map { [$0] } ?? []
        if patternsEnd > data.count { said.append(Shortfall.patternsLost(samplesToo: cut.sentence != nil)) }
        shortfalls = said
    }

    /// The four bytes at a place among the patterns. A pattern the file has none of is one with
    /// nothing in it: Scream Tracker did not save the empty patterns at the end of a tune, and a
    /// list may well name one.
    @inline(__always)
    func cell(at place: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        guard place >= 0, place + 3 < cellCount else { return (0xFF, 0x01, 0x80, 0) }
        return (cells[place], cells[place + 1], cells[place + 2], cells[place + 3])
    }

    /// The pattern at a place in the list; past the list's end, the mark of its end. (And a number
    /// that is neither a pattern's nor a mark is taken for the end.)
    @inline(__always)
    func order(_ place: Int) -> UInt8 {
        guard place >= 0, place < orders.count else { return Self.end }
        return orders[place] > 63 && orders[place] != Self.endToTop ? Self.end : orders[place]
    }
}
