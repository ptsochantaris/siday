// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The reading of the header follows ASAP, Copyright (C) 2010-2026 Piotr Fusik, used under the GNU
// General Public License, version 2 or later (see THIRD-PARTY.md), so that a file is understood
// here as it is there.

import SidayFoundation

/// A SAP file: a piece of music for the 8-bit Ataris, the 400, the 800 and the XL and XE machines
/// that followed them, as the machine played it. Like an SNDH file it is not a recording but the
/// program that played it, cut out of the game or demo it came from: 6502 code and its data, in
/// the blocks an Atari DOS file is made of, after a header of lines of text saying where to start
/// it and how to call it.
struct SAPFile {
    /// How the tune's code is called. B: its INIT is called once with the song's number, and then
    /// its PLAYER as often as the header says. C: music made in Chaos Music Composer, whose player is
    /// started and called at places of its own. D: its INIT is run as the machine's own
    /// program, never to return, and its PLAYER, if there is one, is called as the machine's
    /// vertical blank interrupt would call it. S: the same, with no player, and a counter the
    /// tune's code waits on counted down in its place: SoftSynth's music.
    enum Kind { case b, c, d, s }

    var kind = Kind.b
    var title = ""
    var author = ""
    var date = ""
    var songs = 1
    /// The song to play first, counted from nought.
    var defaultSong = 0
    /// Each song's length in milliseconds, where the file gives it; nil where it does not.
    var durations: [Int?] = []
    /// For each song, whether it goes on from the start again where its length ends.
    var loops: [Bool] = []
    var ntsc = false
    /// True for a tune for two POKEYs, one on each side, as the stereo upgrades had them.
    var stereo = false
    /// How many of the screen's lines pass between one call of the player and the next.
    var fastplay = 312
    var music = -1
    var initAddress = -1
    var player = -1
    /// Where a tune that plays samples on a COVOX, four eight-bit DACs, writes them.
    var covox = -1
    /// Where the blocks of code and data begin.
    var headerLength = 0
    private let data: [UInt8]

    static let mostSongs = 32

    init(_ data: [UInt8]) throws {
        self.data = data
        let file = ByteReader(data)
        guard data.count >= 30, data.starts(with: [0x53, 0x41, 0x50, 0x0D, 0x0A]) else { throw TuneError.malformed("not a SAP file") }
        var fastplay = -1
        var type: UInt8 = 0
        var index = 5
        durations = []
        loops = []
        func invalid() -> TuneError { .malformed("the header is damaged") }
        while file[index] != 0xFF {
            // The tag, and what follows it, if anything, to the end of the line.
            let lineStart = index
            while file[index] > 0x20 {
                index += 1
                if index >= data.count { throw invalid() }
            }
            let tag = String(decoding: data[lineStart ..< index], as: UTF8.self)
            var argStart = -1, argEnd = -1
            while true {
                let c = file[index]
                if c > 0x20 {
                    guard c <= 0x7C, c != 0x60, c != 0x7B else { throw TuneError.malformed("the header has a character it may not have") }
                    if argStart < 0 { argStart = index }
                    argEnd = -1
                } else {
                    if argEnd < 0 { argEnd = index }
                    if c == 0x0A { break }
                }
                index += 1
                if index >= data.count { throw invalid() }
            }
            index += 1
            if index + 6 >= data.count { throw invalid() }

            func text() -> String {
                let length = argEnd - argStart - 2
                guard argStart >= 0, length >= 0, file[argStart] == 0x22, file[argEnd - 1] == 0x22 else { return "" }
                return TextEncoding.latin1.decode(Self.tidied(Array(data[argStart + 1 ..< argStart + 1 + length]))[...]) ?? ""
            }
            func decimal(_ least: Int, _ most: Int) throws -> Int {
                guard argStart >= 0 else { throw invalid() }
                var value = 0
                for i in argStart ..< argEnd {
                    let c = file[i]
                    guard c >= 0x30, c <= 0x39 else { throw invalid() }
                    value = value * 10 + Int(c - 0x30)
                    guard value <= most else { throw invalid() }
                }
                guard value >= least else { throw invalid() }
                return value
            }
            func hex() throws -> Int {
                guard argStart >= 0 else { throw invalid() }
                var value = 0
                for i in argStart ..< argEnd {
                    let c = file[i]
                    guard value <= 0xFFF else { throw invalid() }
                    value <<= 4
                    switch c {
                    case 0x30 ... 0x39: value += Int(c - 0x30)
                    case 0x41 ... 0x46: value += Int(c - 0x41 + 10)
                    case 0x61 ... 0x66: value += Int(c - 0x61 + 10)
                    default: throw invalid()
                    }
                }
                return value
            }

            switch tag {
            case "AUTHOR": author = text()
            case "NAME": title = text()
            case "DATE": date = text()
            case "TIME":
                guard durations.count < Self.mostSongs, argStart >= 0 else { throw invalid() }
                var end = argEnd
                var loop = false
                if end - argStart > 5, data[end - 5 ..< end].elementsEqual([0x20, 0x4C, 0x4F, 0x4F, 0x50]) { // " LOOP"
                    loop = true
                    end -= 5
                }
                guard let length = Self.duration(data[argStart ..< end]) else { throw TuneError.malformed("a song's length is not a length") }
                durations.append(length)
                loops.append(loop)
            case "SONGS": songs = try decimal(1, Self.mostSongs)
            case "DEFSONG": defaultSong = try decimal(0, Self.mostSongs - 1)
            case "TYPE":
                guard argStart >= 0 else { throw invalid() }
                type = file[argStart]
            case "FASTPLAY": fastplay = try decimal(1, 32767)
            case "MUSIC": music = try hex()
            case "INIT": initAddress = try hex()
            case "PLAYER": player = try hex()
            case "COVOX":
                covox = try hex()
                guard covox == 0xD600 else { throw TuneError.unsupported("a COVOX anywhere but at D600") }
                stereo = true
            case "STEREO": stereo = true
            case "NTSC": ntsc = true
            default: break
            }
        }
        guard defaultSong < songs else { throw TuneError.malformed("the song to play first is not among its songs") }
        headerLength = index
        switch type {
        case 0x42: // B
            guard player >= 0, initAddress >= 0 else { throw TuneError.malformed("it does not say where its code is") }
            kind = .b
        case 0x43: // C
            guard player >= 0, music >= 0 else { throw TuneError.malformed("it does not say where its code is") }
            kind = .c
        case 0x44: // D
            guard initAddress >= 0 else { throw TuneError.malformed("it does not say where its code is") }
            kind = .d
        case 0x53: // S
            guard initAddress >= 0 else { throw TuneError.malformed("it does not say where its code is") }
            kind = .s
            if fastplay < 0 { fastplay = 78 }
        default:
            throw TuneError.unsupported("a kind of SAP file that is not played")
        }
        self.fastplay = fastplay >= 0 ? fastplay : ntsc ? 262 : 312
        guard file[index + 1] == 0xFF else { throw invalid() }
        while durations.count < songs {
            durations.append(nil)
            loops.append(false)
        }
    }

