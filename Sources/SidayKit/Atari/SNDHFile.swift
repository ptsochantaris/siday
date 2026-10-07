// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The reading of the header follows AtariAudio, Copyright (c) Arnaud Carré, used under the MIT licence
// (see THIRD-PARTY.md), so that a file is understood here as it is there.

/// An SNDH file: a piece of Atari ST music as the machine played it. It is not a recording of the
/// sound chip but the program that drove it, cut out of the game or demo it came from: 68000 code and
/// its data, with three ways in at its head (start a song, stop, and play one tick) and a few words
/// about itself after them. Most are packed with Ice.
struct SNDHFile {
    /// The file unpacked: what goes into the machine's memory.
    var image: [UInt8]
    var title = ""
    var composer = ""
    var ripper = ""
    var converter = ""
    var year = ""
    var songs = 1
    /// The song to play first, counted from 1.
    var firstSong = 1
    /// How many times a second the player's code is to be called.
    var tickRate = 50
    /// Each song's length in seconds, where the file gives it so; 0 where it does not.
    var seconds: [Int] = []
    /// Each song's length in calls of the player, where the file gives it so; 0 where it does not.
    /// This is the newer and the more exact of the two.
    var ticks: [Int] = []

    static let mostSongs = 128

    init(_ data: [UInt8]) throws {
        if ICE.isPacked(data) {
            guard let unpacked = ICE.unpack(data) else { throw TuneError.malformed("the Ice packing is damaged") }
            image = unpacked
        } else {
            image = data
        }
        let file = ByteReader(image)
        // A branch over the header, two more branches, and then the four letters.
        guard image.count > 16, file[0] == 0x60, file.ascii(at: 12, length: 4) == "SNDH" else {
            throw TuneError.malformed("not an SNDH file")
        }
        let end = file[1] != 0 ? Int(Int8(bitPattern: file[1])) + 2 : file.u16be(2) + 2

        func tag(_ name: StaticString, at place: Int) -> Bool {
            name.withUTF8Buffer { name in
                for (index, character) in name.enumerated() where file[place + index] != character { return false }
                return true
            }
        }
        func text(at place: Int) -> (String, Int) { file.cString(at: place) }
        /// The number a run of digits spells, as C's `atoi` reads it.
        func number(at place: Int, digits: Int = .max) -> Int {
            var place = place, value = 0, read = 0
            while file[place] == 0x20, read < digits {
                place += 1
                read += 1
            }
            while read < digits, file[place] >= 0x30, file[place] <= 0x39, value < 100_000_000 {
                value = value * 10 + Int(file[place] - 0x30)
                place += 1
                read += 1
            }
            return value
        }

        seconds = [Int](repeating: 0, count: Self.mostSongs)
        ticks = seconds
        var tags = 0
        var place = 16
        while place + 4 <= end {
            if tag("!#SN", at: place) {
                // Where each song's name is: two bytes a song.
                place += 4 + songs * 2
                tags += 1
            }
            if tag("!#", at: place) {
                firstSong = number(at: place + 2)
                place = text(at: place + 2).1
                tags += 1
            } else if tag("TITL", at: place) {
                (title, place) = text(at: place + 4)
                tags += 1
            } else if tag("COMM", at: place) {
                (composer, place) = text(at: place + 4)
                tags += 1
            } else if tag("RIPP", at: place) {
                (ripper, place) = text(at: place + 4)
                tags += 1
            } else if tag("CONV", at: place) {
                (converter, place) = text(at: place + 4)
                tags += 1
            } else if tag("YEAR", at: place) {
                (year, place) = text(at: place + 4)
                tags += 1
            } else if tag("##", at: place) {
                songs = number(at: place + 2, digits: 2)
                // Some files have this wrong.
                if songs <= 0 || songs > Self.mostSongs { songs = 1 }
                place += 4
                tags += 1
            } else if tag("TIME", at: place) {
                // In seconds, a word for each song, on a word boundary.
                place += 4
                if place & 1 != 0 { place += 1 }
                for song in 0 ..< songs {
                    seconds[song] = file.u16be(place)
                    place += 2
                }
                tags += 1
            } else if tag("FRMS", at: place) {
                // In calls of the player, a long for each song.
                place += 4
                for song in 0 ..< songs {
                    // (A length too long to be one is no length.)
                    ticks[song] = file[place] < 0x40 ? file.u32be(place) : 0
                    place += 4
                }
                tags += 1
            } else if tag("HDNS", at: place) {
                break
            } else if tag("TA", at: place) || tag("TB", at: place) || tag("TC", at: place) || tag("TD", at: place) || tag("!V", at: place) {
                // Which of the machine's timers called the player, or the screen's own rate, and how often.
                tickRate = number(at: place + 2)
                place = text(at: place + 2).1
                tags += 1
            } else {
                place += 1
            }
        }
        guard tags >= 1 else { throw TuneError.malformed("an SNDH file with nothing in its header") }
        guard tickRate > 0, tickRate <= 2000 else { throw TuneError.malformed("an SNDH file with no usable replay rate") }
        if firstSong > songs || firstSong < 1 { firstSong = 1 }
        seconds = Array(seconds[..<songs])
        ticks = Array(ticks[..<songs])
    }
}
