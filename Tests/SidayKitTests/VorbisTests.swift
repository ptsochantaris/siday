// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayCodecs
import SidayKit
@testable import SidayFoundation
import Testing

// Fast checks of the Ogg Vorbis decoder. The thorough check is made outside the package, against the C it
// is ported from (stb_vorbis 1.22 as libopenmpt 0.8.9 ships it, built for its push-data API alone and with
// -ffp-contract=off): every Ogg Vorbis file of the collection, and every Vorbis stream in its MO3 files,
// decodes to the same bits, taking the same bytes on each call. The numbers here are that C's, for two
// files made with ffmpeg's own Vorbis encoder (which writes only stereo): 0.25 s of a 440 Hz sine at
// 8 kHz, named, and 0.2 s of 1 kHz on the left and 250 Hz on the right at 22.05 kHz.

/// FNV-1a over the bits of the floats, as the C check makes it.
private func fnv(_ floats: [Float]) -> UInt64 {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    for x in floats {
        h ^= UInt64(x.bitPattern)
        h &*= 0x0000_0100_0000_01B3
    }
    return h
}

/// Every frame a decoder gives, interleaved, fed as libopenmpt feeds it: all that is left on each call.
/// Also what each call took and gave.
private func decodeAll(_ d: VorbisDecoder, _ bytes: [UInt8], from start: Int) -> (samples: [Float], calls: [[Int]]) {
    var samples: [Float] = []
    var calls: [[Int]] = []
    var position = start
    while calls.count < bytes.count + 16 {
        let (consumed, frames) = d.decodeFrame(bytes, at: position)
        calls.append([consumed, frames])
        position += consumed
        for i in 0 ..< frames {
            for c in 0 ..< d.channels { samples.append(d.samples(of: c)[i]) }
        }
        if consumed == 0 && frames == 0 { break }
    }
    return (samples, calls)
}

/// Every frame of a file, interleaved.
private func play(_ f: VorbisFile) -> [Float] {
    var samples: [Float] = []
    var calls = 0
    while calls < 100_000 {
        calls += 1
        let n = f.next()
        if n == 0 { break }
        for i in 0 ..< n {
            for c in 0 ..< f.channels { samples.append(f.samples(of: c)[i]) }
        }
    }
    return samples
}

/// How often a channel of interleaved samples rises through 0 in a second, over the middle of it: the
/// rises between the first and the last, over the time between them.
private func frequency(_ samples: [Float], channel: Int, of channels: Int, rate: Int) -> Double {
    let frames = samples.count / channels
    var first: Int?, last = 0, rises = 0
    for i in frames / 8 + 1 ..< frames - frames / 8
        where samples[(i - 1) * channels + channel] < 0 && samples[i * channels + channel] >= 0
    {
        if first == nil { first = i } else { rises += 1 }
        last = i
    }
    guard let first, last > first else { return 0 }
    return Double(rises) * Double(rate) / Double(last - first)
}

/// The period of a channel in frames, as the lag between `shortest` and `longest` at which it is most
/// like itself: for a tone with noise on it, where counting its rises through 0 would count the noise.
private func period(_ samples: [Float], channel: Int, of channels: Int, shortest: Int, longest: Int) -> Int {
    let frames = samples.count / channels
    var best = 0, bestSum = -Double.infinity
    for lag in shortest ... longest {
        var sum = 0.0
        for i in frames / 8 ..< frames - frames / 8 - lag {
            sum += Double(samples[i * channels + channel]) * Double(samples[(i + lag) * channels + channel])
        }
        if sum > bestSum {
            best = lag
            bestSum = sum
        }
    }
    return best
}

private func rms(_ samples: [Float], channel: Int, of channels: Int) -> Double {
    let frames = samples.count / channels
    var sum = 0.0
    for i in frames / 8 ..< frames - frames / 8 {
        let x = Double(samples[i * channels + channel])
        sum += x * x
    }
    return (sum / Double(frames - frames / 4)).squareRoot()
}

