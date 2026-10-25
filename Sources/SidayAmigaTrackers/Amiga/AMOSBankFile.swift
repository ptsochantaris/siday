// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// After UADE's player of these banks (amigasrc/players/ambk/AMOS.s, "Amos Music Bank Player (Dec
// 2004)": François Lionet's format, adapted by DEFECT, put together for UADE by mld; GPL, version 2
// or later), whose converter is followed here step for step.

import SidayFoundation

/// An AMOS music bank: the music of a program written in AMOS, François Lionet's BASIC for the
/// Amiga, kept as a bank of the program's, "AmBk", of the kind "Music   ". It holds instruments
/// (samples), songs and patterns; a song is a list of patterns for each of the four voices, and a
/// pattern one voice's notes and commands, as words, with a command to wait so many lines between them.
///
/// It is made a ProTracker module, as UADE makes it: the samples' headers from the instruments', the
/// order from the first voice's list, the lines of each voice's patterns side by side, each command
/// ProTracker's like it (volume C, tempo F as a hundred over AMOS's, arpeggio 0, slides to a note 3,
/// vibrato 4, volume slides A, slides up 1 and down 2, a jump B, the end of a pattern D on the line
/// before it), the last of the commands that go on kept on every line until another or a stop; and
/// the samples after the patterns.
enum AMOSBankFile {
    /// Where the bank's own header begins (past "AmBk", or at the start of a bank kept without it), if
    /// the file is one: "Music   " eight bytes in, and the song where UADE's check (`AMBK_Check`)
    /// looks for it.
    private static func base(_ data: [UInt8]) -> Int? {
        func word(_ at: Int) -> Int { at >= 0 && at + 2 <= data.count ? Int(data[at]) << 8 | Int(data[at + 1]) : -1 }
        guard data.count >= 0x40 else { return nil }
        let base: Int
        if data[0] == 0x41, data[1] == 0x6D, data[2] == 0x42, data[3] == 0x6B { // "AmBk"
            guard data[8] == 0x80 else { return nil }
            base = 4
        } else {
            guard data[0] == 0xC0 else { return nil }
            base = 0
        }
        let music: [UInt8] = [0x4D, 0x75, 0x73, 0x69, 0x63, 0x20, 0x20, 0x20]
        guard (0 ..< 8).allSatisfy({ data[base + 8 + $0] == music[$0] }) else { return nil }
        let songs = base + 0x14 + long(data, base + 0x14)
        guard word(songs) == 6 else { return nil }
        let end = songs + 2 + Int(Int16(truncatingIfNeeded: word(songs + 4)))
        guard word(end - 2) == 0xFFFE || word(end - 2) == 0 else { return nil }
        return base
    }

