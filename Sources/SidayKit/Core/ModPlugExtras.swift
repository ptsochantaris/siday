// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written for siday from OpenMPT's own account of what it adds to a file (its loaders, Copyright (c)
// 2004-2026 OpenMPT Project Developers and Contributors, BSD 3-Clause: see THIRD-PARTY.md). No code
// here is taken from it.

/// What ModPlug Tracker and OpenMPT add to an XM or an IT file that the trackers those files belong
/// to know nothing of: plug-ins, and which instruments and channels are played through them.
///
/// The plug-ins that are OpenMPT's own are played, by the replayer that has been taught to (see
/// `ModPlugSound`). The rest are read so that a tune that needs them can be said to
/// (`TuneInfo.shortfalls`): an instrument that is nothing but a plug-in is silent without it.
struct ModPlugExtras {
    /// Which of the places for a plug-in, counted from 1, has one in it.
    private(set) var hasPlugIn = [Bool](repeating: false, count: 256)
    /// The plug-ins themselves, the first place first; one that is not there for a place left empty.
    private(set) var plugIns: [ModPlugPlugIn] = []
    /// What the song's own extras say of how loud it is, where they say: which of OpenMPT's ways
    /// of adding up, its "sample pre-amp" and its "synth volume".
    private(set) var mixLevels: Int?, preAmp: Int?, synthVolume: Int?
    /// The plug-in each channel is sent through, counted from 1; nought for none.
    private(set) var channelPlugIns: [Int] = []
    /// And the one each instrument plays through, the first instrument first.
    private(set) var instrumentPlugIns: [Int] = []