/// A small generator of numbers for the fuzzing, so that a run can be made again (SplitMix64).
private struct Numbers {
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

/// A file spoilt in one to four ways: cut short, bits flipped, a run of random bytes written over it or
/// put into it, or a 4-byte field set to 0xFFFFFFFF or 0x80000000.
private func spoil(_ file: [UInt8], _ r: inout Numbers) -> [UInt8] {
    var d = file
    for _ in 0 ... r.below(4) {
        switch r.below(6) {
        case 0 where d.count > 1: d.removeLast(d.count - r.below(d.count))
        case 1 where !d.isEmpty:
            for _ in 0 ... r.below(8) { d[r.below(d.count)] ^= UInt8(1 << r.below(8)) }
        case 2 where !d.isEmpty:
            let at = r.below(d.count)
            for i in at ..< min(d.count, at + 1 + r.below(64)) { d[i] = UInt8(truncatingIfNeeded: r.next()) }
        case 3 where d.count > 4:
            let at = r.below(d.count - 4)
            let field: [UInt8] = r.below(2) == 0 ? [0xFF, 0xFF, 0xFF, 0xFF] : [0x00, 0x00, 0x00, 0x80]
            d.replaceSubrange(at ..< at + 4, with: field)
        case 4 where !d.isEmpty:
            let at = r.below(d.count)
            d.insert(contentsOf: (0 ... r.below(300)).map { _ in UInt8(truncatingIfNeeded: r.next()) }, at: at)
        default:
            if !d.isEmpty { d[r.below(min(d.count, 4096))] = UInt8(truncatingIfNeeded: r.next()) }
        }
    }
    return d
}

@Suite struct VorbisTests {
    @Test func aSineIsDecodedAsTheCDecodesIt() throws {
        let f = try VorbisFile(sine8kOgg)
        #expect(f.channels == 2)
        #expect(f.sampleRate == 8000)
        #expect(f.title == "Four Forty")
        #expect(f.artist == "A Sine")
        #expect(f.length == 2048)
        let samples = play(f)
        #expect(samples.count == 4096)
        #expect(fnv(samples) == 0x1DC7_377A_0BE5_0E7F)
        let picks: [Int: UInt32] = [0: 0x3B3F_ACDE, 1: 0x3B3F_ACDE, 100: 0xBDB5_C9A7, 1001: 0x3A05_E040,
                                    2000: 0xB8E1_1B82, 3001: 0x3813_A600, 4000: 0xBB34_F274]
        for (at, bits) in picks { #expect(samples[at].bitPattern == bits) }
        // ffmpeg's sine is an eighth of full scale, and was made stereo at 3 dB down.
        #expect(abs(frequency(samples, channel: 0, of: 2, rate: 8000) - 440) < 5)
        #expect(abs(rms(samples, channel: 0, of: 2) - 0.125 / 2) < 0.003)
    }

    @Test func eachCallTakesAndGivesWhatTheCDoes() throws {
        var consumed = 0
        let d = try VorbisDecoder(stereo22kOgg, at: 0, consumed: &consumed)
        #expect(consumed == 3405)
        #expect(d.channels == 2 && d.sampleRate == 22050)
        #expect(d.comments == ["encoder=Lavc63.1.102 vorbis"])
        let (samples, calls) = decodeAll(d, stereo22kOgg, from: consumed)
        // The first frame gives nothing, as Vorbis has it.
        #expect(Array(calls.prefix(4)) == [[532, 0], [119, 1024], [124, 1024], [116, 1024]])
        #expect(calls.count == 7)
        #expect(samples.count == 4416 * 2)
        #expect(fnv(samples) == 0xE822_55EB_5BFD_3D34)
        #expect(samples[8001].bitPattern == 0x3E4B_BED9)
        #expect(d.error == .needMoreData) // at the end
        #expect(abs(frequency(samples, channel: 0, of: 2, rate: 22050) - 1000) < 5)
        // 22050 / 250 is 88.2 (the encoder left noise on this channel, which rises through 0 too)
        #expect(abs(period(samples, channel: 1, of: 2, shortest: 60, longest: 120) - 88) <= 1)
        #expect(abs(rms(samples, channel: 0, of: 2) - 0.5 / 2.squareRoot()) < 0.02)
        #expect(abs(rms(samples, channel: 1, of: 2) - 0.25 / 2.squareRoot()) < 0.02)
    }

    /// An MO3 file of version 5 can keep one set of headers for several samples: the decoder is opened
    /// from those, and given each sample's audio from elsewhere.
    @Test func theHeadersCanBeGivenApartFromTheAudio() throws {
        var consumed = 0
        let whole = decodeAll(try VorbisDecoder(stereo22kOgg, at: 0, consumed: &consumed), stereo22kOgg, from: consumed)
        let headers = Array(stereo22kOgg[..<consumed]), audio = Array(stereo22kOgg[consumed...])
        var used = 0
        let apart = decodeAll(try VorbisDecoder(headers, at: 0, consumed: &used), audio, from: 0)
        #expect(used == consumed)
        #expect(apart.samples == whole.samples)
    }

    @Test func aChainedFileIsPlayedThroughWhileItCanBe() throws {
        let one = play(try VorbisFile(sine8kOgg))
        let twice = try VorbisFile(sine8kOgg + sine8kOgg)
        #expect(twice.length == 4096)
        #expect(play(twice) == one + one)
        // a stream of another rate ends it
        let other = try VorbisFile(sine8kOgg + stereo22kOgg)
        #expect(other.length == 2048)
        #expect(play(other) == one)
    }

    @Test func aFileStartsAgain() throws {
        let f = try VorbisFile(stereo22kOgg)
        let first = play(f)
        #expect(f.next() == 0)
        f.restart()
        #expect(play(f) == first)
    }

    @Test func afterAFlushTheDecoderFindsItsPlaceAgain() throws {
        var consumed = 0
        let d = try VorbisDecoder(stereo22kOgg, at: 0, consumed: &consumed)
        var position = consumed
        for _ in 0 ..< 2 { position += d.decodeFrame(stereo22kOgg, at: position).consumed }
        d.flush()
        // From the middle of a page, it looks for the next; this file has no other, so it ends quietly.
        var calls = 0
        while calls < 1000 {
            calls += 1
            let (c, _) = d.decodeFrame(stereo22kOgg, at: position)
            position += c
            if c == 0 { break }
        }
        #expect(calls < 1000)
        // From the start of a page, it goes on from the frame after the next.
        let e = try VorbisDecoder(stereo22kOgg, at: 0, consumed: &consumed)
        e.flush()
        let (samples, _) = decodeAll(e, stereo22kOgg, from: 58)
        #expect(!samples.isEmpty)
    }

    @Test func whatIsNotVorbisIsTurnedAway() {
        var consumed = 0
        #expect(throws: TuneError.self) { try VorbisDecoder([], at: 0, consumed: &consumed) }
        #expect(throws: TuneError.self) { try VorbisDecoder(Array("OggS not really".utf8), at: 0, consumed: &consumed) }
        #expect(throws: TuneError.self) { try VorbisFile(Array(repeating: 0x4F, count: 100)) }
        do {
            _ = try VorbisDecoder(Array(sine8kOgg.prefix(2000)), at: 0, consumed: &consumed)
            Issue.record("headers cut short were taken")
        } catch {
            #expect("\(error)".contains("cut short"))
        }
        // past the end, or before the start
        #expect(throws: TuneError.self) { try VorbisDecoder(sine8kOgg, at: sine8kOgg.count + 5, consumed: &consumed) }
        if let d = try? VorbisDecoder(sine8kOgg, at: 0, consumed: &consumed) {
            #expect(d.decodeFrame(sine8kOgg, at: sine8kOgg.count + 9) == (0, 0))
            _ = d.decodeFrame(sine8kOgg, at: -9)
            _ = d.samples(of: 7)[0]
        }
    }

    /// Spoilt files: each is opened and played to its end without stopping the program, and in a bounded
    /// number of calls. (Thousands are run outside the package, beside the C, with the same results.)
    @Test func spoiltFilesNeitherStopNorHang() {
        var r = Numbers(state: 0x5EED_0F_0995)
        for _ in 0 ..< 300 {
            let file = spoil(r.below(2) == 0 ? sine8kOgg : stereo22kOgg, &r)
            if let f = try? VorbisFile(file) {
                var calls = 0, sum: Float = 0
                while calls < 10000 {
                    calls += 1
                    let n = f.next()
                    if n == 0 { break }
                    for c in 0 ..< f.channels { sum += f.samples(of: c)[n - 1] }
                }
                #expect(calls < 10000)
                _ = sum
            }
            var consumed = 0
            if let d = try? VorbisDecoder(file, at: 0, consumed: &consumed) {
                let (_, calls) = decodeAll(d, file, from: consumed)
                #expect(calls.count <= file.count + 2)
            }
        }
    }
}

// The two files, made with ffmpeg 9.0 (`-c:a vorbis -strict -2`).

/// An Ogg Vorbis file is played as a recording: named as its tags name it, as long as its stream, at the
/// player's rate.
@Test func anOggVorbisFileIsPlayedAsARecording() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try TuneLoader.load(sine8kOgg, format: .ogg, options: options)
    #expect(renderer.info.format == "Ogg Vorbis")
    #expect(renderer.info.title == "Four Forty")
    #expect(renderer.info.author == "A Sine")
    #expect(renderer.info.detail == "8 kHz stereo")
    #expect(renderer.knownLength == 2048.0 / 8000)
    #expect(renderer.channelCount == 2)
    // 2048 samples at 8 kHz are 12,288 at 48 kHz: 48 blocks of 256, and the tune is found to have
    // ended in the block after them.
    var blocks = 0
    var block = [Float](repeating: 0, count: 256 * 2)
    while !renderer.hasEnded, blocks < 100 {
        block.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 256) }
        blocks += 1
    }
    #expect(blocks == 49)
}

