// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of zlib's DEFLATE and of the J2B files of Jazz Jackrabbit 2, which Impulse Tracker's
// replayer plays as OpenMPT plays them. The thorough checks are made outside the package: the
// unpacking byte for byte against the system's zlib, and every channel's pitch and volume on every
// tick of each file to hand against libopenmpt.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func text(_ letters: String, _ length: Int) -> [UInt8] { Array(Array(letters.utf8).prefix(length)) + [UInt8](repeating: 0, count: max(0, length - letters.utf8.count)) }

/// A part of a RIFF file, made even.
private func chunk(_ letters: String, _ body: [UInt8], even: Bool = true) -> [UInt8] {
    Array(letters.utf8) + long(body.count) + body + (even && body.count % 2 != 0 ? [0] : [])
}

/// Bytes as a zlib stream of stored blocks.
private func stored(_ data: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [0x78, 0x01]
    var at = 0
    repeat {
        let length = min(65535, data.count - at)
        out += [at + length == data.count ? 1 : 0] + word(length) + word(length ^ 0xFFFF) + data[at ..< at + length]
        at += length
    } while at < data.count
    let adler = Inflate.adler32(data)
    return out + [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
}

/// A J2B file's header around a zlib stream.
private func muse(_ riff: [UInt8], packed: [UInt8]? = nil, old: Bool = false) -> [UInt8] {
    let packed = packed ?? stored(riff)
    return Array("MUSE".utf8) + long(old ? 0xBEBA_ADDE : 0xAFBE_ADDE) + long(packed.count + 24) + long(Int(Inflate.crc32(packed, from: 0, to: packed.count)))
        + long(packed.count) + long(riff.count) + packed
}

/// One channel's part of a row: a note (61 is middle C, 128 lets the key go), an instrument, a
/// volume of 127, and a command of the file's numbers (0 arpeggio, 4 vibrato, 10 slide of volume,
/// 14 ProTracker's Exy, 18 FastTracker's Kxx) with its value.
private struct Cell {
    var channel = 0
    var note: UInt8 = 0, instrument: UInt8 = 0
    var volume: UInt8?
    var command: (UInt8, UInt8)?

    var bytes: [UInt8] {
        var what = UInt8(channel)
        var rest: [UInt8] = []
        if let command {
            what |= 0x80
            rest += [command.1, command.0]
        }
        if note != 0 || instrument != 0 {
            what |= 0x40
            rest += [instrument, note]
        }
        if let volume {
            what |= 0x20
            rest.append(volume)
        }
        return [what] + rest
    }
}

/// A RIFF "AM  " file: one pattern of 64 rows of these cells (by row), played once; one instrument of
/// a square wave of 32 frames that goes round, at 8,363 Hz for middle C.
private func am(_ rows: [Int: [Cell]], channels: Int = 2, amigaSlides: Bool = true, speed: UInt8 = 6) -> [UInt8] {
    var main = text("a square wave", 64) + [amigaSlides ? 1 : 0, UInt8(channels), speed, 125] + word(0) + word(0) + [128]
    main += [UInt8](repeating: 64, count: channels)
    var pattern: [UInt8] = [63]
    for row in 0 ..< 64 {
        for cell in rows[row] ?? [] { pattern += cell.bytes }
        pattern.append(0)
    }
    let sound: [UInt8] = (0 ..< 32).map { $0 < 16 ? 0x7F : 0x81 }
    var sampleHeader = long(56) + text("square", 32) + word(16384) + word(32767) + word(0x80 | 0x08) + word(0)
    sampleHeader += long(32) + long(0) + long(32) + long(8363)
    let sample = chunk("RIFF", Array("AS  ".utf8) + chunk("SAMP", sampleHeader + sound))
    var instrument = long(322) + [0, 0] + text("square", 32) + [UInt8](repeating: 0, count: 128) + [0] + word(0) + word(0) + word(0)
    instrument += [UInt8](repeating: 0, count: 7)
    for _ in 0 ..< 3 { instrument += word(0) + [0xFF, 0, 0, 0] + [UInt8](repeating: 0, count: 40) + word(0) }
    instrument += word(1)
    let body = chunk("INIT", main) + chunk("ORDR", [0, 0]) + chunk("PATT", [0] + long(pattern.count) + pattern)
        + chunk("RIFF", Array("AI  ".utf8) + chunk("INST", instrument + sample))
    return Array("RIFF".utf8) + long(body.count + 4) + Array("AM  ".utf8) + body
}

private func load(_ file: [UInt8]) throws -> ITRenderer {
    try #require(try TuneLoader.load(file, format: .j2b) as? ITRenderer)
}

/// What a channel's voice is at on each of so many ticks: samples a second, and its volume of 64.
private func ticks(_ file: [UInt8], _ count: Int, channel: Int = 0) throws -> [(rate: Int, volume: Int)] {
    let player = IT2Player(try load(file).module, forSound: true)
    return (0 ..< count).map { _ in
        player.Update()
        defer { _ = player.mixer.mixTick() }
        guard let voice = player.hChn[channel].SlaveChnPtr, voice.pointee.Flags & SF_CHAN_ON != 0, voice.pointee.Flags & SF_NOTE_STOP == 0 else { return (0, 0) }
        return (Int(voice.pointee.Frequency), Int(voice.pointee.Vol))
    }
}

@Test func inflateUnpacksEveryKindOfBlock() throws {
    // Stored, in blocks of 65,535 bytes and less.
    let bytes = (0 ..< 70000).map { UInt8(truncatingIfNeeded: $0 * 7 + $0 / 13) }
    #expect(try Inflate.zlib(stored(bytes), from: 0, to: stored(bytes).count, size: bytes.count) == bytes)
    // In the codes the format fixes, and in codes of the block's own (both made by zlib).
    let fixed: [UInt8] = [0x78, 0x01, 0xF3, 0x4A, 0xAC, 0xAA, 0x52, 0xF0, 0x4A, 0x4C, 0xCE, 0x2E, 0x4A, 0x4C, 0x4A, 0xCA, 0x2C, 0x51, 0x30, 0xD2,
                          0x01, 0xF2, 0x08, 0x0B, 0x29, 0x02, 0x00, 0x1F, 0xF0, 0x12, 0xB4]
    #expect(try Inflate.zlib(fixed, from: 0, to: fixed.count, size: 56) == Array("Jazz Jackrabbit 2, Jazz Jackrabbit 2, Jazz Jackrabbit 2!".utf8))
    let own: [UInt8] = [
        0x78, 0xDA, 0xE5, 0x8C, 0xC7, 0x01, 0x80, 0x20, 0x10, 0x04, 0x5B, 0xD9, 0x0A, 0xA8, 0xC5, 0x87, 0x0D, 0x80, 0x92, 0x0C, 0x9C, 0x64, 0xA1, 0x7A,
        0xAF, 0x0F, 0xDF, 0x13, 0x56, 0xA7, 0x11, 0xAB, 0xDF, 0x4E, 0xA8, 0x44, 0x3D, 0xC0, 0xD0, 0x8B, 0xA3, 0xDE, 0x4F, 0x06, 0x35, 0x9D, 0x50, 0x18,
        0x5F, 0x72, 0x0E, 0xEC, 0x64, 0x05, 0x16, 0xC9, 0xDE, 0x3D, 0xA0, 0x58, 0xEA, 0xBE, 0x38, 0x18, 0xDF, 0x34, 0xA3, 0xA9, 0x03, 0x2E, 0x1F, 0x2B,
        0x25, 0x6E, 0x6D, 0x16, 0x58, 0x7F, 0x7F, 0xFD, 0x00, 0x5B, 0xE5, 0x7B, 0x79,
    ]
    let sentence = Array("The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. ".utf8)
    #expect(try Inflate.zlib(own, from: 0, to: own.count, size: 344) == sentence + sentence + sentence + sentence)
    // A stream that is damaged, or cut short, or says it makes more than it does, is refused.
    var damaged = own
    damaged[20] ^= 0x10
    #expect(throws: TuneError.self) { try Inflate.zlib(damaged, from: 0, to: damaged.count, size: 344) }
    #expect(throws: TuneError.self) { try Inflate.zlib(own, from: 0, to: own.count - 3, size: 344) }
    #expect(throws: TuneError.self) { try Inflate.zlib(own, from: 0, to: own.count, size: 345) }
    // The two checksums.
    #expect(Inflate.crc32(Array("123456789".utf8), from: 0, to: 9) == 0xCBF4_3926)
    #expect(Inflate.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
}

@Test func j2bNoteSoundsAtItsPitch() throws {
    #expect(TuneFormat(fileExtension: "J2B") == .j2b)
    let file = muse(am([0: [Cell(note: 61, instrument: 1)]]))
    let renderer = try load(file)
    #expect(renderer.info.format == "J2B" && renderer.info.title == "a square wave" && renderer.info.shortfalls.isEmpty)
    // Middle C plays the sample at its own rate, and the octave above at twice.
    #expect(try ticks(file, 1)[0].rate == 8363)
    #expect(try ticks(muse(am([0: [Cell(note: 73, instrument: 1)]])), 1)[0].rate == 16726)
    // The volume column is of 127.
    #expect(try ticks(muse(am([0: [Cell(note: 61, instrument: 1, volume: 127)]])), 1)[0].volume == 64)
    #expect(try ticks(muse(am([0: [Cell(note: 61, instrument: 1, volume: 63)]])), 1)[0].volume == 31)
    // The RIFF file unpacked, and one packed in zlib's own codes, play the same.
    #expect(try ticks(am([0: [Cell(note: 61, instrument: 1)]]), 1)[0].rate == 8363)
}

@Test func j2bRefusesWhatIsDamaged() throws {
    let riff = am([0: [Cell(note: 61, instrument: 1)]])
    var file = muse(riff)
    file[file.count - 10] ^= 1
    // (The checksum of what is packed is wrong.)
    #expect(throws: TuneError.self) { try load(file) }
    // Cut short.
    #expect(throws: TuneError.self) { try load(Array(muse(riff).dropLast(5))) }
    // Said to unpack to more than it does.
    var longer = muse(riff)
    longer[20] &+= 1
    #expect(throws: TuneError.self) { try load(longer) }
    // And a RIFF file without its song.
    #expect(throws: TuneError.self) { try load(Array("RIFF".utf8) + long(200) + Array("AM  ".utf8) + chunk("ORDR", [0, 0])) }
}

@Test func j2bVibratoStartsAgainWithANote() throws {
    // A vibrato with "old effects", after a note that came on an earlier row, starts unbent on its
    // first tick, where Impulse Tracker would bend it by where the last vibrato left off.
    let file = muse(am([0: [Cell(note: 61, instrument: 1, command: (4, 0x88))], 1: [Cell(command: (4, 0))], 4: [Cell(note: 61, instrument: 1)],
                        8: [Cell(command: (4, 0x88))]]))
    let rates = try ticks(file, 8 * 6 + 2).map(\.rate)
    #expect(rates[6 + 2] != 8363)
    #expect(rates[8 * 6] == 8363 && rates[8 * 6 + 1] != 8363)
}

@Test func j2bSaysWhatItLeavesOut() throws {
    let file = muse(am([0: [Cell(note: 61, instrument: 1)], 4: [Cell(command: (18, 0x02))]]))
    let shortfalls = try load(file).info.shortfalls
    #expect(shortfalls.count == 1 && shortfalls[0].contains("FastTracker's Kxx"))
}

@Test func j2bOfTheOlderKindPlays() throws {
    // "AMFF": its song in "MAIN", and each instrument with its samples' headers and sound in one part.
    let main = text("older", 64) + [1, 1, 6, 125] + word(0) + word(0) + [128] + [32]
    let pattern: [UInt8] = [63, 0x40, 1, 61] + [UInt8](repeating: 0, count: 64)
    let sound: [UInt8] = (0 ..< 32).map { $0 < 16 ? 0x7F : 0x81 }
    var instrument: [UInt8] = [0, 0] + text("square", 28) + [1] + [UInt8](repeating: 0, count: 120) + [0] + word(0) + word(0) + word(0)
    instrument += [UInt8](repeating: 0, count: 65) + word(0)
    var sample = Array("SAMP".utf8) + long(64 + 32) + text("square", 28) + [32, 64] + word(0x80 | 0x08) + long(32) + long(0) + long(32) + long(16000)
    sample += long(0) + long(0)
    let body = chunk("MAIN", main, even: false) + chunk("ORDR", [0, 0], even: false) + chunk("PATT", [0] + long(pattern.count) + pattern, even: false)
        + chunk("INST", instrument + sample + sound, even: false)
    let riff = Array("RIFF".utf8) + long(body.count + 4) + Array("AMFF".utf8) + body
    #expect(try ticks(muse(riff, old: true), 1)[0].rate == 16000)
}
