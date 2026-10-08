// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Foundation
import Testing

// Fast checks of the tunes that are for the FM chip alone: CMF files, on Creative's driver, and ROL
// files, on AdLib's. The thorough check is made outside the package, against the players they are
// ported from (fmdrv, and AdPlug's ROL player) on the chip this one is ported from: `siday --raw
// out.raw tune.cmf` writes the chip's own samples for the tune, and the two are to agree to the sample.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
private func long(_ value: Int) -> [UInt8] { word(value & 0xFFFF) + word(value >> 16 & 0xFFFF) }
private func number(_ value: Float) -> [UInt8] { long(Int(value.bitPattern)) }
private func padded(_ text: String, _ length: Int) -> [UInt8] { Array(text.utf8) + [UInt8](repeating: 0, count: length - text.utf8.count) }

private func mono(_ renderer: any Renderer, seconds: Double) -> [Float] {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return stride(from: 0, to: frames * 2, by: 2).map { buffer[$0] }
}

private func crossings(_ samples: ArraySlice<Float>) -> Int {
    zip(samples, samples.dropFirst()).count { $0 < 0 && $1 >= 0 }
}

private func loudest(_ samples: ArraySlice<Float>) -> Float { samples.map(abs).max() ?? 0 }

/// A CMF file of one instrument, a plain sine that holds, and one note: middle C for a second.
/// - Parameters:
///   - before: MIDI to come before the note.
///   - title: a title, which goes between the header and the instrument.
private func cmf(before: [UInt8] = [], title: String = "", version: Int = 0x0101, key: UInt8 = 60, speed: UInt8 = 127) -> [UInt8] {
    let text = title.isEmpty ? [] : Array(title.utf8) + [0]
    let instruments = 40 + text.count
    var file = Array("CTMF".utf8) + word(version) + word(instruments) + word(instruments + 16) + word(48) + word(96)
    file += word(title.isEmpty ? 0 : 40) + word(0) + word(0) + [UInt8](repeating: 0, count: 16) + word(1) + word(120)
    file += text
    // The first operator silent and the second at full level, both holding, joined so that only the second is heard.
    file += [0x21, 0x21, 0x3F, 0x00, 0xF0, 0xF0, 0x0F, 0x0F, 0x00, 0x00, 0x00] + [UInt8](repeating: 0, count: 5)
    file += [0x00, 0xC0, 0x00] + before + [0x00, 0x90, key, speed, 0x60, 0x80, key, 0x00, 0x00, 0xFF, 0x2F, 0x00]
    return file
}

@Test func cmfNoteSoundsAtItsPitchForItsLength() throws {
    let renderer = try TuneLoader.load(cmf(title: "one note"), format: .cmf)
    #expect(renderer.info.format == "CMF")
    #expect(renderer.info.title == "one note")
    #expect(renderer.info.detail == "Sound Blaster FM, 9 voices")
    // 96 ticks at 96 a second, and a second for the note to die away.
    #expect(abs(renderer.knownLength! - 2.0) < 0.01)
    #expect(!renderer.endsByLooping)

    // Middle C on the chip is its number 343 in its fourth octave: 260 Hz.
    let sound = mono(renderer, seconds: 1)
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 260) <= 2)
    #expect(loudest(sound[4800...]) > 0.05)
    #expect(!renderer.hasEnded)
    // Let go, it is given a second to die away, and the tune is over. (The driver, stopping, makes the
    // first voice die away slowly, so there is still something of it to fade at the end of the second.)
    let after = mono(renderer, seconds: 1.5)
    #expect(loudest(after[24000 ..< 38400]) > 0.001)
    #expect(loudest(after[47950 ..< 48000]) < 0.001)
    #expect(loudest(after[48000...]) == 0)
    #expect(renderer.hasEnded)
    // And it can be played again.
    renderer.select(subsong: 0)
    #expect(!renderer.hasEnded)
    #expect(mono(renderer, seconds: 1) == sound)
}

