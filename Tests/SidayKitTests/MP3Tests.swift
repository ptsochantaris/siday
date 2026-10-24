// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayCodecs
@testable import SidayFoundation
import Testing

// Fast checks of the port of minimp3. The thorough checks are made outside the package, against the C
// built from OpenMPT's copy of minimp3.h with MINIMP3_NO_SIMD and -ffp-contract=off (and against
// minimp3_ex.h's mp3dec_load_buf for MP3File): every MP3 and MP2 file of the collection, the MP3
// streams inside its MO3 files, files made by LAME and ffmpeg in every mode and rate, streams of
// random frames of every layer, version, rate and mode, and thousands of damaged files, all decoded to
// the same bits as the C decodes them to. Here a few small files are held to the C's numbers for them.

/// FNV-1a over the samples' bits, as the scratch tool that took the C's numbers worked it out.
private func fnv(_ values: some Sequence<UInt32>) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for value in values { hash = (hash ^ UInt64(value)) &* 0x100_0000_01B3 }
    return hash
}

/// A stream decoded frame by frame from its first byte, as the C's mp3dec_decode_frame decodes it.
private func decodeFrames(_ bytes: [UInt8]) -> (frames: Int, samples: Int, floats: [Float], shorts: [Int16]) {
    let decoder = MP3Decoder(), shortDecoder = MP3Decoder()
    let pcm = UnsafeMutablePointer<Float>.allocate(capacity: 1152 * 2)
    let pcm16 = UnsafeMutablePointer<Int16>.allocate(capacity: 1152 * 2)
    defer { pcm.deallocate(); pcm16.deallocate() }
    var floats: [Float] = [], shorts: [Int16] = []
    var position = 0, frames = 0, samples = 0
    var steps = 0
    while steps < 100_000 {
        steps += 1
        var info = MP3FrameInfo(), info16 = MP3FrameInfo()
        let count = decoder.decodeFrame(bytes, at: position, into: pcm, info: &info)
        let count16 = shortDecoder.decodeFrame(bytes, at: position, into: pcm16, info: &info16)
        #expect(count == count16 && info.frameBytes == info16.frameBytes)
        if count > 0 {
            floats += UnsafeBufferPointer(start: pcm, count: count * info.channels)
            shorts += UnsafeBufferPointer(start: pcm16, count: count * info.channels)
            frames += 1
            samples += count
        }
        if info.frameBytes == 0 { break }
        position += info.frameBytes
    }
    return (frames, samples, floats, shorts)
}

/// A whole file through MP3File, its channels interleaved again.
private func decodeFile(_ file: MP3File) -> [Float] {
    var samples: [Float] = []
    var steps = 0
    while steps < 100_000 {
        steps += 1
        let count = file.next()
        if count == 0 { break }
        for i in 0 ..< count {
            for channel in 0 ..< file.channels { samples.append(file.samples(of: channel)[i]) }
        }
    }
    return samples
}

/// What the C gives for each of the fixtures (from SCRATCH/codecs/mp3/tools/fixture_numbers.py).
private struct Expected: Sendable, CustomTestStringConvertible {
    let name: String
    let bytes: @Sendable () -> [UInt8]
    let frames: Int, samples: Int, floatHash: UInt64, int16Hash: UInt64
    let channels: Int, hz: Int, length: Int, fileHash: UInt64
    var testDescription: String { name }
}

/// `tone440` with 100 bytes of junk between two of its frames.
private func withJunk() -> [UInt8] {
    let bytes = MP3Fixtures.tone440
    return Array(bytes[..<1072]) + (0 ..< 100).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) } + Array(bytes[1072...])
}

/// `tone440` without its ID3v1 tag and 50 bytes of its last frame.
private func cutShort() -> [UInt8] {
    Array(MP3Fixtures.tone440.dropLast(50 + 128))
}

