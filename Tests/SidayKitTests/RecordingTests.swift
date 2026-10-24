// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayCodecs
@testable import SidayFoundation
@testable import SidayKit
import Foundation
import Testing

// Recordings: WAV files of each way of keeping their samples, read as ffmpeg reads them, and the
// renderer that plays a recording at the player's rate, with a voice for each side.

/// A WAV file of so many frames of 16-bit samples, made by `sample(frame, channel)`.
private func wav(rate: Int, channels: Int, frames: Int, tags: [(String, String)] = [], _ sample: (Int, Int) -> Int16) -> [UInt8] {
    func u32(_ v: Int) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }
    func u16(_ v: Int) -> [UInt8] { (0 ..< 2).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }
    var format = u16(1) + u16(channels) + u32(rate) + u32(rate * channels * 2) + u16(channels * 2) + u16(16)
    format = Array("fmt ".utf8) + u32(format.count) + format
    var info = Array("INFO".utf8)
    for (name, text) in tags {
        var bytes = Array(text.utf8) + [0]
        if bytes.count & 1 == 1 { bytes.append(0) }
        info += Array(name.utf8) + u32(bytes.count) + bytes
    }
    let list = tags.isEmpty ? [] : Array("LIST".utf8) + u32(info.count) + info
    var data: [UInt8] = []
    for frame in 0 ..< frames { for channel in 0 ..< channels { data += u16(Int(sample(frame, channel))) } }
    let body = Array("WAVE".utf8) + format + list + Array("data".utf8) + u32(data.count) + data
    return Array("RIFF".utf8) + u32(body.count) + body
}

/// Everything a renderer plays, to its end, interleaved.
private func playedThrough(_ renderer: any Renderer, seconds: Double = 60) -> [Float] {
    var sound: [Float] = []
    var block = [Float](repeating: 0, count: 2048 * 2)
    while !renderer.hasEnded, Double(sound.count) < seconds * Double(outputSampleRate * 2) {
        block.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 2048) }
        sound += block
    }
    return sound
}

/// Every sample of a recording as it is read.
private func readThrough(_ source: some RecordingSource) -> [[Float]] {
    var channels = [[Float]](repeating: [], count: source.channels)
    while true {
        let count = source.next()
        if count == 0 { break }
        for channel in 0 ..< source.channels { channels[channel] += UnsafeBufferPointer(start: source.samples(of: channel), count: count) }
    }
    return channels
}

private func stereo() -> LoadOptions {
    var options = LoadOptions()
    options.stereo = .abc
    return options
}

private let toneRate = 44100

/// A second of a 1 kHz tone at half of full scale on the left, and nothing on the right.
private let tone = wav(rate: toneRate, channels: 2, frames: toneRate, tags: [("INAM", "A Tone"), ("IART", "Nobody")]) { frame, channel in
    channel == 0 ? Int16((Foundation.sin(2 * Double.pi * 1000 * Double(frame) / Double(toneRate)) * 16384).rounded()) : 0
}

@Test func aWAVFileIsPlayedAtThePlayersRateWithAVoiceForEachSide() throws {
    let renderer = try TuneLoader.load(tone, format: .wav, options: stereo())
    #expect(renderer.info.format == "WAV")
    #expect(renderer.info.title == "A Tone")
    #expect(renderer.info.author == "Nobody")
    #expect(renderer.info.detail == "44.1 kHz stereo, 16-bit")
    #expect(renderer.knownLength == 1)
    #expect(renderer.channelCount == 2)
    var sides = [Float](repeating: 9, count: 2)
    sides.withUnsafeMutableBufferPointer { renderer.takeChannelSides(into: $0.baseAddress!) }
    #expect(sides == [-1, 1])

    let sound = playedThrough(renderer)
    let left = stride(from: 0, to: sound.count, by: 2).map { sound[$0] }
    let right = stride(from: 1, to: sound.count, by: 2).map { sound[$0] }
    // A second of it, at 48 kHz, and silence after.
    let heard = left.lastIndex { abs($0) > 0.001 } ?? 0
    #expect(abs(heard - outputSampleRate) < 30)
    #expect(right.allSatisfy { $0 == 0 })
    // Half of full scale, as loud as recordings are made: and still 1 kHz.
    let middle = Array(left[10000 ..< 40000])
    let peak = middle.map(abs).max() ?? 0
    #expect(abs(peak - 0.5 * RecordingPlayers.gain) < 0.001)
    let rises = (1 ..< middle.count).filter { middle[$0 - 1] < 0 && middle[$0] >= 0 }.count
    #expect(abs(rises - 625) <= 1)
}