private let sine8kOgg = Base64.decode("""
T2dnUwACAAAAAAAAAABZcYkpAAAAAFO7C3UBHgF2b3JiaXMAAAAAAkAfAAAAAAAAAAAAAAAAAAC7AU9nZ1MAAAAAAAAAAAAAWXGJKQEAAAAwcW+gDmD/////
//////////+7A3ZvcmJpcwwAAABMYXZmNjMuMS4xMDIDAAAAGwAAAGVuY29kZXI9TGF2YzYzLjEuMTAyIHZvcmJpcxAAAAB0aXRsZT1Gb3VyIEZvcnR5DQAA
AGFydGlzdD1BIFNpbmUBBXZvcmJpcxxCQ1YCABAAAIR0mlmqASLMQIaB0JCVAAACAABghCIMMSA0ZCUAABAAACCGkoNoQmvON+c4aJaDplJsTgcnUm2e5KZi
bs4555xzsjlnjHPOOacoZxaDZkJrzjknMWiWgmZCa84550lsHrSmSmvOOWecczoYZ4RxzjmnSWsepGZjbc45Z0FrmqPmUmzOOSdSbp7U5lJtzjnnnHPOOeec
c845p3pxOgfnhHPOOSdqb67lJnRxzjnnk3G6NyeEc84555xzzjnnnHPOOScIDVkJAAABABCEYWMYdwqC9DkaiFGEmIZMetA9OkyCxiCnkHo0OhoppQ5CSWWc
lNIJQkNWAgCAAAAQQkghhRRSSCGFFFJIIYUYYoghhpxyyimooJJKKqooo8wyyyyzzDLLLLMOO+usww5DDDHE0EorsdRUW4011pp7zrnmIK2V1lprrZRSSiml
lILQkJUAAAgAAIGQQQYZZBRSSCGFGGLKKaecggoqIDRkJQAABgDAIWeggQYaaKCBBhpooHHGGYgggggiqKSSTDoKKbXYaswx116DDjr3nnvvufgchFJKKaWU
UkoppZRSSiklCA1ZCQCAAAAACCGEEFJIIYUUUooxxhxzDjoJJQRCQ1YCAGAAAAwxxBhkkEFIIYUYYoopxxxzDDoIIZRSUmihhVxqiCWWVlqJpaWYaoux1lhz
7THW3nvvvffee++99957zoHQkJUAQAQAAIMMIogggowxBiEEhIasBABAAAAQYogxxiCEEFKIIaecgkwy6aSjkAKhISsBACcAAIQRRyRxBBJnoIEIKqkgo8xC
LLG11lprrbXWWmuttdZaa6211lprrbXWWmuttdZaay0QGrISAIgAAGCQQQYZRBBBBBlkgNCQlQAACAAAI4xABBmlFGOOOeYYdNBBJx2FFlogNGQlAOAEAEAg
oYgyzDAEEVVUUUYVVRRSRymllFJKKaWUUkoppZRSSimllFJKKaWUUkoppVRKKaUEQkNWAgBkAACQopRSKS1FgiKlGKQYS0YVc1BaiqhyDFLNqVLOIOYklogx
hJSTVDLmFEIMQuocdUwpBi2VGELGGKTYckuhcw4IDVkhAIRmADgcB5AsC5AsCwAAAAAAAAAkTQM0zwMszQMAAAAAAAAASdMAy9MAzfMAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJA0DdA8D9A8DwAAAAAAAAA0zwM8TwQ8UQQAAAAAAAAAy/MA
TfQATxQBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJA0DdA8D9A8DwAAAAAAAAAs
zwM8UQQ0TwQAAAAAAAAAy/MATxQBT/QAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
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
""")