private let expectations: [Expected] = [
    Expected(name: "tone440", bytes: { MP3Fixtures.tone440 }, frames: 21, samples: 12096, floatHash: 0xE597_9ECA_B347_3059, int16Hash: 0x14FC_7E5F_ABF9_A0EE,
             channels: 1, hz: 22050, length: 12672, fileHash: 0x827E_E3B7_1258_B061),
    Expected(name: "junk between frames", bytes: withJunk, frames: 9, samples: 5184, floatHash: 0xC62F_DFE5_448B_2B89, int16Hash: 0x7334_F701_AEFA_95DE,
             channels: 1, hz: 22050, length: 5760, fileHash: 0x0374_7658_0330_9011),
    Expected(name: "last frame cut short", bytes: cutShort, frames: 21, samples: 12096, floatHash: 0xE597_9ECA_B347_3059, int16Hash: 0x14FC_7E5F_ABF9_A0EE,
             channels: 1, hz: 22050, length: 12096, fileHash: 0xE597_9ECA_B347_3059),
    Expected(name: "gapless", bytes: { MP3Fixtures.gapless }, frames: 12, samples: 13824, floatHash: 0xBF9A_824F_55CF_EBCC, int16Hash: 0x0C2B_6582_02BC_F93E,
             channels: 1, hz: 44100, length: 11025, fileHash: 0xA5ED_A82C_8D70_D76A),
    Expected(name: "MPEG-2.5", bytes: { MP3Fixtures.mpeg25 }, frames: 9, samples: 5184, floatHash: 0x3EBB_4517_AAFC_E0F6, int16Hash: 0xFCF1_4393_B0E1_F4BF,
             channels: 1, hz: 8000, length: 3200, fileHash: 0x096E_03E4_4C1F_B8EC),
    Expected(name: "free format", bytes: { MP3Fixtures.freeFormat }, frames: 22, samples: 12672, floatHash: 0x8209_2CC6_9415_9AFE, int16Hash: 0xB60B_48E3_DC66_D570,
             channels: 1, hz: 22050, length: 12672, fileHash: 0x8209_2CC6_9415_9AFE),
    Expected(name: "layer II", bytes: { MP3Fixtures.layer2 }, frames: 9, samples: 10368, floatHash: 0x2265_53A5_01A5_CF9A, int16Hash: 0x9D3B_7DC4_1254_794D,
             channels: 2, hz: 32000, length: 10368, fileHash: 0x2265_53A5_01A5_CF9A),
    Expected(name: "layer I", bytes: { MP3Fixtures.layer1 }, frames: 1, samples: 384, floatHash: 0x0410_28B3_02AF_0A01, int16Hash: 0xCAE6_74D2_8CE2_C82F,
             channels: 2, hz: 32000, length: 384, fileHash: 0x0410_28B3_02AF_0A01),
]

@Test(arguments: expectations)
private func decodesAsMinimp3Does(_ expected: Expected) throws {
    let bytes = expected.bytes()
    let decoded = decodeFrames(bytes)
    #expect(decoded.frames == expected.frames)
    #expect(decoded.samples == expected.samples)
    #expect(fnv(decoded.floats.map(\.bitPattern)) == expected.floatHash)
    #expect(fnv(decoded.shorts.map { UInt32(UInt16(bitPattern: $0)) }) == expected.int16Hash)

    let file = try MP3File(bytes)
    #expect(file.channels == expected.channels)
    #expect(file.sampleRate == expected.hz)
    #expect(file.length == expected.length)
    let samples = decodeFile(file)
    #expect(samples.count == expected.length * expected.channels)
    #expect(fnv(samples.map(\.bitPattern)) == expected.fileHash)

    // And again from the start, the same.
    file.restart()
    #expect(fnv(decodeFile(file).map(\.bitPattern)) == expected.fileHash)
}

/// How often a channel's samples cross zero going up, a second, between `from` and `to`.
private func pitch(_ samples: [Float], from: Int, to: Int, rate: Int) -> Double {
    var crossings = 0
    for i in from + 1 ..< to where samples[i - 1] < 0 && samples[i] >= 0 { crossings += 1 }
    return Double(crossings) * Double(rate) / Double(to - from)
}

private func rms(_ samples: [Float], from: Int, to: Int) -> Double {
    var sum = 0.0
    for i in from ..< to { sum += Double(samples[i]) * Double(samples[i]) }
    return (sum / Double(to - from)).squareRoot()
}

@Test func soundsAsEncoded() throws {
    // The gapless tone: exactly a quarter of a second, 440 Hz at a sixteenth of full level (0.044 RMS).
    let tone = try MP3File(MP3Fixtures.gapless)
    let samples = decodeFile(tone)
    #expect(samples.count == 11025)
    #expect(abs(pitch(samples, from: 1000, to: 10000, rate: 44100) - 440) < 6)
    #expect(abs(rms(samples, from: 1000, to: 10000) - 0.0625 / 2.0.squareRoot()) < 0.003)

    // Layer II, stereo: 1000 Hz on the left, 500 Hz on the right.
    let stereo = try MP3File(MP3Fixtures.layer2)
    var left: [Float] = [], right: [Float] = []
    while case let count = stereo.next(), count > 0 {
        left += UnsafeBufferPointer(start: stereo.samples(of: 0), count: count)
        right += UnsafeBufferPointer(start: stereo.samples(of: 1), count: count)
    }
    #expect(abs(pitch(left, from: 1500, to: 9000, rate: 32000) - 1000) < 10)
    #expect(abs(pitch(right, from: 1500, to: 9000, rate: 32000) - 500) < 10)
    #expect(abs(rms(left, from: 1500, to: 9000) - 0.0625 / 2.0.squareRoot()) < 0.003)

    // MPEG-2.5 at 8 kHz: 300 Hz.
    let low = decodeFile(try MP3File(MP3Fixtures.mpeg25))
    #expect(abs(pitch(low, from: 500, to: 3000, rate: 8000) - 300) < 8)
}