    private static func long(_ data: [UInt8], _ at: Int) -> Int {
        guard at >= 0, at + 4 <= data.count else { return 0 }
        return Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3])
    }

    static func isOne(_ data: [UInt8]) -> Bool { base(data) != nil }

    /// The ProTracker module the bank is made into. (`AMBK_InitPlayer`)
    static func module(_ data: [UInt8]) throws(TuneError) -> [UInt8] {
        guard let base = base(data) else { throw .malformed("not an AMOS music bank") }
        func word(_ at: Int) throws(TuneError) -> Int {
            guard at >= 0, at + 2 <= data.count else { throw .malformed("an AMOS music bank cut short") }
            return Int(data[at]) << 8 | Int(data[at + 1])
        }
        // The song, its lists of patterns (where they are from the song, as the 68000 adds a word to
        // an address: with its sign), and the patterns after the last list: as many as the highest number in the fourth voice's list.
        let song = base + 0x14 + long(data, base + 0x14) + 2
        var at = song + Int(Int16(truncatingIfNeeded: try word(song + 6)))
        var highest = 0
        while true {
            let number = try word(at)
            at += 2
            if number & 0x8000 != 0 { break }
            highest = max(highest, number)
        }
        // (A module converted from Game Music Creator's has a word more before the patterns.)
        if try word(at) == 0 { at += 2 }
        let patterns = at
        guard highest < ProTrackerModule.mostPatterns else { throw .unsupported("an AMOS music bank of more than a hundred patterns") }

        var module = [UInt8](repeating: 0, count: 1084 + (highest + 1) * 1024)
        func put16(_ at: Int, _ value: Int) {
            module[at] = UInt8(truncatingIfNeeded: value >> 8)
            module[at + 1] = UInt8(truncatingIfNeeded: value)
        }
        for i in 0 ..< 31 { put16(42 + 6 + i * 30, 1) }

        // The samples' headers, from the instruments' (32 bytes each, after their count, from 0x20):
        // a length, then a loop of more than one word if there is one; and the volume, and the name.
        let instruments = try word(base + 0x20)
        guard instruments <= 31 else { throw .unsupported("an AMOS music bank of more than 31 instruments") }
        var sampleBytes = 0
        for i in 0 ..< instruments {
            let from = base + 0x22 + i * 32, to = 20 + i * 30
            put16(to + 24, try word(from + 12))
            let length = try word(from + 14)
            if length != 0 {
                put16(to + 22, length)
                let loop = try word(from + 10)
                if loop > 2 {
                    put16(to + 28, loop)
                    put16(to + 26, (try word(from + 8)) * 2)
                }
            } else {
                // (A bank that says no length in its second place has it in the first, and its loop's
                // start as the distance of the loop from the sample, as UADE takes it.)
                let length = try word(from + 8)
                put16(to + 22, length)
                let loop = try word(from + 10)
                if loop > 2 {
                    put16(to + 28, loop)
                    put16(to + 26, long(data, from + 4) - long(data, from))
                }
            }
            sampleBytes += (Int(module[to + 22]) << 8 | Int(module[to + 23])) * 2
            for k in 0 ..< 16 { module[to + k] = data[from + 16 + k] }
        }

        // The title, and the order: the first voice's list, to its end.
        for k in 0 ..< 16 { module[k] = data[song + 12 + k] }
        var order = song + Int(Int16(truncatingIfNeeded: try word(song)))
        var length = 0
        while true {
            let number = try word(order)
            order += 2
            if number & 0x8000 != 0 { break }
            guard length < 128 else { throw .unsupported("an AMOS music bank with too long a song") }
            module[952 + length] = UInt8(truncatingIfNeeded: number)
            length += 1
        }
        module[950] = UInt8(length)
        module[1080 ..< 1084] = [0x4D, 0x2E, 0x4B, 0x2E] // "M.K."

        // The patterns, each voice's from where the list of them says.
        for pattern in 0 ... highest {
            for voice in 0 ..< 4 {
                let track = patterns + Int(Int16(truncatingIfNeeded: try word(patterns + 2 + (pattern * 4 + voice) * 2)))
                convert(data, from: track, into: &module, at: 1084 + pattern * 1024 + voice * 4)
            }
        }

        // The samples, after the instruments' headers, one after another.
        let samples = base + 0x22 + instruments * 32
        if samples < data.count { module += data[samples ..< min(data.count, samples + sampleBytes)] }
        return module
    }

    /// One voice's pattern, into its column of a ProTracker pattern, as UADE's `.ConvertPatt` does it.
    ///
    /// It converts all 64 lines, though a pattern that jumps elsewhere partway is heard only to its
    /// jump: past it are the words of the next voice's pattern, or the end of the bank. Where they end,
    /// so does the conversion, and the lines left are empty. (UADE reads on into what is after the bank,
    /// and comes to grief there: the banks of Tyran, whose first pattern is 22 lines and a jump.)
    private static func convert(_ data: [UInt8], from start: Int, into module: inout [UInt8], at first: Int) {
        var from = start
        func next() -> Int? {
            guard from >= 0, from + 2 <= data.count else { return nil }
            defer { from += 2 }
            return Int(data[from]) << 8 | Int(data[from + 1])
        }
        func peek() -> Int? {
            guard from >= 0, from + 2 <= data.count else { return nil }
            return Int(data[from]) << 8 | Int(data[from + 1])
        }
        var wait = 0 // lines still to wait (`d3`)
        var going = 0 // the command that goes on, and its value (`d4`)
        var line = 0
        lines: while line < 64 {
            let cell = first + line * 16
            func word(_ at: Int) -> Int { Int(module[cell + at]) << 8 | Int(module[cell + at + 1]) }
            func setWord(_ at: Int, _ value: Int) {
                module[cell + at] = UInt8(truncatingIfNeeded: value >> 8)
                module[cell + at + 1] = UInt8(truncatingIfNeeded: value)
            }
            for k in 0 ..< 4 { module[cell + k] = 0 }
            wait = Int(Int8(truncatingIfNeeded: wait - 1))
            if wait > 0 {
                setWord(2, word(2) | going)
                line += 1
                continue
            }
            var command = going // what this line's command is (`d5`)
            // Words, until one that says how long to wait.
            while true {
                guard let value = next() else { return }
                if value & 0x8000 == 0 {
                    if value & 0x7F00 == 0x7F00 {
                        // An old note: this, how long to wait after it, and then its sample's number
                        // (in the top six bits) and its period.
                        guard let following = peek() else { return }
                        var sample = following >> 10 + Int(module[cell + 2] >> 4) + Int(module[cell] & 0x10)
                        sample &= 0xFF
                        module[cell] = UInt8(sample & 0x10)
                        module[cell + 1] = 0
                        module[cell + 2] = module[cell + 2] & 0x0F | UInt8(truncatingIfNeeded: sample << 4)
                        setWord(0, word(0) | following & 0x3FF)
                        from += 2
                        wait = value & 0x7F
                        setWord(2, word(2) | going)
                        line += 1
                        continue lines
                    }
                    // A note: its period, on this line.
                    if value & 0x3000 == 0x3000 { setWord(0, word(0) | value & 0xFFF) }
                    continue
                }
                let parameter = value & 0xFF
                switch value & 0xFF00 {
                case 0x9000:
                    // Wait so many lines: this one has this line's command.
                    wait = parameter
                    setWord(2, word(2) & 0xF000 | command)
                    line += 1
                    continue lines
                case 0x8000:
                    // The end of the pattern, as a break on the line before. (UADE writes it there for
                    // a pattern that ends on its first line too, into what is before the pattern.)
                    if line > 0 {
                        module[cell - 16 + 3] = 0
                        module[cell - 16 + 2] = module[cell - 16 + 2] & 0xF0 | 0x0D
                    }
                    return
                case 0x8400:
                    // The command that goes on stops.
                    going = 0
                case 0x8900:
                    // The sample to play.
                    let sample = (parameter + 1) & 0xFF
                    module[cell + 2] |= UInt8(truncatingIfNeeded: sample << 4)
                    module[cell] |= UInt8(sample & 0x10)
                case 0x9100, 0x8300, 0x8800:
                    // A jump, the volume, or the tempo (a hundred over AMOS's): on this line only. (A
                    // tempo of nought is passed over.)
                    if value & 0xFF00 == 0x8800, parameter == 0 { continue }
                    let letter: UInt8 = value & 0xFF00 == 0x9100 ? 0x0B : value & 0xFF00 == 0x8300 ? 0x0C : 0x0F
                    module[cell + 3] = UInt8(truncatingIfNeeded: value & 0xFF00 == 0x8800 ? 100 / parameter : parameter)
                    module[cell + 2] = module[cell + 2] & 0xF0 | letter
                    command = word(2)
                case 0x8A00, 0x8B00, 0x8C00, 0x8D00, 0x8E00, 0x8F00:
                    // An arpeggio, a slide to the note, vibrato, a volume slide, a slide up or down:
                    // on this line and the next ones, until another or a stop.
                    let letters: [UInt8] = [0x0, 0x3, 0x4, 0xA, 0x1, 0x2]
                    module[cell + 3] = UInt8(parameter)
                    module[cell + 2] = module[cell + 2] & 0xF0 | letters[(value >> 8) - 0x8A]
                    command = word(2)
                    going = command & 0xFFF
                default:
                    break
                }
            }
        }
    }
}
