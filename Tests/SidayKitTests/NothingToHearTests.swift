// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayPlayer
@testable import SidayFoundation
import Testing

// The two rules every tracker's loader keeps: a file of which nothing can sound is not played, with
// one plain reason; and a file cut short plays what it has, and says so.

/// A ProTracker module of one pattern, of four channels or as many as its tag says, whose first row
/// plays the first sample (or the first so many, one to a channel), with a command beside it; each
/// sample is the same so many bytes, and loops over all of them.
private func mod(tag: String = "M.K.", sample: [Int8], command: UInt8 = 0, parameter: UInt8 = 0, samples: Int = 1) -> [UInt8] {
    let channels = tag == "6CHN" ? 6 : 4
    var file = Array("nothing to hear".utf8) + [UInt8](repeating: 0, count: 5)
    for number in 0 ..< 31 {
        var header = [UInt8](repeating: 0, count: 30)
        if number < samples {
            let words = sample.count / 2
            header[22] = UInt8(words >> 8)
            header[23] = UInt8(words & 0xFF)
            header[25] = 64
            header[28] = UInt8(words >> 8)
            header[29] = UInt8(words & 0xFF)
        } else {
            header[29] = 1
        }
        file += header
    }
    file += [1, 127] + [0] + [UInt8](repeating: 0, count: 127) + Array(tag.utf8)
    var pattern = [UInt8](repeating: 0, count: channels * 256)
    for channel in 0 ..< samples {
        // C-2 (period 428) on sample `channel + 1`.
        pattern[channel * 4 ..< channel * 4 + 4] = [0x01, 0xAC, UInt8(channel + 1) << 4 | command, parameter]
    }
    file += pattern
    for _ in 0 ..< samples { file += sample.map { UInt8(bitPattern: $0) } }
    return file
}

/// A sample of 64 bytes: a square wave, or silence.
private let square: [Int8] = (0 ..< 64).map { $0 & 8 == 0 ? 64 : -64 }
private let silence = [Int8](repeating: 0, count: 64)

private func loudest(_ renderer: any Renderer, seconds: Double = 0.5) -> Float {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return buffer.map(abs).max() ?? 0
}

private func reason(_ load: () throws -> any Renderer) -> String? {
    do {
        _ = try load()
        return nil
    } catch {
        return "\(error)"
    }
}

/// An XM file of one pattern, whose first row plays the one instrument's one sample of eight bits.
private func xm(sample: [Int8]) -> [UInt8] {
    func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
    func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16) }
    var file = Array("Extended Module: ".utf8) + Array("nothing to hear     ".utf8) + [0x1A] + Array("FastTracker v2.00   ".utf8) + word(0x0104)
    file += long(276) + word(1) + word(0) + word(2) + word(1) + word(1) + word(1) + word(6) + word(125)
    file += [UInt8](repeating: 0, count: 256)
    // The pattern: 64 rows, the first with a note on the first channel, the rest empty.
    let rows: [UInt8] = [0x80 | 0x03, 49, 1, 0x80] + [UInt8](repeating: 0x80, count: 63 * 2)
    file += long(9) + [0] + word(64) + word(rows.count) + rows
    // The instrument, with one sample, which every note plays.
    var instrument = long(263) + [UInt8](repeating: 0x20, count: 22) + [0] + word(1) + long(40)
    instrument += [UInt8](repeating: 0, count: 263 - instrument.count)
    file += instrument
    // The sample's header and its sound, as the difference from each byte to the one before.
    file += long(sample.count) + long(0) + long(sample.count) + [64, 0, 1, 128, 0, 0] + [UInt8](repeating: 0x20, count: 22)
    var last: Int8 = 0
    for value in sample {
        file.append(UInt8(bitPattern: value &- last))
        last = value
    }
    return file
}

@Test func silenceIsHeardAsSuch() {
    let none = [UInt8](repeating: 0, count: 100), one = [UInt8](repeating: 0, count: 99) + [1]
    #expect(!Shortfall.sounds(none) && Shortfall.sounds(one))
    none.withUnsafeBytes { #expect(!Shortfall.sounds($0.baseAddress, count: 100)) }
    one.withUnsafeBytes { #expect(Shortfall.sounds($0.baseAddress, count: 100) && !Shortfall.sounds($0.baseAddress, count: 99)) }
    #expect(!Shortfall.sounds(nil, count: 10))
}

@Test func moduleOfSilentSamplesIsNotPlayed() throws {
    let refusal = "\(Shortfall.nothingToHear)"
    #expect(refusal == "malformed: a module whose samples are all missing or silent")
    // A ProTracker module whose sample is all noughts, and one cut short before it.
    #expect(reason { try TuneLoader.load(mod(sample: silence), format: .mod) } == refusal)
    #expect(reason { try TuneLoader.load(Array(mod(sample: square).dropLast(64)), format: .mod) } == refusal)
    // One with a single point that is not nought is played; and so is one whose loop of silence is
    // turned over as it plays (EFx), which makes a sound of it, if a faint one.
    #expect(loudest(try TuneLoader.load(mod(sample: square), format: .mod)) > 0.05)
    #expect(reason { try TuneLoader.load(mod(sample: [0, 0, 0, 1] + silence.dropLast(4)), format: .mod) } == nil)
    #expect(loudest(try TuneLoader.load(mod(sample: silence, command: 0xE, parameter: 0xFF), format: .mod), seconds: 2) > 0)
    // An XM file, whose samples are counted the same way, and a ProTracker module of more channels
    // than four, which FastTracker 2's replayer plays.
    #expect(reason { try TuneLoader.load(xm(sample: silence), format: .xm) } == refusal)
    #expect(loudest(try TuneLoader.load(xm(sample: square), format: .xm)) > 0.05)
    #expect(reason { try TuneLoader.load(mod(tag: "6CHN", sample: silence), format: .mod) } == refusal)
}

@Test func startrekkerModuleWithoutItsInstrumentsWantsThem() {
    // A module of Startrekker's whose samples are empty is taken to have synthesised instruments in
    // the file beside it, which is wanted.
    var file = mod(tag: "FLT4", sample: [], samples: 2)
    file += [UInt8](repeating: 0, count: 2) // (a file needs its first pattern whole to be taken for one)
    do {
        _ = try TuneLoader.load(file, format: .mod, path: "/music/lead.mod")
        Issue.record("played without its instruments")
    } catch let TuneError.missingCompanion(said) {
        #expect(said == "its instruments are kept in a file of their own, lead_nt.mod, lead.mod.nt or lead.mod.as, which was not found")
    } catch {
        Issue.record("refused for another reason: \(error)")
    }
}

@Test func modNamedFileThatIsNoModuleSaysWhatItIs() {
    // An IFF file of some kind, named as a module: it says how long it is and what it holds.
    let body = Array("MMF1SONG".utf8) + [UInt8](repeating: 0x41, count: 2200)
    let file = Array("FORM".utf8) + [0, 0, UInt8((body.count) >> 8), UInt8(body.count & 0xFF)] + body
    #expect(reason { try TuneLoader.load(file, format: .mod) } == "unsupported: an IFF file of a kind this player does not know (MMF1)")
    // A module that says it is ProTracker's and ends in its first pattern has none of its samples.
    #expect(reason { try TuneLoader.load(Array(mod(sample: square).prefix(1500)), format: .mod) } == "\(Shortfall.nothingToHear)")
}