/// An ID3v2 tag of the given version and flags, with these frames (each four characters, or three for
/// version 2.2, and its contents).
private func id3v2(version: UInt8, flags: UInt8 = 0, _ frames: [(String, [UInt8])]) -> [UInt8] {
    var body: [UInt8] = []
    for (id, contents) in frames {
        body += Array(id.utf8)
        let size = contents.count
        if version == 2 {
            body += [UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]
        } else if version == 3 {
            body += [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF), 0, 0]
        } else {
            body += [UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F), UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F), 0, 0]
        }
        body += contents
    }
    body += [UInt8](repeating: 0, count: 20) // padding
    let size = body.count
    return [0x49, 0x44, 0x33, version, 0, flags, UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F), UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)] + body
}

private func utf16(_ text: String, bigEndian: Bool, bom: Bool) -> [UInt8] {
    var bytes: [UInt8] = bom ? (bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]) : []
    for unit in text.utf16 { bytes += bigEndian ? [UInt8(unit >> 8), UInt8(unit & 0xFF)] : [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
    return bytes + [0, 0]
}

@Test func readsTags() throws {
    let tone = try MP3File(MP3Fixtures.tone440)
    #expect(tone.title == "Tone")
    #expect(tone.artist == "Siday")

    // Without its ID3v2 tag, from its ID3v1 tag.
    let bare = Array(MP3Fixtures.tone440[132...])
    let fromID3v1 = try MP3File(bare)
    #expect(fromID3v1.title == "Tone")
    #expect(fromID3v1.artist == "Siday")

    let stream = Array(MP3Fixtures.gapless)
    let title = "Tōne – ünïcode 𝄞", artist = "Ärtist"
    let tags: [[UInt8]] = [
        id3v2(version: 2, [("TT2", [0] + Array("Latin-1 \u{E9}".unicodeScalars.map { UInt8($0.value) }) + [0]), ("TP1", [0, 0x41])]),
        id3v2(version: 3, [("TIT2", [1] + utf16(title, bigEndian: false, bom: true)), ("TPE1", [1] + utf16(artist, bigEndian: true, bom: true))]),
        id3v2(version: 4, [("TPE1", [3] + Array(artist.utf8)), ("TIT2", [2] + utf16(title, bigEndian: true, bom: false))]),
    ]
    let expected = [("Latin-1 \u{E9}", "A"), (title, artist), (title, artist)]
    let plain = decodeFile(try MP3File(stream))
    for (tag, names) in zip(tags, expected) {
        let file = try MP3File(tag + stream)
        #expect(file.title == names.0)
        #expect(file.artist == names.1)
        // The tag is skipped, and the sound is as without it.
        #expect(decodeFile(file) == plain)
    }
}

@Test func refusesFilesWithoutFrames() {
    #expect(throws: TuneError.self) { try MP3File([]) }
    #expect(throws: TuneError.self) { try MP3File([UInt8](repeating: 0, count: 5000)) }
    #expect(throws: TuneError.self) { try MP3File(Array(MP3Fixtures.tone440[..<132])) }
    #expect(throws: TuneError.self) { try MP3File((0 ..< 3000).map { UInt8(truncatingIfNeeded: $0 &* 7919 >> 3) }) }
}

/// The tables' Huffman trees, followed from every pattern of bits: no step leaves the table, and every
/// step reads some bits; and the scale factor bands add up to a granule's 576 lines at every rate.
@Test func tablesAreSafe() {
    let tabs = MP3Tables.huffman, index = MP3Tables.huffmanIndex
    func walk(_ base: Int, _ offset: Int, _ width: Int) -> Bool {
        for bits in 0 ..< 1 << width {
            let at = base + bits + offset
            guard at >= 0, at < tabs.count else { return false }
            let leaf = Int(tabs[at])
            if leaf < 0 {
                guard leaf & 7 != 0, walk(base, -(leaf >> 3), leaf & 7) else { return false }
            } else if leaf >> 8 > width {
                return false
            }
        }
        return true
    }
    for table in 0 ..< 32 { #expect(walk(Int(index[table]), 0, 5), "table \(table)") }
    for rate in 0 ..< 8 {
        #expect(MP3Tables.scfLong[rate * 23 ..< rate * 23 + 23].reduce(0) { $0 + Int($1) } == 576)
        #expect(MP3Tables.scfShort[rate * 40 ..< rate * 40 + 40].reduce(0) { $0 + Int($1) } == 576)
        #expect(MP3Tables.scfMixed[rate * 40 ..< rate * 40 + 40].reduce(0) { $0 + Int($1) } == 576)
    }
}

/// SplitMix64, for damage that is the same on every run.
private struct Random {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
}

/// Damaged files (cut, with bits turned over, with junk, with four-byte fields at their extremes, or
/// all random) are decoded without trapping, every loop ends, and MP3File gives as many samples as
/// its length says. (The scratch fuzzer runs thousands of these under the address sanitizer and
/// holds every one to the C.)
@Test func survivesDamage() {
    var random = Random(state: 2026)
    let seeds = [MP3Fixtures.tone440, MP3Fixtures.gapless, MP3Fixtures.mpeg25, MP3Fixtures.freeFormat, MP3Fixtures.layer2, MP3Fixtures.layer1]
    let extremes: [[UInt8]] = [[0xFF, 0xFF, 0xFF, 0xFF], [0x80, 0, 0, 0], [0, 0, 0, 0], [0x7F, 0xFF, 0xFF, 0xFF]]
    for _ in 0 ..< 150 {
        var bytes = seeds[random.below(seeds.count)]
        for _ in 0 ... random.below(4) {
            if bytes.isEmpty { bytes = (0 ..< 2000).map { _ in UInt8(truncatingIfNeeded: random.next()) } }
            switch random.below(7) {
            case 0: bytes = Array(bytes.prefix(random.below(bytes.count + 1)))
            case 1: bytes = Array(bytes.dropFirst(random.below(bytes.count + 1)))
            case 2:
                for _ in 0 ... random.below(40) { bytes[random.below(bytes.count)] ^= UInt8(1 << random.below(8)) }
            case 3:
                let at = random.below(bytes.count)
                bytes.insert(contentsOf: (0 ..< random.below(1500) + 1).map { _ in UInt8(truncatingIfNeeded: random.next()) }, at: at)
            case 4:
                let at = random.below(bytes.count)
                let field = extremes[random.below(extremes.count)]
                for i in 0 ..< 4 where at + i < bytes.count { bytes[at + i] = field[i] }
            case 5:
                // A Xing frame's count of frames at an extreme, and an ID3v2 tag that says it is huge.
                if let at = (0 ..< max(0, bytes.count - 16)).first(where: { bytes[$0] == 0x49 && bytes[$0 + 1] == 0x6E && bytes[$0 + 2] == 0x66 && bytes[$0 + 3] == 0x6F }) {
                    bytes[at + 7] = 0x0F
                    for i in 0 ..< 4 { bytes[at + 8 + i] = extremes[random.below(2)][i] }
                }
                bytes = [0x49, 0x44, 0x33, 3, 0, 0, 0x7F, 0x7F, 0x7F, 0x7F] + bytes
            default:
                bytes = (0 ..< random.below(4000)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            }
        }
        _ = decodeFrames(bytes)
        if let file = try? MP3File(bytes) {
            let length = file.length ?? -1
            var total = 0, steps = 0
            while steps < 100_000 {
                steps += 1
                let count = file.next()
                if count == 0 { break }
                total += count
            }
            #expect(steps < 100_000)
            #expect(total == length)
        }
    }
}

enum MP3Fixtures {
    /// A 440 Hz tone at a sixteenth of full level (ffmpeg's sine at half), half a second, by LAME: MPEG-2 layer III, 22.05 kHz mono, 32 kbit/s, with ID3v2 and ID3v1 tags (title "Tone", artist "Siday"); its frames are too small for an Info frame.
    static let tone440 = Base64.decode("""
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
IZoQVP6GZUjBpCKMMwJQwSALjAmAGQzgxw0w4fl8cWETEYJBYKQMBKJ9D52Bkby2HQyVY1er2eRXs9oFMv48BPq+PiA8pr097+jymWB5q97/7pSn973x
DPiDB94gDAkOVDQQ//NAxNUWAEYMAOf0QHDz/Ljgf/RBD9cH1Zc//EjqM7Ek0Snkbl1/5VbJlcQlnQsAf84A/zMBeWowb/AKsgbUMBlgIckOManAxxcI
RQBocycx4hcLyDKhaMTKBZR8OhEgF8KXFKNSnPj/80LE2CNhbiwDXngAskVsOkckgA55Ekqta/5BSLECI8gBoViqRWvqq/8pFMzKhXLxdOGRfNDUvev/
//mJiYF9zVIyOmCB88XTI7//4kB4JUxBTUU0LjBVVVVVVVVVVVVVVVVVVVVVVVX/80DEpiM6mkQBnKAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVf/zQsR0AAADSAHAAABVVVVVVVVVVVVV
VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVRBR1Rv
bmUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFNpZGF5AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/
""")

    /// The same tone at 44.1 kHz, a quarter of a second, by LAME at 64 kbit/s mono: MPEG-1 layer III with an Info frame and a LAME tag of its delay and padding.
    static let gapless = Base64.decode("""
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
uzCtCPMIkIECgEgwAQBACKWYzBOydnWzrgtg9BkLsTQcDgr0PjsDIxlsIQhFU+aaHs8BPs9nlJWOPAQ9Rx8QHjynx7w/SmsvHms33v/VKfN77xDuBHRG
H1AhDGwSHLfeIz6Fey5Pw/9/+GIAACAMCARCEEAAAAAAA0mJ04b2QEggNAl/nh7LGV5eAADS8v+Y9nqZYFIrS73+AOJA65YWcT+BwjoG4kg1aEok/Ax6
//tSxI0CCPAfES37IkI9FyIKvPAAsGw4UchRMXSZQKPgY8cAYNBIUGdANA0WpfilBZIuYdI5JAFK/8i5WJ0vE0UyYWv/80KxqXTIzWaG///5eMThxM0N
UkTE5/5cCg0JCIBCpL//g8EqTEFNRTQuMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqr/+1LEf4AS0REfudoAAAAANIOAAASqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqg==
""")

    /// A 300 Hz tone, 0.4 seconds, by LAME at 8 kHz mono, 24 kbit/s: MPEG-2.5.
    static let mpeg25 = Base64.decode("""
/+M4xAAAAAAAAAAAAEluZm8AAAAPAAAACAAAB5gAICAgICAgICAgICAgQEBAQEBAQEBAQEBAYGBgYGBgYGBgYGBgYICAgICAgICAgICAgKCgoKCgoKCg
oKCgoKDAwMDAwMDAwMDAwMDg4ODg4ODg4ODg4ODg////////////////AAAAOUxBTUU0LjAgAAEoAAAAACwaAAAUGCQDQCIAABgAAAeYc60WxgAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/+M4xAAq8NJYAVoYAS5ZcsuWXLLll40H0i1N0xEJBbAsgWQQAPkyuTw0BCBp
GxxKB1Kx0pRvmRpCwKIL3ia50x0x1jsTd+XyyUQw/j+Q5GKTD86enp6e28+AAODDP+AHv+OGAH4AAeHh4eGAAAAAAeHh4eGAAAAAAeHh4eGAAAAAAeHh
4eGAAAAAAeHh4eGAAAAAAeHh4eGAAAAAAeHh4eGAAAAAAeHh4ekAAAAEB4eHh+AAACPeHj0IAMwKwXDBlBqMIcLYwOggZmWxL//+mEoGWYlAyJiJ/+M4
xB8y2y5AEZ6gAKYBn3o2kIA7ZTEvB1OeEGZdq3zAuUFM001AxhBGTA9B8MHkGgwYwbDEFBDlNimMFsH//8DIMwNovA1zkDAlgM2YAzJ4ydFbJfgGCwMY
LAxhEB4ADBggMGGC+INg1Wv/8AQCHRBZEFhQfqGKQuFFJBq4Mjf//4xogqIKjlCghQQ6RcouUhwuYc7///vkyOaQUpEWIsYkVLpkXjZZd////9lJJ0VZ
ilMkUTFI9/1q//5/3Y13j7P8rcOAG4VBeTA0gT0wj4K5MHWAZzAq/+M4xB4khGn8Ad9QAAMHMZ0IWzH/iu08LbhHNU3B9DElgw8wdAJFMIMAdTAzwLYw
HIB3MAjAfjASwA4MACvx/5Jl////////+X///iuS//qd+35X/+hf/+Sf/qJJf/pr//OC7Nb/bVv/zR5+35CX//jn/9P/4xCEl/+cIM36fjwmg76ypuaE
+HyAItAfkaBe4B7VhgJoGEYACDtmBwDaBnI/HQYc8ITGBbgv4GUmMBjk5gY0IgGJAsAUQwRBAUe+WP/9v/5Kv/+tv/5z//P//0//6B//+3/8/+M4xFcb
7GYIoKfqQKj//2//p/q/OP/+pH/+v/+dJb/9Zl+v8sVMQU1FNC4wVVVVVVVVVeAB//v/1O6yxtS1HoKyBuhabijHCM5gUgHOYGSDvGDSDS5qZ+2GYq0H
/mCMgtgGbFqBiEtAVEIKBsBgWgWBwotssPr/9//7H//57/+n//n//6X/8sf///+Xv/9v/6X6/zjf/qP////86S3/8nf/6R5MQU1FNC4wVVVVVVVVVVVV
VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+M4xKQcBGoIYN/qQFX//X/MRvVeAIcZQBQE0LA8pgg4MKYTSFLmDlgeZguQXoYxcR/G
ThGtR+9Gp0bS+L8mGkBRhgrQRYYVQDlGAzAC5gA4BoYFsBVGAjAAiBn5/qCMP////////w///5gYF9/0yi/r+Wf/tx3/+S//qKw0b/TR//4Lp7/7at/+
YLP6fU8t/0zxt//O//kIJGN/1cLX7/PCuWVxmaO+mYYdgWBgjiGmH+DeYhIgZgPgtGC6AYYLQVZgWBAmAKA6hLMY90A2/0vTAyF2Mh4X/+M4xMolZGn4
AV9QACMgJYg6V15jCKADMMsVgwoQ/DAxClMI8JBWxXkPmPgDIYggZgoGGYYIJ5gcBhGA6CwYMYGhgGAqvk79SFxjZ09Zh7B7FxnnxiF5xToIMmiHgVMI
wRjQAgIxSn7I6Tk5XMOpMOWNcSChowgk0IsdIgIMnqCgIyEZkikkq8KgvZ+pycz7bw4ZYMVRAQBMeBHAZfoBDEESQIKDrajy7mq0LOXouOVE7GfbeuWN
9t64jankWsSqUQQBqAqvSIVMsxQfN2ZRyGqfKI2MZVR4/+M4xP9W08I0AZ7QAG+565hn3PXMNrFV+sRdS1F3sFWuzhkzBHLZquutMztWanq12W1akurV
+565h/c/5z////3YZsxCG2gsTiDUmcTbZmdzTns4pW8a3GatSNVs4zM2I1NW4zM2I1NX1Qbu32AAxcdGS57TkxeZMTE9daJQjJASA8jHECI6sCUe8DQN
AUNiUFYNQaes6sNS0seneW/y1QNW9Xt/+Gv/KhriLrDXEX/87U/53/yx4s+JVUxBTUU0LjBVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+M4xG4UEHXsX8wI
AFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
""")

    /// The 440 Hz tone of `tone440` by LAME in free format at 40 kbit/s: MPEG-2 layer III with no bit rate in its headers.
    static let freeFormat = Base64.decode("""
//MAxAAaCIJkH1gYADG25KFTqnVOqdU7E4HfRdiEsAjM6za83tNIy1663fhyMRiMRiMUlJg7uBuD4fggCDsH/DEp7+U8/yjuf5T39HBAHwfg+DgIBhQY
B8H6wICHB9+jwfB8HwfBwEAQBAMA+D4Pg+BAQBAMKiAgBBghACQYYTBWRf/zAsQMG6HWYLWcgABAPaT1MqlYw9f1ADQhSJh4ZM7BvcQGHxAEjIeBBnkT
LChZKFhoWg/ikhKQhb8ho5oypNf45wyxMkVID/5kXi8Yl0upf/5eJoxLpdMi8Xkf//y6XUi8XlgqDQVO//o/////2qqTx9drWSAAKMA5ARDARQawwJcF
//MCxBMacFYUAd8AABDBUQHowPkJ8MOdDEDUoR58w8ILZHgmgwCMAYMBNAWgMAlmAJABoBAAFb1YXOqpXtWjZbrdQ7Gaoqi+5NTUWf2QDYQRvr3Mjqrm
0v6tduOvT/RTv/KqsjElE/VDOiiAwFhE3RhplwCAJPdxGAXdWdAs9e6fFrD/8wDEHxaASiB0P7IkWQ8Bi3cbibSWo96LEBe+lzbaFPWJ59QyfWPUxpOL
BZDmTZGLs0GPUxBk35IUqbi9IG2LIbtdEpOSJyuD+63WbCYCmESJHLClxTAIwBw2ncmPA+oWIrOgWjsEVOqXr0TQxP6/p9BgxQWNUOa+9y10BUeRe5B8
//MCxDoYaPoMAP6EZItJPppugy4Xv1x1VEyxj02uauL3mFCdFdiE0qzqHJEjbGHn6IZ2EXUhe/GdCoWMWTlpLtLGMAgAk/jmPg4HFSUCz14fs/TR7UyL
29NFpqT/xY1Gf/231b0VjfrnMh2dXlPXF93scrbug//3ceky31kql2l4TAH/8wLEThAARhxKPzwgsAgNbPKJQPCFgrNoFo7ARQi9lzWIv9bGSLL8zTYt
jmtKqy11+tKaHobUdelTDhpCFpS2eIrep0XF4vvWzAZDshjnLmI67Z1smlG3H8cbH8EYhIwzKn+L+m/MecNAOvNO2uLYhVG5mxe37/r2SWlf9kd0MsZR
Sv/zAMSEFahKEADn9EDf0DP7/ZRO6TY3Un1a//2cfSBlB/PxyekzbykvlhS8JgDYBQayWXinfACwVm0Cz1gVegHULpYNGWHHuZbkz2k92PU52siMC7TF
Jlnfo4FMMvmKlU2U78Wuu6IcR6Utq2sfXnRcK9KXXyRq5wf+8qrdjAiggdD/8wLEog9oRjB2FvwgSqBFmjAIADc2RA5IPYHEhy9YGnb9ZfkIonDPpXWn
KcJte3n8ff/c16f885ZPEFf9o2fMjjgyOGxQ2/+c/lthOZkQ6SOBa2DIlQlwGhwVE2WdUt98OJLj2h9jkwKPC+XBFVbg8dfCBQV0tfVMQSkg/9Y1nhNK
///zAMTaFfhKEEjn9ECQlKAlkTAIQDw2LM8hPWIDhq9n5nrHGxqEl0i6KxMKucmFbgC6SaksC5lAZirVDCJ0LVnUSDX3MMwUr2Emjjqi004QOe4WFWJt
cOCEdygy9AMkFbS9jBxgTCzs3cqVGJX4xUwgawfr9XXiMCeB9y/qYxZIwB7/8wLE9x2aIgwq/oZkAQTYTD+49AsOHLVgaW31RVayTszSo1rpJoXYxun4
2/tp8prvcw3X7jfvzXX91u/s50MV1OJ5qIFV3a9qG/CT/et7v3o/YqNvZip1u/N97/ovv7H1eiH/YBf1mFidJPJ9S6pMZBD546zuN1MDDCNi2SKpgAQA
Kf/zAsT0GqBODCjn9ECATgKRtmqYWfkkEFVYnVi14i7FdNVuRU0d/d3Rqq7pVrxFlps3cF10i2KC5YVeXxETeOZqU8ViEkJ3DCqHLArDI0MFHD0Hh8VM
lgyXU5iYlNBjlxj9mIStjHJlkOVOIXjgpWtn/9YsyMDsCezAAAAEvEYAOAFG//MAxP4cyPoMQv6EZQFwDObzMtVHFDoKHkrXGit9Ye8maoqkm5TbNDKs
0PK9L2Mgn/CM6eZtmlRoeL7Phcv+UUgvqluefTv90KLQXPJAXtmhHVvk06ZrU/G4PhLEvriWQ7nTLnsRN6zPEWd/ysXdLsG3/F1izMCfkvPq4nVPB//9
aP/zAsT+HSj+CCr+hGQE0/mkVlSlnTAFQEA1B8/xOmKDgLLodnhjjZlJMY5ZJTGlMgg8s4p+xKwrgeTTHrcKyzCk60dccNR7exm9McUOl2Keq4ipkVPm
RCjJua4qAj5TFmh+LAIMBhTRWKVIeYGsW7h2c7DHKZbkYIEEvgIABLxGACgB//MAxP8gqpIEIP7GZUYBYA4m6NMPhwRCBhpOlr0VvqZuqyuSqOxbkSVt
tSrWuu4bVnV3Z3VrlqtilJWhnYtmZma7FeyFIpnkZnZnRroyNS523Rzo9WxTz/e4jctNrjVQNhjOCN53yg03hLC2JvSHF+s7B9Lu5075JVpvZQ/26lU9
pv/zAsTxGnBGECrn9ECqqk//jciJgSYKooMu0v6YAaAdGhrngpgIIAQhq40VnuEhYY7MwIa2MBqyOOPN+UrCLljqlImrbX90PbKZEiz6a11Oex8sx982
Vdqbo1brFzYlwxfylAkhF5gdbWFqsoPDX/oCltlyfnJsOMxPOkKT+zD9n3Om//MCxP0hClYEAP7KZVP5Y1qVYIwXALzMAMABTABQAAwBEAaMA+Apzj5o
fQwKgA3MAZABC7K6n5v45WdP3bHKl3vlzG4Z8Q77XZ0vZ990twW79+nGPviH+zVa1SENjXp/wxpP3Jo7EcOo5vl08+3p2VDB5IQCchG5qol/YwhgiVaD
F5D/8wDE7h4BohRU+ES9ik0ktsBrdTUtFp8vuPOiUIs+tHOJZkWUNlhb+2u9fpGay9BDBisCAskScmz/ljk3EwR8IuAwAUW1MAEADzAJwH42uFrvPumA
RVMJrsuxisWUyrkRxLndP8z+U9SnzOkv5nu5yrp62EhR5cnBkVT/feZM/Tp8//MCxOsoK/H8APmG3IusLY05NyQF7t40nWR4bgkk9IquV+40SYJVu74b
KyWutVbhc04z4eRl8rm/B9r1BCC9aD4Fqy05gBgDmAOACpIwDgKjAyAuMIoFsDBcmEOEyYgwlxhhB5nB5HEYR4XhiJBkGDQCIYHQCQNABbIwMu25b9vA
iYX/8wLEwCACHgQA/oZlyErGxgCQBwPA/zTc2BULseghCgqxoeh7PAQ9V2eRJVezwDTQ+Ph48iTZpq9/AeRIasZNXvf/dKU+bv74fx90p77xDj39KU1m
lM3/xrMAMCcH5tEHwTPs9BwSHO7aXPswf/rDH+D/+Q91t+mAQRCBA24jTfMgCv/zAMS2KsHaJAFeeACAkw/8qyMz2MzAQHBAL/zq1TNCIJJBK7/A8AsD
3oANwXCyYUuKZwM4nCEsACRKRuXeFhYUShQsBhwxMoFEx8BYKDQEHWDBYYIQdJZl8GzoWFBi0MChlwLnxOSSal1o/xOouYQmGfFaFQaQ7RctepVX/kcQ
8zL/8wLEgC2jbjzRnKAAoVyLEyWCkXycLpe9f1f/8xJkwL581Ni8dMED54umR3/////OmhubF0yMky4ibImJwzc1cvHTCkxBTUU0LjCqqqqqqqqqqqqq
qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqv/zAMQ/AAADSAHAAACqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
qqo=
""")

    /// 1000 Hz on the left and 500 Hz on the right at a sixteenth of full level, 0.3 seconds, by ffmpeg's MP2 encoder: MPEG-1 layer II, 32 kHz stereo, 64 kbit/s.
    static let layer2 = Base64.decode("""
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
""")

    /// Four MPEG-1 layer I frames, 32 kHz joint stereo, of random contents (no encoder of layer I is to hand), of which minimp3 decodes one.
    static let layer1 = Base64.decode("""
//8ZZAAAAC4AAAAAAAAAAAB3AAAAshQAALoAAAAAAABrAACS0QAAAAAA8QAAAAAA//8paQAAAAAAAAAAAAAAAACdAACaAAD+egAAAAAAKQAAXAAAAADd
AIQAAIgAAAAAws4AADMAAAAAAAAAcrn0FAAAAAAA1wBYFR7IAABvVQC4AAC5AAcAzgAAAAAnAAAA//44ZAAAAAAAAAAAAAAAZwAAAAAAAAAAAAAAAMkA
AAAALgAAANFnAJIAAAAAAAAAAAAAAAAAAABqRAAAAPgAAAAAAAAAAAAAAAAAAAAAABsAAAAAAE4AVwAAAAD7AAAAAAAAAAAAAAAAAAAAAAD4UgBPAAAA
AAAAAAAAAAAAAAAAANoAAAAAAAAmAAAAAAAA//9JZNYAMgBKAAAAEwAAAAAASQAAbwAAAOIAZvAAAABpAKR8ACAAAAAAAAAAAAAAAAAAAIwA/20AAAAA
AAAAAL9iAAAAAAAAIAAA2QAAAAAA2fcAAAB5fQAA0wAAADkAAAC4AOUAAAA7AAAAoAAAAAAAAAAAAAAAAAClPgAAALQAAAClAAAAOgAAAAAAAAARAE8x
AABLAAAAfAAAJQ0AJAAAAAAAAAAAAAAAAAAAAPwAAAAAAB8AYQDSFgAAADEA
""")
}
