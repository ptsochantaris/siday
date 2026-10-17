// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// SAP files, for the 8-bit Ataris' POKEY. The thorough check is made outside the package: `siday
// --raw out.raw tune.sap` writes the machine's own samples, which agree to the sample with those
// of ASAP's `asapconv -R 48000` for every song of the ASMA collection.

private func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }

/// A SAP file of the given header lines and blocks of code and data.
private func sap(_ lines: [String], _ blocks: [(Int, [UInt8])]) -> [UInt8] {
    var file = Array("SAP\r\n".utf8)
    for line in lines { file += Array((line + "\r\n").utf8) }
    file += [0xFF, 0xFF]
    for (start, bytes) in blocks { file += word(start) + word(start + bytes.count - 1) + bytes }
    return file
}

/// Code at 0x2000 that sets the first channel of the POKEY at `pokey` going, a plain square wave
/// at full volume, at the frequency the table at 0x2100 has for the song in A; and then `after`.
private func tone(pokey: Int = 0xD200, volume: UInt8 = 0xAF, after: [UInt8] = [0x60]) -> [UInt8] {
    [0xAA, 0xBD, 0x00, 0x21] // TAX, LDA $2100,X
        + [0x8D] + word(pokey) // STA AUDF1
        + [0xA9, volume, 0x8D] + word(pokey + 1) // LDA #, STA AUDC1
        + after
}

/// The frequencies for two songs: about 391 Hz, and an octave and a bit above it.
private let table: (Int, [UInt8]) = (0x2100, [0x50, 0x28])
private let player: (Int, [UInt8]) = (0x2080, [0x60]) // RTS