@Test func cmfDriverDoesWhatCreativesDid() throws {
    // A key struck softly is quieter.
    let hard = mono(try TuneLoader.load(cmf(), format: .cmf), seconds: 0.5)
    let soft = mono(try TuneLoader.load(cmf(speed: 1), format: .cmf), seconds: 0.5)
    #expect(loudest(soft[4800...]) < loudest(hard[4800...]) * 0.8)
    #expect(loudest(soft[4800...]) > 0.002)

    // The driver's own controller for pitch: up by so many 256ths of a semitone. 127 of them is all but
    // half a semitone, 268 Hz.
    let raised = mono(try TuneLoader.load(cmf(before: [0x00, 0xB0, 0x68, 127]), format: .cmf), seconds: 1)
    #expect(abs(crossings(raised[4800...]) * 10 / 9 - 268) <= 2)
    // A bend of pitch as MIDI has it is not something the driver did.
    let bent = mono(try TuneLoader.load(cmf(before: [0x00, 0xE0, 0x00, 0x7F]), format: .cmf), seconds: 1)
    #expect(abs(crossings(bent[4800...]) * 10 / 9 - 260) <= 2)

    // Its controller for the drums: six voices are left for notes.
    let drums = try TuneLoader.load(cmf(before: [0x00, 0xB0, 0x67, 0x01, 0x00, 0xC0, 0x00]), format: .cmf)
    #expect(drums.info.detail == "Sound Blaster FM, 6 voices and drums")
    #expect(loudest(mono(drums, seconds: 0.5)[4800...]) > 0.05)

    // The older kind of file, with its count of instruments in one byte.
    var old = cmf(version: 0x0100)
    old.remove(at: 0x25)
    old[6] -= 1
    old[8] -= 1
    #expect(loudest(mono(try TuneLoader.load(old, format: .cmf), seconds: 0.5)[4800...]) > 0.05)
}

@Test func cmfThatIsNotOneIsRefused() throws {
    #expect(throws: TuneError.self) { try TuneLoader.load([UInt8](repeating: 0x41, count: 200), format: .cmf) }
    #expect(throws: TuneError.self) { try TuneLoader.load(cmf(version: 0x0200), format: .cmf) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array(cmf().prefix(30)), format: .cmf) }
    // One cut short in its music stops where the music does.
    let short = try TuneLoader.load(Array(cmf().dropLast(6)), format: .cmf)
    _ = mono(short, seconds: 2.5)
    #expect(short.hasEnded)
    // And one whose music never says it is over, and is nothing but notes, ends with the file.
    #expect(try TuneLoader.load(Array(cmf().dropLast(4)), format: .cmf).knownLength != nil)
}

/// A bank file of instruments that are plain sines.
/// - Parameter instruments: each one's name, and how much quieter than full it is (from 0 to 63).
private func bank(_ instruments: [(name: String, quieter: UInt8)]) -> [UInt8] {
    var file: [UInt8] = [1, 0] + Array("ADLIB-".utf8) + word(instruments.count) + word(instruments.count + 1)
    file += long(28) + long(28 + (instruments.count + 1) * 12) + [UInt8](repeating: 0, count: 8)
    for (index, instrument) in instruments.enumerated() { file += word(index) + [1] + padded(instrument.name, 9) }
    file += word(instruments.count) + [0] + padded("", 9) // a place kept free
    for instrument in instruments {
        // Each operator: scaling, multiple, feedback, attack, sustain, whether it holds, decay, release,
        // level, tremolo, vibrato, whether it hurries when high, and whether the two are joined in a chain.
        file += [0, 0] + [0, 1, 0, 15, 0, 1, 0, 15, 63, 0, 0, 0, 1] + [0, 1, 0, 15, 0, 1, 0, 15, instrument.quieter, 0, 0, 0, 1] + [0, 0]
    }
    return file + [UInt8](repeating: 0, count: 30)
}

/// A ROL file with one note in its first voice: middle C for a second.
private func rol(instrument: String = "SINE", drums: Bool = false, volume: Float = 1, bend: Float? = nil) -> [UInt8] {
    var file = word(0) + word(4) + padded("\\roll\\default", 40) + word(4) + word(4) + word(48) + word(56) + [0, drums ? 0 : 1]
    file += [UInt8](repeating: 0, count: 90 + 38 + 15) + number(120) + word(0)
    for voice in 0 ..< (drums ? 11 : 9) {
        let filler = [UInt8](repeating: 0, count: 15)
        guard voice == 0 else {
            file += filler + word(0) + filler + word(0) + filler + word(0) + filler + word(0)
            continue
        }
        file += filler + word(8) + word(60) + word(8)
        file += filler + word(1) + word(0) + padded(instrument, 9) + [0, 0, 0]
        file += filler + word(1) + word(0) + number(volume)
        file += filler + (bend.map { word(1) + word(0) + number($0) } ?? word(0))
    }
    return file
}

private func played(_ file: [UInt8], banks: [[UInt8]] = [], seconds: Double = 1) throws -> (renderer: any Renderer, sound: [Float]) {
    var options = LoadOptions()
    options.adLibBanks = banks.map { AdLibBank($0) }
    let renderer = try TuneLoader.load(file, format: .rol, options: options)
    return (renderer, mono(renderer, seconds: seconds))
}