    private static func name(_ text: StaticString) -> Int {
        text.withUTF8Buffer { Int($0[0]) | Int($0[1]) << 8 | Int($0[2]) << 16 | Int($0[3]) << 24 }
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    /// How many channels are sent through a plug-in that is there.
    var channelsThroughPlugIns: Int {
        channelPlugIns.filter { $0 > 0 && $0 < hasPlugIn.count && hasPlugIn[$0] }.count
    }

    /// True if an instrument, counted from nought, plays through a plug-in that is there.
    func playsThroughPlugIn(instrument: Int) -> Bool {
        guard instrument >= 0, instrument < instrumentPlugIns.count else { return false }
        let slot = instrumentPlugIns[instrument]
        return slot > 0 && slot < hasPlugIn.count && hasPlugIn[slot]
    }

    /// Says that an instrument plays through a plug-in: an IT file has it in the instrument itself.
    mutating func set(plugIn slot: Int, ofInstrument instrument: Int) {
        while instrumentPlugIns.count <= instrument { instrumentPlugIns.append(0) }
        instrumentPlugIns[instrument] = slot
    }

    /// Reads the pieces these trackers put one after another in a file, each with four letters and a
    /// length: the song's text and its names, which are passed over, and the plug-ins. Stops at
    /// the first thing that is none of them, and says where that is.
    /// Where the file's macros are, if it has any of its own: what the commands Z and the one
    /// after it send. Nine lines of 32 letters for the song, then the sixteen that take the
    /// command's value, then the 128 with values of their own.
    private(set) var macros: (at: Int, length: Int)?

    /// What one of those macros does to a channel's filter, if that is what it is for: 0 if it
    /// sets where the filter closes and 1 if it sets how it rings, with the value it sets, or nil
    /// for the command's own. Such a macro is "F0F000z" or "F0F001" and two digits.
    /// - Parameter number: 0 to 15 for those that take the command's value, 16 on for the others.
    func filterMacro(_ file: ByteReader, _ number: Int) -> (sets: UInt8, value: UInt8?)? {
        guard let macros, number >= 0, (9 + number + 1) * 32 <= macros.length else { return nil }
        var letters: [UInt8] = []
        for k in 0 ..< 32 {
            let byte = file[macros.at + (9 + number) * 32 + k]
            if byte == 0 { break }
            if byte != 0x20 { letters.append(byte >= 0x61 && byte <= 0x66 ? byte - 0x20 : byte) }
        }
        func digit(_ byte: UInt8) -> UInt8? { byte >= 0x30 && byte <= 0x39 ? byte - 0x30 : byte >= 0x41 && byte <= 0x46 ? byte - 0x37 : nil }
        guard letters.count >= 7, Array(letters[0 ..< 5]) == Array("F0F00".utf8), let sets = digit(letters[5]), sets <= 1 else { return nil }
        if letters.count == 7, letters[6] == 0x7A { return (sets, nil) }
        guard letters.count == 8, let high = digit(letters[6]), let low = digit(letters[7]) else { return nil }
        return (sets, high << 4 | low)
    }

    /// True if one of those macros sends anything at all.
    func macroSendsSomething(_ file: ByteReader, _ number: Int) -> Bool {
        guard let macros, number >= 0, (9 + number + 1) * 32 <= macros.length else { return false }
        let first = file[macros.at + (9 + number) * 32]
        return first != 0 && first != 0x20
    }

    mutating func readPieces(_ file: ByteReader, at start: Int, before end: Int) -> Int {
        var at = start
        while at >= 0, at + 8 <= end {
            let code = file.u16le(at) | file.u16le(at + 2) << 16
            let high = file.u16le(at + 6)
            guard high < 0x4000 else { break }
            let length = high << 16 | file.u16le(at + 4)
            guard length <= end - at - 8 else { break }
            let body = at + 8
            if code == Self.name("CHFX") {
                channelPlugIns = (0 ..< min(length / 4, 256)).map { file.u16le(body + $0 * 4) }
            } else if file[at] == 0x46, file[at + 1] == 0x58 || Self.isDigit(file[at + 1]), Self.isDigit(file[at + 2]), Self.isDigit(file[at + 3]) {
                // A plug-in: "FX" and two figures, or "F" and three. The place is in use if it
                // says which plug-in it is, in its first eight bytes.
                var slot = Int(file[at + 2] - 0x30) * 10 + Int(file[at + 3] - 0x30)
                if file[at + 1] != 0x58 { slot += Int(file[at + 1] - 0x30) * 100 }
                if slot + 1 < hasPlugIn.count, length >= 8, (0 ..< 8).contains(where: { file[body + $0] != 0 }) {
                    hasPlugIn[slot + 1] = true
                    while plugIns.count <= slot { plugIns.append(ModPlugPlugIn()) }
                    plugIns[slot] = ModPlugPlugIn(file.data, at: body, size: length)
                }
            } else if code == Self.name("MIDI") {
                macros = (body, length)
            } else if code != Self.name("text"), code != Self.name("PNAM"), code != Self.name("CNAM") {
                break
            }
            at = body + length
        }
        return at
    }

    /// True if the plug-in in a place, counted from 1, is one of OpenMPT's own, which are played.
    func isPlayed(plugIn slot: Int) -> Bool {
        slot >= 1 && slot <= plugIns.count && plugIns[slot - 1].kind != nil
    }

    /// The names of the plug-ins that are not OpenMPT's own, and how many plug-ins there are in all.
    var plugInsLeftOut: (names: [String], all: Int) {
        let there = plugIns.filter { $0.isThere }
        return (there.filter { $0.kind == nil }.map { $0.title }, there.count)
    }

    /// Reads the song's own extras, which these trackers put after everything else in a file and
    /// begin "STPM": a list of things, each with a name, a size and a value. Only what bears on
    /// how loud the song is played is kept.
    mutating func readSongExtras(_ file: ByteReader) {
        let data = file.data
        // (The last of them, if the letters come up more than once: the real one is at the end.)
        var at = data.count - 4
        while at >= 0, !(data[at] == 0x53 && data[at + 1] == 0x54 && data[at + 2] == 0x50 && data[at + 3] == 0x4D) { at -= 1 }
        guard at >= 0 else { return }
        at += 4
        while at + 6 <= data.count {
            let code = file.u16le(at) | file.u16le(at + 2) << 16
            let size = file.u16le(at + 4)
            guard (0 ..< 4).allSatisfy({ data[at + $0] >= 0x20 && data[at + $0] < 0x7F }), at + 6 + size <= data.count else { break }
            let value = size >= 4 ? file.u16le(at + 6) | min(file.u16le(at + 8), 0x3FFF) << 16 : size >= 2 ? file.u16le(at + 6) : size == 1 ? Int(data[at + 6]) : 0
            if code == Self.name(".MMP") { mixLevels = value } else if code == Self.name(".APS") { preAmp = value } else if code == Self.name("VTSV") { synthVolume = value }
            at += 6 + size
        }
    }

    /// Reads what is said of each instrument beyond what its own tracker could say, which begins
    /// "XTPM" somewhere at or after `start`: a list of things, each with a name, a size, and a
    /// value of that size for every instrument. Only which plug-in each plays through is kept.
    mutating func readInstrumentExtras(_ file: ByteReader, from start: Int, instruments: Int) {
        guard instruments > 0, start >= 0 else { return }
        var at = start
        let data = file.data
        // (The letters are written last first.)
        while at + 4 <= data.count, !(data[at] == 0x58 && data[at + 1] == 0x54 && data[at + 2] == 0x50 && data[at + 3] == 0x4D) { at += 1 }
        at += 4
        while at + 6 <= data.count {
            let code = file.u16le(at) | file.u16le(at + 2) << 16
            // A name is letters; anything else is the end of the list.
            guard (0 ..< 4).allSatisfy({ data[at + $0] >= 0x20 && data[at + $0] < 0x7F }), code != Self.name("STPM") else { break }
            let size = file.u16le(at + 4)
            at += 6
            if code == Self.name(".PiM"), size >= 1 {
                for instrument in 0 ..< instruments where at + instrument * size < data.count {
                    set(plugIn: Int(data[at + instrument * size]), ofInstrument: instrument)
                }
            }
            at += size * instruments
        }
    }
}