private func render(_ renderer: any Renderer, seconds: Double) -> [Float] {
    let frames = Int(seconds * Double(outputSampleRate))
    var buffer = [Float](repeating: 0, count: frames * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
    return buffer
}

/// How many times a second the left side crosses nought upwards, from `skip` seconds in.
private func frequency(_ samples: [Float], skip: Double = 0.1) -> Double {
    let start = Int(skip * Double(outputSampleRate))
    var crossings = 0
    for i in stride(from: start * 2 + 2, to: samples.count, by: 2) where samples[i - 2] < 0 && samples[i] >= 0 { crossings += 1 }
    return Double(crossings) / (Double(samples.count / 2 - start) / Double(outputSampleRate))
}

private func swing(_ samples: [Float], from: Int, side: Int = 0) -> Float {
    var low: Float = 0, high: Float = 0
    for i in stride(from: from * 2 + side, to: samples.count, by: 2) {
        low = min(low, samples[i])
        high = max(high, samples[i])
    }
    return high - low
}

private let typeB = ["AUTHOR \"Someone\"", "NAME \"A Tune\"", "DATE \"1987\"", "SONGS 2", "DEFSONG 1", "TYPE B",
                     "INIT 2000", "PLAYER 2080", "TIME 01:23.456 LOOP", "TIME 00:05"]

@Test func sapHeaderIsRead() throws {
    let renderer = try SAPRenderer(sap(typeB, [(0x2000, tone()), player, table]))
    #expect(renderer.info.format == "SAP")
    #expect(renderer.info.title == "A Tune")
    #expect(renderer.info.author == "Someone")
    #expect(renderer.info.detail == "1987, Atari 8-bit")
    #expect(renderer.subsongCount == 2)
    #expect(renderer.defaultSubsong == 1)
    #expect(renderer.songs.map(\.length) == [83.456, 5])
    #expect(renderer.channelCount == 5 && renderer.channelsAlwaysShown == 4 && renderer.speakerChannel == 4)
}

@Test func sapUnknownNamesAreMadePlain() {
    func tidied(_ text: String) -> String { String(decoding: SAPFile.tidied(Array(text.utf8)), as: UTF8.self) }
    #expect(tidied("<?>") == "")
    #expect(tidied("<?> (Mister Beep)") == "Mister Beep")
    #expect(tidied("Jacek Dojwa <?>") == "Jacek Dojwa?")
    #expect(tidied("<?> Spring & Vin Samuel (VinsCool)") == "? Spring & Vin Samuel (VinsCool)")
    #expect(tidied("Lukasz Sychowicz (X-Ray)") == "Lukasz Sychowicz (X-Ray)")
}

@Test func sapPlaysTheSongAskedFor() throws {
    let renderer = try SAPRenderer(sap(typeB, [(0x2000, tone()), player, table]))
    // The machine's clock, divided by 28, by the frequency's register and one, and by two for a
    // square wave's two halves.
    renderer.select(subsong: 0)
    #expect(abs(frequency(render(renderer, seconds: 1)) - 1_773_447.0 / (28 * 81 * 2)) < 2)
    renderer.select(subsong: 1)
    #expect(abs(frequency(render(renderer, seconds: 1)) - 1_773_447.0 / (28 * 41 * 2)) < 2)
}

@Test func sapVoicesAreShown() throws {
    let renderer = try SAPRenderer(sap(typeB, [(0x2000, tone()), player, table]))
    renderer.select(subsong: 0)
    _ = render(renderer, seconds: 0.2)
    var levels = [Float](repeating: 0, count: 5)
    renderer.takeChannelLevels(into: &levels)
    #expect(levels == [1, 0, 0, 0, 0])
    var pitches = [Float](repeating: 0, count: 5), struck = [Bool](repeating: false, count: 5)
    renderer.takeChannelNotes(pitches: &pitches, struck: &struck)
    #expect(abs(pitches[0] - ChannelPitch.note(ofHz: 1_773_447.0 / (28 * 81 * 2))) < 0.01)
    #expect(pitches[1 ... 4].allSatisfy { $0 == 0 })
    #expect(struck[0])
}

@Test func sapChannelCanBeLeftOut() throws {
    let renderer = try SAPRenderer(sap(typeB, [(0x2000, tone()), player, table]))
    #expect(swing(render(renderer, seconds: 0.5), from: 4800) > 0.01)
    renderer.setMuted([true, false, false, false])
    #expect(swing(render(renderer, seconds: 0.5), from: 4800) < 0.0001)
    renderer.setMuted([])
    #expect(swing(render(renderer, seconds: 0.5), from: 4800) > 0.01)
}

@Test func sapStereoHasAPOKEYOnEachSide() throws {
    // The second POKEY's registers are 0x10 above the first's; this one is quieter.
    let code = tone(after: []) + tone(pokey: 0xD210, volume: 0xA4)
    let file = sap(["STEREO", "TYPE B", "INIT 2000", "PLAYER 2080"], [(0x2000, code), player, table])
    var options = LoadOptions()
    options.stereo = .abc
    options.sbProSeparation = 1
    let renderer = try SAPRenderer(file, options: options)
    #expect(renderer.channelCount == 9 && renderer.channelsAlwaysShown == 8 && renderer.speakerChannel == 8)
    #expect(renderer.info.detail == "Atari 8-bit, two POKEYs")
    let samples = render(renderer, seconds: 0.5)
    let left = swing(samples, from: 4800), right = swing(samples, from: 4800, side: 1)
    #expect(right > 0.001 && left > right * 2)
    var sides = [Float](repeating: 0, count: 9)
    renderer.takeChannelSides(into: &sides)
    #expect(sides == [-1, -1, -1, -1, 1, 1, 1, 1, 0])
    // Brought together, a fifth of the difference between the sides is kept.
    options.sbProSeparation = 0.2
    let near = render(try SAPRenderer(file, options: options), seconds: 0.5)
    let nearLeft = swing(near, from: 4800), nearRight = swing(near, from: 4800, side: 1)
    #expect(nearLeft > nearRight && nearLeft < left && nearRight > right)
    #expect(abs((nearLeft - nearRight) - 0.2 * (left - right)) < 0.01)
    // Heard in mono, the two are heard together, on both sides.
    let mono = render(try SAPRenderer(file), seconds: 0.5)
    #expect(abs(swing(mono, from: 4800) - (left + right) / 2) < 0.01)
    #expect(swing(mono, from: 4800) == swing(mono, from: 4800, side: 1))
}

@Test func sapTypeDRunsAsTheMachinesProgram() throws {
    // Its INIT never comes back; it is the program the machine runs.
    let code = tone(after: [0x4C, 0x0C, 0x20]) // JMP to itself
    let renderer = try SAPRenderer(sap(["TYPE D", "INIT 2000"], [(0x2000, code), table]))
    #expect(abs(frequency(render(renderer, seconds: 1)) - 1_773_447.0 / (28 * 81 * 2)) < 2)
}

@Test func sapWhoseCodeDoesNotComeBackIsRefused() {
    let code: [UInt8] = [0x4C, 0x00, 0x20] // JMP to itself
    #expect(throws: TuneError.self) { try SAPRenderer(sap(["TYPE B", "INIT 2000", "PLAYER 2080"], [(0x2000, code), player])) }
}

@Test func sapDamagedFilesAreRefused() {
    #expect(throws: TuneError.self) { try SAPRenderer(Array("not a SAP file at all, not at all".utf8)) }
    #expect(throws: TuneError.self) { try SAPRenderer(sap(["TYPE B", "PLAYER 2080"], [player])) }
    #expect(throws: TuneError.self) { try SAPRenderer(sap(["TYPE X", "INIT 2000"], [player])) }
    #expect(throws: TuneError.self) { try SAPRenderer(sap(["TYPE B", "INIT 2000", "PLAYER 2080", "TIME 1:2"], [player])) }
}

@Test func sapTimersInterruptTheProcessor() throws {
    // The first timer, at its slowest, interrupts the processor, which counts the interrupts at
    // 0x80 and sets the channel's volume from the count.
    let interrupt: [UInt8] = [0x48, 0xE6, 0x80, 0xA5, 0x80, 0x29, 0x0F, 0x09, 0xA0, 0x8D, 0x01, 0xD2, // PHA INC LDA AND ORA STA AUDC1
                              0xA9, 0x00, 0x8D, 0x0E, 0xD2, 0xA9, 0x01, 0x8D, 0x0E, 0xD2, 0x68, 0x40] // IRQEN off and on, PLA RTI
    let start: [UInt8] = [0x78, 0xA9, 0x00, 0x8D, 0x08, 0xD2, // SEI, AUDCTL 0
                          0xA9, 0xFF, 0x8D, 0x00, 0xD2, // AUDF1 255
                          0xA9, 0x01, 0x8D, 0x0E, 0xD2, 0x8D, 0x09, 0xD2, // IRQEN timer 1, STIMER
                          0x58, 0x4C, 0x14, 0x20] // CLI, JMP to itself
    let renderer = try SAPRenderer(sap(["TYPE D", "INIT 2000"], [(0x2000, start), (0x2100, interrupt), (0xFFFE, [0x00, 0x21])]))
    _ = render(renderer, seconds: 0.5)
    var levels = [Float](repeating: 0, count: 5)
    renderer.takeChannelLevels(into: &levels)
    // (So many interrupts a second: the clock divided by 28 and by 256.)
    #expect(levels[0] > 0)
}

@Test func sapConsoleLoudspeakerIsAVoice() throws {
    // A square wave on the console's loudspeaker alone, as a beeper is played: in for four lines of
    // the screen, held by WSYNC, and out for four.
    let wait: [UInt8] = [0x8D, 0x0A, 0xD4] // STA WSYNC
    let code: [UInt8] = [0xA9, 0x00, 0x8D, 0x1F, 0xD0] + wait + wait + wait + wait
        + [0xA9, 0x08, 0x8D, 0x1F, 0xD0] + wait + wait + wait + wait + [0x4C, 0x00, 0x20]
    let renderer = try SAPRenderer(sap(["TYPE D", "INIT 2000"], [(0x2000, code)]))
    let samples = render(renderer, seconds: 0.5)
    #expect(swing(samples, from: 4800) > 0.01)
    var levels = [Float](repeating: 0, count: 5)
    renderer.takeChannelLevels(into: &levels)
    #expect(levels == [0, 0, 0, 0, 1])
    var pitches = [Float](repeating: 0, count: 5), struck = [Bool](repeating: false, count: 5)
    renderer.takeChannelNotes(pitches: &pitches, struck: &struck)
    #expect(abs(pitches[4] - ChannelPitch.note(ofHz: 1_773_447.0 / (114 * 8))) < 0.5)
    #expect(struck[4])
    renderer.setMuted([false, false, false, false, true])
    _ = render(renderer, seconds: 0.2)
    #expect(swing(render(renderer, seconds: 0.5), from: 4800) < 0.0001)
}
