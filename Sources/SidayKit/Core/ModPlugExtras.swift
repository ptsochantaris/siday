// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written for siday from OpenMPT's own account of what it adds to a file (its loaders, Copyright (c)
// 2004-2026 OpenMPT Project Developers and Contributors, BSD 3-Clause: see THIRD-PARTY.md). No code
// here is taken from it.

/// What ModPlug Tracker and OpenMPT add to an XM or an IT file that the trackers those files belong
/// to know nothing of: plug-ins, and which instruments and channels are played through them.
///
/// None of it is played here. It is read only so that a tune that needs it can be said to
/// (`TuneInfo.shortfalls`): an instrument that is nothing but a plug-in is silent without it.
struct ModPlugExtras {
    /// Which of the places for a plug-in, counted from 1, has one in it.
    private(set) var hasPlugIn = [Bool](repeating: false, count: 256)
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
                if slot + 1 < hasPlugIn.count, length >= 8, (0 ..< 8).contains(where: { file[body + $0] != 0 }) { hasPlugIn[slot + 1] = true }
            } else if code != Self.name("text"), code != Self.name("MIDI"), code != Self.name("PNAM"), code != Self.name("CNAM") {
                break
            }
            at = body + length
        }
        return at
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
