// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Foundation
import Testing

@Test func lh5RejectsDataThatIsNotAnArchive() {
    #expect(LH5.unwrapArchive([1, 2, 3]) == nil)
    #expect(LH5.decode([0, 0, 0, 0], offset: 0, originalSize: 16) == nil)
}

@Test func ayChipProducesATone() {
    var chip = AYChip(type: .ay, clockHz: 1_773_400, sampleRate: 48000, stereo: .mono)
    defer { chip.deallocate() }
    // Tone period 252 on channel A is 1773400 / 16 / 252 = 439.8 Hz.
    chip.write(0, 252); chip.write(1, 0); chip.write(7, 0x3E); chip.write(8, 15)
    var crossings = 0
    var previous = 0.0
    for i in 0 ..< 48000 {
        let (l, _) = chip.sample()
        if i > 4800, previous < 0, l >= 0 { crossings += 1 }
        previous = l
    }
    // 0.9 s of a 439.8 Hz tone.
    #expect(abs(crossings - 396) <= 2)
}

@Test func songLengthDatabaseIsReadFromBytes() {
    let text = "[Database]\r\n; /MUSICIANS/H/Hubbard_Rob/Commando.sid\r\n0123456789abcdef0123456789abcdef=3:55 0:07.5 1:02.125\n"
        + ";a comment that names no tune\n; /DEMOS/A-F/Other.sid   \nfedcba9876543210fedcba9876543210=0:30\nnot an entry\n"
    let parsed = SongLengthDatabase.parse(Array(text.utf8))
    #expect(parsed.byHash.count == 2)
    #expect(parsed.byHash["0123456789abcdef0123456789abcdef"] == [235, 7.5, 62.125])
    #expect(parsed.byPath["/musicians/h/hubbard_rob/commando.sid"] == [235, 7.5, 62.125])
    #expect(parsed.byPath["/demos/a-f/other.sid"] == [30])
}

@Test func songLengthsAreFoundByContentThenByPlace() {
    let tune = Array("PSID and the rest of a tune".utf8)
    // d41d8cd98f00b204e9800998ecf8427e is the MD5 of nothing at all.
    let text = "[Database]\n; /MUSICIANS/X/Tune.sid\n0123456789abcdef0123456789abcdef=1:00\n; /DEMOS/Empty.sid\nd41d8cd98f00b204e9800998ecf8427e=0:07 0:09\n"
    let database = SongLengthDatabase(Array(text.utf8))
    #expect(!database.isEmpty)
    #expect(database.lengths(of: [], path: nil) == [7, 9])
    #expect(database.lengths(of: tune, path: nil) == nil)
    #expect(database.lengths(of: tune, path: "/Volumes/C64Music/MUSICIANS/X/Tune.sid") == [60])
    #expect(database.lengths(of: tune, path: "/elsewhere/Tune.sid") == nil)

    // A file that gives no lengths is not a database.
    #expect(SongLengthDatabase([]).isEmpty)
    #expect(SongLengthDatabase(Array("Nothing here gives a length.\nname=value\n".utf8)).isEmpty)
}

@Test func televisionKeepsTheMiddleAndLosesTheEnds() {
    for set in TelevisionSet.allCases {
        let television = Television(set)
        let middle = television.response(at: 1000)
        #expect(middle > 0.5 && middle < 2)
        // No bass to speak of, and little top.
        #expect(television.response(at: 40) < middle * 0.1)
        #expect(television.response(at: 12000) < middle * 0.25)
        // Nothing steady gets through: a speaker cannot hold a cone out.
        #expect(television.response(at: 0.001) < 1e-6)
    }
    // The wooden cabinet has the more bass of the two.
    #expect(Television(.wood).response(at: 120) > Television(.plastic).response(at: 120) * 1.5)
}

@Test func televisionIsMonoAndStaysInRange() {
    for set in TelevisionSet.allCases {
        var television = Television(set)
        let frames = 48000
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { buffer.deallocate() }
        // A full-scale 110 Hz square wave on the left only, the loudest thing a chip could send.
        for frame in 0 ..< frames {
            buffer[frame * 2] = (frame * 110 / 24000) % 2 == 0 ? 1 : -1
            buffer[frame * 2 + 1] = 0
        }
        television.process(buffer, frames: frames)
        var peak: Float = 0, heard = false
        for frame in 0 ..< frames {
            #expect(buffer[frame * 2] == buffer[frame * 2 + 1])
            peak = max(peak, abs(buffer[frame * 2]))
            if abs(buffer[frame * 2]) > 0.05 { heard = true }
        }
        #expect(peak.isFinite && peak <= 1)
        #expect(heard)

        // Silence in, after the cone has settled, is silence out.
        television.reset()
        for index in 0 ..< frames * 2 { buffer[index] = 0 }
        television.process(buffer, frames: frames)
        #expect(buffer[frames * 2 - 1] == 0)
    }
}

@Test func spectrumAnalyzerShowsATone() {
    let frames = 4096
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { buffer.deallocate() }
    func play(_ hertz: Double, amplitude: Double, into analyzer: inout SpectrumAnalyzer) {
        for frame in 0 ..< frames {
            let sample = Float(amplitude * Foundation.sin(2 * Double.pi * hertz * Double(frame) / Double(outputSampleRate)))
            buffer[frame * 2] = sample
            buffer[frame * 2 + 1] = sample
        }
        analyzer.add(buffer, frames: frames)
        analyzer.analyse()
    }
    func tallest(_ analyzer: SpectrumAnalyzer) -> Int {
        analyzer.levels.indices.max { analyzer.levels[$0] < analyzer.levels[$1] }!
    }

    // Silence shows nothing.
    var analyzer = SpectrumAnalyzer()
    play(1000, amplitude: 0, into: &analyzer)
    #expect(analyzer.levels.allSatisfy { $0 == 0 })

    // A tone stands up in one place: its own band and little either side of it.
    play(1000, amplitude: 0.25, into: &analyzer)
    let band = tallest(analyzer)
    #expect(analyzer.levels[band] > 0.5)
    #expect(analyzer.levels.indices.filter { abs($0 - band) > 2 }.allSatisfy { analyzer.levels[$0] < 0.1 })

    // A higher tone stands further to the right.
    var other = SpectrumAnalyzer()
    play(4000, amplitude: 0.25, into: &other)
    #expect(tallest(other) > band)

    // When the tone stops the bar falls, and its cap stays up a little longer.
    let before = analyzer.levels[band]
    for index in 0 ..< frames * 2 { buffer[index] = 0 }
    analyzer.add(buffer, frames: 2048)
    analyzer.analyse()
    #expect(analyzer.levels[band] < before)
    #expect(analyzer.caps[band] == before)
    for _ in 0 ..< 60 {
        analyzer.add(buffer, frames: 2048)
        analyzer.analyse()
    }
    #expect(analyzer.levels[band] == 0 && analyzer.caps[band] == 0)
}