private let stereo22kOgg = Base64.decode("""
T2dnUwACAAAAAAAAAABZKXigAAAAAPym3u0BHgF2b3JiaXMAAAAAAiJWAAAAAAAAAAAAAAAAAAC7AU9nZ1MAAAAAAAAAAAAAWSl4oAEAAABUupoRDjv/////
//////////+7A3ZvcmJpcwwAAABMYXZmNjMuMS4xMDIBAAAAGwAAAGVuY29kZXI9TGF2YzYzLjEuMTAyIHZvcmJpcwEFdm9yYmlzHEJDVgIAEAAAhHSaWaoB
IsxAhoHQkJUAAAIAAGCEIgwxIDRkJQAAEAAAIIaSg2hCa8435zholoOmUmxOBydSbZ7kpmJuzjnnnHOyOWeMc845pyhnFoNmQmvOOScxaJaCZkJrzjnnSWwe
tKZKa845Z5xzOhhnhHHOOadJax6kZmNtzjlnQWuao+ZSbM45J1JuntTmUm3OOeecc84555xzzjmnenE6B+eEc845J2pvruUmdHHOOeeTcbo3J4RzzjnnnHPO
Oeecc845JwgNWQkAAAEAEIRhYxh3CoL0ORqIUYSYhkx60D06TILGIKeQejQ6GimlDkJJZZyU0glCQ1YCAIAAABBCSCGFFFJIIYUUUkghhRhiiCGGnHLKKaig
kkoqqiijzDLLLLPMMssssw4766zDDkMMMcTQSiux1FRbjTXWmnvOueYgrZXWWmutlFJKKaWUgtCQlQAACAAAgZBBBhlkFFJIIYUYYsopp5yCCiogNGQlAAAG
AMAhZ6CBBhpooIEGGmigccYZiCCCCCKopJJMOgoptdhqzDHXXoMOOveee++5+ByEUkoppZRSSimllFJKKSUIDVkJAIAAAAAIIYQQUkghhRRSijHGHHMOOgkl
BEJDVgIAYAAADDHEGGSQQUghhRhiiinHHHMMOgghlFJSaKGFXGqIJZZWWomlpZhqi7HWWHPtMdbee++9995777333nvOgdCQlQBABAAAgwwiiCCCjDEGIQSE
hqwEAEAAABBiiDHGIIQQUoghp5yCTDLppKOQAqEhKwEAJwAAhBFHJHEEEmeggQgqqSCjzEIssbXWWmuttdZaa6211lprrbXWWmuttdZaa6211lprLRAashIA
iAAAYJBBBhlEEEEEGWSA0JCVAAAIAAAjjEAEGaUUY4455hh00EEnHYUWWiA0ZCUA4AQAQCChiDLMMAQRVVRRRhVVFFJHKaWUUkoppZRSSimllFJKKaWUUkop
pZRSSimlVEoppQRCQ1YCAGQAAJCilFIpLUWCIqUYpBhLRhVzUFqKqHIMUs2pUs4g5iSWiDGElJNUMuYUQgxC6hx1TCkGLZUYQsYYpNhyS6FzDggNWSEAhGYA
OBwHkCwLkCwLAAAAAAAAACRNAzTPAyzNAwAAAAAAAABJ0wDL0wDN8wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAkDQN0DwP0DwPAAAAAAAAADTPAzxPBDxRBAAAAAAAAADL8wBN9ABPFAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAkDQN0DwP0DwPAAAAAAAAACzPAzxRBDRPBAAAAAAAAADL8wBPFAFP9AAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
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
ziMJw86b8Y3YZsKG8+bQhvNmwobz5uIs+5y9z9Pb//APv/Jc/r9BvmOXn849vPIVKvTufWfKwdLdu8/a6uzWZx78eds3s08vntny8HTZ58ERn13Zurp9bevq
9rWtx648fvHYlSec/syVJ5x+7PLxi8e2H9+6uv3/998+fn//7eP399/efn/97e3319/efn/97e339UuX39e/XT7W75eP9fvlY/1++Vi/Xz7W75eP9fvlY/1+
+djv52O/n4/9fj72+/nY7+ftZ95+5u1n3n7m7WfefubtZ95+5u1n3n7m7WfefubtZdZeZu1lVi2z9uJVi1ctXrV41eJVi1ctXrV41eJVi1cWVhasscYaa6yx
xhprrLHGGmusscYaa6yxxhprrLHGGmusscYaa6yxxhprrLHGGmui0Wg0Go1Go9FoNBqNRqPRaDQajUaj0Wg0Go1GAX7T+HJ/hKz/nmP6n1LRH/r9F4QQU4uy
GUmw/QJ7FymEftDnxmI0EqLwwABgMSwBoFQOBBEAAAAAAAAAAAAAAAAAdOteXa97DADg/FlfdDxBkRRJcXFj43DAyicMfTdvhliJlRhrLAAAEdXwzWhJvlY9
8P4YAAAAPsPYdPdLyPrvuxim/yn5ldD7tyCECkLU1NCbKQnGL9Q4RQrpAb2/hxHKCDmiMAAAAEsAlJQtQQEAAAAAAAAAAAAAAACA4U/0n9TrHnYAwD7/2E/9
s7wdpNJq93CstK38r/0iLenjtZVYiZUAESFDfPvN5gP7wy3nl+0AAP7i2Az9Syjmf9+x/U/FL+nzsyCEeGq4nygYn6txJyGVN6rfDkIoI5QQURhgAFgMSwAo
Vg4EBQAAAAAAAAAAAAAAAAB4bd2jMQAAHn/u8Qd6AtZdd2Elfaz72819DxawATFq8gAARKIaHXrEkmgo//P1HAAAHrjL4orUJYjBDKFHREfKCAklzlxGIqYL
qQUhhA6hNAg5EvpRpiiKQrYn2xmtCQCA76OHjz99uPn+9OnTnj98/Lg8fvr06OHjxwf706fHH/P19PFp7cfn5+3h6WkBQKkY7+cvP3/ecTisZe+dzh6ZSaVS
qaoAAAAAWEmdYZ7o3G30wdUgx8QftO7xXhbLstx36GvHFq9t4nPDeHf84Prg+BqnY0++nZ6ivZo8f3eXcxbLvr93+hfvrS3Y+fttVh5seGzdzXNso3ftu1Y6
/Zp7+FQhYPS3W7fH0YN9fP7g8E6nuxQrtu5//9PafvwJV/rW/T/z2HrzhF/53HZ77PU/c8GVzz7hClv3v//ptrn2+JVeO/3Y6Vq/cu3KRltXT2+xfeXKNrXT
v73vy++/f5z9/ttL6/r4/eWL1/f3V5ePj4/a7+/v+3x8fJys39+3y8fHyvI8C/O+q3t5lvb6vsPyPM2870ovy8Ks72oty9Ks6zr0sjSzrkMvyyKv62p6WZpZ
16GXpZl1HbSP3Lfc7+/b7vfpbddevItrb95vvzfnN/vIfdv9Pr3tfM+7uPbi/fZ7c36zN/ct95G/Uat27BuM+x+u/bi/Uat27OtY/8O1H/c3lNqxD/4Ws3EC
uiAGLQSHKCMkVIdyikaEIoYkhdBDog5CKCPEj2hPTEa0JyYj2hOTxRwA4PvxL//p0Yf7+adHDz//9OE9fPrp03x9+unTWp9++fSwPv345dcHn3759cnzL79+
9PwLAMAvAEA9n/lS++zO/4APub0zRs+MqFQqBaoCAEC4kbm61D7WhzWMPiw3/ax7uO7h2A/3i77y2Ldyhzb4c3l3xji6ka6ke0iBbd4QZpdazrqNc7azn7an
tz95+3t7Pz0e+2ziBPLVQfX0/KsjfXr+1ROHL08f8/7L05906ufVz1T6+Pv3gxU/PGwXF11ROl3R0y1nPZ4+NK/vwLnnPZ7uao/1Mfpe/kyY1LLNb2dzGw4M
/3vPz8PrDntjq117/Sec5spnnnCa7fs/4XTfvvqE0/X61SdcrffTj1/d9ta1x7bZunZ1W+srV6+09e+//b7eH7/9vs7Hb7+/+vjt91eXl35/r8v77+/nvL/8
fur94/1i/fF+sf54v9gf72/ZH+9vO5f3j+3y/rF2ef9YO6/v4lneZby8y7C8z7C8z9Drs9LrskrrsrbWZW3WZW1mWZtZ1oVZ1sVe1mXodRl6XYZel6HXZdAs
q+7LHA73ZQ6H9Cqsg3y91sGeXv5g70scovdlDof0MpsDr8I6yNfLH+zpxSF6X+IQTa9pO7W8Hqi8zAdv8Tltp5Z3vfIyH7zKc9pOLe+6/TIfvMpz1tTyBg==
""")