@Test func aRecordingsLightsShowEachSideAndItsVoicesCanBeLeftOut() throws {
    let renderer = try TuneLoader.load(tone, format: .wav, options: stereo())
    var block = [Float](repeating: 0, count: 4800 * 2)
    renderer.setMuted([true, false])
    block.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
    #expect(block.allSatisfy { $0 == 0 })
    var levels = [Float](repeating: 0, count: 2)
    levels.withUnsafeMutableBufferPointer { renderer.takeChannelLevels(into: $0.baseAddress!) }
    // (A voice left out still shows how loud it is.)
    #expect(abs(levels[0] - 0.5) < 0.01)
    #expect(levels[1] == 0)
}

@Test func aRecordingHeardInMonoHasBothSidesInBothSpeakers() throws {
    let renderer = try TuneLoader.load(tone, format: .wav)
    var block = [Float](repeating: 0, count: 4800 * 2)
    block.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4800) }
    let left = stride(from: 0, to: block.count, by: 2).map { block[$0] }
    #expect((0 ..< 4800).allSatisfy { block[$0 * 2] == block[$0 * 2 + 1] })
    #expect(abs((left.map(abs).max() ?? 0) - 0.25 * RecordingPlayers.gain) < 0.001)
}

@Test func aRecordingAtThePlayersOwnRateIsPlayedSampleForSample() throws {
    let file = wav(rate: outputSampleRate, channels: 1, frames: 1000) { frame, _ in Int16(truncatingIfNeeded: frame * 37 - 18000) }
    let renderer = try TuneLoader.load(file, format: .wav)
    let sound = playedThrough(renderer)
    for frame in 0 ..< 1000 {
        #expect(sound[frame * 2] == Float(Int16(truncatingIfNeeded: frame * 37 - 18000)) / 32768 * RecordingPlayers.gain)
    }
    #expect(sound[2000 ..< sound.count].allSatisfy { $0 == 0 })
}

/// Tones well inside a CD's band come out as loud as they went in; one beyond half the lower rate is taken out.
@Test func aRecordingIsBroughtToThePlayersRateWithNothingMirrored() throws {
    for (rate, hz, kept) in [(44100, 19000.0, true), (22050, 9500, true), (96000, 30000, false), (8000, 3500, true)] {
        let file = wav(rate: rate, channels: 1, frames: rate / 2) { frame, _ in
            Int16((Foundation.sin(2 * Double.pi * hz * Double(frame) / Double(rate)) * 16384).rounded())
        }
        let sound = playedThrough(try TuneLoader.load(file, format: .wav))
        let middle = stride(from: 2000 * 2, to: 20000 * 2, by: 2).map { sound[$0] / RecordingPlayers.gain }
        let rms = (middle.map { $0 * $0 }.reduce(0, +) / Float(middle.count)).squareRoot()
        if kept {
            #expect(abs(rms - 0.5 / Float(2).squareRoot()) < 0.002, "\(rate) Hz, \(hz) Hz")
        } else {
            #expect(rms < 0.0001, "\(rate) Hz, \(hz) Hz")
        }
    }
}