@Test func rolNoteSoundsAtItsPitchForItsLength() throws {
    let (renderer, sound) = try played(rol(), banks: [bank([("SINE", 0)])])
    #expect(renderer.info.format == "ROL")
    #expect(renderer.info.detail == "AdLib Visual Composer, 9 voices")
    // Eight ticks at four to the beat and 120 beats a minute, and a second for the note to die away.
    #expect(abs(renderer.knownLength! - 2.0) < 0.01)
    #expect(abs(crossings(sound[4800...]) * 10 / 9 - 260) <= 2)
    #expect(loudest(sound[4800...]) > 0.05)
    _ = mono(renderer, seconds: 1.5)
    #expect(renderer.hasEnded)

    // At half the volume it is quieter, and bent as far up as it goes it is all but a semitone higher.
    let half = try played(rol(volume: 0.5), banks: [bank([("SINE", 0)])]).sound
    #expect(loudest(half[4800...]) < loudest(sound[4800...]) * 0.8)
    #expect(loudest(half[4800...]) > 0.002)
    let bent = try played(rol(bend: 2), banks: [bank([("SINE", 0)])]).sound
    #expect(abs(crossings(bent[4800...]) * 10 / 9 - 275) <= 2)

    // With the drums there are eleven voices in the file, and six of the chip's for notes.
    let drums = try played(rol(drums: true), banks: [bank([("SINE", 0)])])
    #expect(drums.renderer.info.detail == "AdLib Visual Composer, 6 voices and drums")
    #expect(loudest(drums.sound[4800...]) > 0.05)
}

@Test func rolFindsItsInstrumentsWhereItCan() throws {
    // In the first bank that has one of the name, whatever its letters' case.
    let loud = bank([("OTHER", 63), ("SINE", 0)]), quiet = bank([("SINE", 40)])
    let first = try played(rol(), banks: [loud, quiet]).sound, second = try played(rol(), banks: [quiet, loud]).sound
    #expect(loudest(second[4800...]) < loudest(first[4800...]) * 0.1)
    #expect(try played(rol(instrument: "sine"), banks: [loud]).sound == first)
    #expect(try played(rol(), banks: [bank([("OTHER", 0)]), loud]).sound == first)
    #expect(AdLibBank(loud).count == 2)
    #expect(AdLibBank([1, 2, 3]).count == 0)

    // Failing that, among the instruments that come with the player: AdLib's own are all there.
    let own = try played(rol(instrument: "PIANO1"))
    #expect(own.renderer.info.detail == "AdLib Visual Composer, 9 voices")
    #expect(loudest(own.sound[..<24000]) > 0.05)
    for name in ["ACCORDN", "BDRUM1", "CYMBAL1", "SNARE1", "XYLO1", "piano1"] {
        #expect(BuiltInAdLibBank.instrument(named: AdLibBank.capitals(name.utf8)) != nil, "\(name)")
    }
    // The bass drum as AdLib made it: a soft thump an octave down, from two operators in a chain.
    let drum = try #require(BuiltInAdLibBank.instrument(named: Array("BDRUM1".utf8)))
    #expect(drum.modulator == AdLibInstrument.Operator(ammulti: 0x00, ksltl: 0x0B, ardr: 0xA8, slrr: 0x4C, waveform: 0))
    #expect(drum.carrier == AdLibInstrument.Operator(ammulti: 0x00, ksltl: 0x00, ardr: 0xD6, slrr: 0x4F, waveform: 0))
    #expect(drum.fbc == 0x00)
    #expect(AdLibBankData.instruments > 1000)

    // And one that is nowhere is silent, and said to be missing.
    let none = try played(rol(instrument: "NOSUCH1"), banks: [loud])
    #expect(none.renderer.info.detail == "AdLib Visual Composer, 9 voices, 1 instrument not found")
    #expect(loudest(none.sound[...]) < 0.001)
    #expect(BuiltInAdLibBank.instrument(named: Array("NOSUCH1".utf8)) == nil)
    #expect(BuiltInAdLibBank.instrument(named: []) == nil)
}

@Test func rolThatIsCutShortPlaysAsFarAsItGoes() throws {
    // Cut off part way through its other voices, the first is all there.
    let whole = rol()
    let cut = try played(Array(whole.prefix(whole.count - 400)), banks: [bank([("SINE", 0)])])
    #expect(loudest(cut.sound[4800...]) > 0.05)
    #expect(cut.renderer.knownLength != nil)
    #expect(throws: TuneError.self) { try TuneLoader.load([UInt8](repeating: 0x41, count: 4000), format: .rol) }
    // A tempo of nothing is not waited on for ever.
    var still = rol()
    still.replaceSubrange(197 ..< 201, with: number(0))
    #expect(try played(still, banks: [bank([("SINE", 0)])]).renderer.knownLength! < 3)
}