    /// A name or date with ASMA's marks of what is not known made plain: "<?>" alone, nothing
    /// known, is nothing; "<?> (Nickname)", a musician whose own name is not known, is the nickname;
    /// and a name followed by "<?>", which is not certain, is followed by a question mark.
    static func tidied(_ text: [UInt8]) -> [UInt8] {
        let unknown: [UInt8] = [0x3C, 0x3F, 0x3E] // <?>
        if text == unknown { return [] }
        var text = text
        if text.starts(with: unknown + [0x20, 0x28]), text.last == 0x29, text.count(where: { $0 == 0x28 }) == 1 {
            text = Array(text[5 ..< text.count - 1])
        }
        var out: [UInt8] = []
        var i = 0
        while i < text.count {
            if text[i...].starts(with: unknown) {
                if out.last == 0x20 { out.removeLast() }
                out.append(0x3F)
                i += 3
            } else {
                out.append(text[i])
                i += 1
            }
        }
        return out
    }

    /// A length as the header writes it, `mm:ss.xxx`, in milliseconds.
    private static func duration(_ text: ArraySlice<UInt8>) -> Int? {
        let s = Array(text)
        var position = 0
        func digit(_ most: Int) -> Int? {
            guard position < s.count else { return nil }
            let d = Int(s[position]) - 0x30
            position += 1
            return d >= 0 && d <= most ? d : nil
        }
        guard var result = digit(9) else { return nil }
        if position < s.count {
            let d = Int(s[position]) - 0x30
            if d >= 0, d <= 9 {
                position += 1
                result = result * 10 + d
            }
            if position < s.count, s[position] == 0x3A {
                position += 1
                guard let tens = digit(5), let units = digit(9) else { return nil }
                result = result * 60 + tens * 10 + units
            }
        }
        result *= 1000
        if position >= s.count { return result }
        guard s[position] == 0x2E else { return nil }
        position += 1
        for scale in [100, 10, 1] {
            guard let d = digit(9) else { return nil }
            result += d * scale
            if position >= s.count { return result }
        }
        return result
    }

    /// Copies the file's blocks of code and data into the machine's memory.
    func load(into memory: UnsafeMutablePointer<UInt8>) throws {
        let file = ByteReader(data)
        var index = headerLength + 2
        while index + 5 <= data.count {
            let start = file.u16le(index)
            let length = file.u16le(index + 2) + 1 - start
            guard length > 0, index + 4 + length <= data.count else { throw TuneError.malformed("a block of its code is damaged") }
            index += 4
            data.withUnsafeBufferPointer { source in
                for i in 0 ..< length { memory[(start + i) & 0xFFFF] = source[index + i] }
            }
            index += length
            if index == data.count { return }
            if index + 7 <= data.count, data[index] == 0xFF, data[index + 1] == 0xFF { index += 2 }
        }
        throw TuneError.malformed("a block of its code is damaged")
    }
}