/// The ways WAV files keep their samples, each read as ffmpeg reads it (the numbers are its).
@Test func everyWayOfKeepingAWAVFilesSamplesIsRead() throws {
    func fixture(_ text: String) throws -> [UInt8] { [UInt8](try #require(Data(base64Encoded: text))) }
    for (name, text, sum, magnitude) in [("IMA ADPCM", imaADPCM, -151_681, 31_106_245), ("Microsoft ADPCM", microsoftADPCM, 6131, 31_296_553)] {
        let file = try WAVFile(try fixture(text))
        #expect(file.detail == name)
        #expect(file.length == 1200)
        let channels = readThrough(file)
        let samples = (0 ..< 1200).flatMap { frame in channels.map { Int(($0[frame] * 32768).rounded()) } }
        #expect(samples.count == 2400)
        #expect(samples.reduce(0, +) == sum, "\(name)")
        #expect(samples.map(abs).reduce(0, +) == magnitude, "\(name)")
    }
    // A-law and μ-law, by G.711's own examples: the loudest and quietest of each.
    #expect(WAVFile.aLaw(0xD5) == 8 && WAVFile.aLaw(0x55) == -8 && WAVFile.aLaw(0xAA) == 32256)
    #expect(WAVFile.muLaw(0xFF) == 0 && WAVFile.muLaw(0x80) == 32124 && WAVFile.muLaw(0x00) == -32124)
}

@Test func aWAVFileThatIsNotOneIsRefusedAndNoneTraps() throws {
    #expect(throws: TuneError.self) { try WAVFile(Array("RIFF\0\0\0\0WAVE".utf8)) }
    #expect(throws: TuneError.self) { try WAVFile(Array("not a wav file at all".utf8)) }
    // Cut short anywhere, or changed at random, it is refused or played: never more.
    var random = SystemRandomNumberGenerator()
    for file in [tone, try [UInt8](#require(Data(base64Encoded: imaADPCM))), try [UInt8](#require(Data(base64Encoded: microsoftADPCM)))] {
        for _ in 0 ..< 60 {
            var bytes = Array(file.prefix(Int.random(in: 0 ... file.count, using: &random)))
            for _ in 0 ..< Int.random(in: 0 ... 8, using: &random) where !bytes.isEmpty {
                bytes[Int.random(in: 0 ..< bytes.count, using: &random)] = UInt8.random(in: 0 ... 255, using: &random)
            }
            if let renderer = try? TuneLoader.load(bytes, format: .wav, options: stereo()) {
                let sound = playedThrough(renderer, seconds: 0.1)
                #expect(sound.allSatisfy { $0.isFinite })
            }
        }
    }
}

// Made by ffmpeg (aevalsrc, 440 Hz and 660 Hz, 0.15 s at 8 kHz in stereo, blocks of 256 bytes).
private let imaADPCM =
    "UklGRjQFAABXQVZFZm10IBQAAAARAAIAQB8AACAgAAAAAQQAAgD5AGZhY3QEAAAAsAQAAGRhdGEABQAAAAAAAAAAAAB3d3d3d3cH//26CSH/aDOR" +
    "RSMTkNusCUPbvLuKJIHKrDE2NCOJUiOCkMu9rNq7ClKZIWMzJAG6vROBy70KQTQCrJkgU8q8ikI0IoG6NAK6rr6smhCaMjUCNDUygbm+ijG6zcuZ" +
    "NRK5zRhDNDOKMDQTgsnMu8i8mzCrKFM1NiKpzSMCuc2aIEQSy5oIM6jbmyA2IxKpRCKozM3LmhmqEEQTQTQkEaDrqiio27yqUxOQvAkyNiSsGGMi" +
    "Epi8vZDLrBi6CTJFQySA20MRkMurGVMzvLsKQZHbrBlEMyOgQiSBy9u9q4rLCUNDMUVDEoHKrImAu76rQiSCyqefSQAb7koACEI1M6sgVCIRuNzL" +
    "oLysEKoIMkU0JJjbIxKo66sYRCPLqglBkMyrGFMjE6hjI5Db27yciasZYzIxRDMTgNurCZDMvLtTJIDKijJVM7saUyQikNu8gcqsCqyJMGNSM4HK" +
    "MxOR2q2JQjO8rJkgAtq8iURDIoBCQwK6us2rmq6KQUMgY0MiAbnMioHJ26sxNQK5myBTNL2LMTYUAbnMErm9m7urEEQxRRKpNDMCusyaMDTdu6oY" +
    "FLi8nFM0JAEgRBKguOu7m8yaKDQZUjQkFKC8nBGozMsoUyOYqggyRcyrKEQjEqjrI6DMq8uqCUEoUxSRUyMTqMucGUNGQUYAeh5JAL2tihgSub2b" +
    "QzQzATE2ErjJzLurzYogNBhENDMjuc2aArnduyBEIqiqGFI0vZsgVCQBqOsSoLyru6sIQyhFE6A1JAKo66ooU9u8qgkTkLysMjYkEhhjIpCYvL26" +
    "y6wYQwkyRUMkkNqrEZDLvAhTM5G7CkFE26wZQjMjoNskgcvLvauKMQlDM4JFQxKA27wJQru+u5k0Adq7IUVDEgpCJYKByrysycuJQYogUzRDAbm9" +
    "IoG6vopBNAKsmhA0ybyKQTUygclTEamtzKubEIshNRI0RSKBuK6LMKnMy5pEErjMAEM0M5ogRCICub68uMyaOKsYQzVEEqDMIDRKAAraSQATkdq8" +
    "iUIzAsuZIVPavIkyNCKRySaCua3Mq5ogikFDAmNDIoG5rooxydu7mkQRucwgUzQUiiE1AgG5zLu4vZsxqxBENDYSqb0zArrdmzBFEruqGFOozJog" +
    "NCQBuDQUqLzru5sZnBBEIlI0JBGo26sgqMzLqkQioOsIMkUjqhg0JBKo68ug26sYqglBU0QjkOsjE6jbqhlTI7yciTGR67oIRDMjmFMjgdvrvKuJ" +
    "rAhCMzFFMyOB26wJkNu9q0IkgtqKMEVDuwlCJRKAytsByruKq4ogRFI0Aco0IoDJy4pCQ8yrmhACur2KRDQiAUE0ArnKvLyavooxNWqbSADnKEYA" +
    "MUUzEoDbuwiY68uqNCWR2okxVDOrGVIzEpDbvIHbrAm7ijFVQiSByjMikNrLCUJDvKyJIIHJrIk0NSKAMjUBysrMq4qsijImIGNDIgLJy4qBus2r" +
    "MjUCyYsoREO8ijEmIwG6vhK5vYqsmhhTMEUCuDQyAcm8mzFF28uaGBK4zJpDNDMCIDUiuLm+vKu9qzBFGEM1JCKozKoRqby9IGMSoKoIQkTLnChD" +
    "IwKYzBSQ25u8qgkyGFMjoTYkEpjMqxhEvL2rCSOQ26wyRYCAGFIICICAgIAICAgIgAiACAgICAiAgAgICAgIgICACAgICIAIgAiACIAIgIA="

private let microsoftADPCM =
    "UklGRlIFAABXQVZFZm10IDIAAAACAAIAQB8AAMkgAAAAAQQAIAD0AAcAAAEAAAACAP8AAAAAwABAAPAAAADMATD/iAEY/2ZhY3QEAAAAsAQAAGRh" +
    "dGEABQAAAAAQABAAsCIIJgAAAAB3d3d+eCiY3sHR4+MCIT9eO10tLxAT9dPDwtDN6u0OHjFCRUMyIiAd/NzNvtDS1dQCAjBuPEw+LiAR9OTDstDf" +
    "2939Hi9SRTNDMxEu++3Mzt+y4+XzEhE/XDw9TS8SBOTTs9HP3OzsDi8xYjUzMzEvDfvNvd/A0+bjAhEwXUw8PT8gA/TVssHA7tz9/R4gUzVDNDIv" +
    "DvztvN6w4tT08wIxPVxMPC8vEgPV06LQzu3r/R4fQkQ0QyIxHg3qzc7A0dPk5AIhT01bLT0vEgP107PSz9zc/A4fQDNVQyIhEB373c7OwOPV4wMS" +
    "ME1bPD4+ERL01AAApAUaCwUQEUJVMY4xoN7d6w4eIFI0Q0QhIQ4M7M7O38Lk1AMCIE9MTDw/LxEE48Sy0N/M7fwOL0IzVTMyIR8M7N2u3tLD5vMC" +
    "EU89Wz0uPxAD9dOzwt/d2+wOH0BDRDNEISAN/Oy938DT1PTzEjBdPFsuPhAS9OTCwsDu3Oz9Hy9CVDQzMyAe/Ou+3rDh0+XzEhBPTEwtPjAR9PTD" +
    "wsHfzOz9DS8xVDREIjEfDevdvt+x4+XzAxE/TUs8Pj8hEuTEwsHA3uvtDh4gU0UzMzEgDvvdvM/QwuTj9BEwTk1LPS4gEgTUw7LQ3tzc/R0gUkQ1" +
    "QjIhH/zs3a7Q0cTkAwIAABkIrQc9wUQyiqkOPE08TD4/EQTjxMLB393b7Q0vQURUMyMxHw363b7P0NPV8/MhP15LTS0+EAP15MKy3+7c7P4eMFJF" +
    "MzMxIB783L3N0MPU9fICME9MTD4+LxL05MOy0M/s7PwPL0FDNUIzIB8N683Oz9LT1fMCIU9dOj5NIBAD9dOy0c/d3Pz9LzFjNDVCIS8O/N293sHT" +
    "1fTyEj9eTDw9PzAC9dOzwsDd6+39Hj9DVTQyMiAODN3MvtDB5OTzAyBOTEw8Ly8h9OPEwsDf3dv9Di9BVDRDMiEfDOzdrd/R1NT0AiE/bkstPj4R" +
    "E+XTs8HQ3N3rDh9AQkQ0QiIvAACyCIwG+l0nCTNm8yHszd6x4uXj9BEwTkw9TC4hEvPmstHB3t3r/h4wQlM1MkIgDwztzM7fwtTk8xIhTkxMPT0v" +
    "IvTkxMKx7t3s/A4fQTNVMzMhLwzs3a3f0cPm4wIhME1bPT0vIQP01bLB0M3t+/4eMUJERCIyIA387L3ewdLU5fISP188XSw/IAEE5MLCwd7s3A0O" +
    "IEFUNDQxMR797L3dv9Lk5fMCIT5dSz0+LyED5sLCwc/u6+0OLzFTNUMyIRAd6929ztHT1vPyITBdTEwtPxAT9NSz0sDd6+39HjBSNlMiMhAe/OzN" +
    "ztDC1OUCAjBOTUs9Py8SBNPEstHO7AAAnAoVBg6ateNZoxf6Di8yREQ0MiEeDevNvt/RxOTzAiE/XTpNPi8hA+XTssHQ3N3sDR9BQ1UjMyEgDfrd" +
    "zr7R0tXz8xFAPVxLLi8gEvTTw8PP7trt/R8/Q1Q0MzIhHfzbzr7QweTk8gIhTkxMPS4wEfTkxMHB383r/h4fQTNVMyIhLg3rzc7fsePl9AIQME1M" +
    "TS0uIQT01LLSz93r7Q4eMVNENTIxIA783K7ewdLk5PISMF47XS0vIBL05MPD0M3s6/4OMEFERDIyIR787L3ewMLj5vICIU9MPUw+LxID5cPCwd/c" +
    "3P0OL0FDRgAAABDwEPAQ8AAQ8BAA8BDwDxE="
