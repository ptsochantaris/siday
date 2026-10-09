// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// How loud each voice of a tune is, for the lights.

@Test func lightGoesByDecibels() {
    #expect(ChannelLight.brightness(of: 0) == 0)
    #expect(ChannelLight.brightness(of: 1) == 1)
    #expect(ChannelLight.brightness(of: 4) == 1)
    // Half the range of 42 dB is 21 dB down, which is a level of about 0.089.
    #expect(abs(ChannelLight.brightness(of: 0.0891) - 0.5) < 0.01)
    // Quieter than the quietest that shows.
    #expect(ChannelLight.brightness(of: 0.005) == 0)
    var last: Float = 0
    for step in 1 ... 100 {
        let brightness = ChannelLight.brightness(of: Float(step) / 100)
        #expect(brightness >= last)
        last = brightness
    }
}

@Test func ayChannelsAreMeasuredApart() {
    var chip = AYChip(type: .ay, clockHz: 1_773_400, sampleRate: 48000, stereo: .mono)
    var levels = [Float](repeating: -1, count: 3)
    func run(_ chip: inout AYChip) -> [Float] {
        for _ in 0 ..< 2000 { _ = chip.sample() }
        levels.withUnsafeMutableBufferPointer { chip.takeLevels(into: $0.baseAddress!) }
        return levels
    }

    // A is silent, B a tone at full volume, C a tone at volume 8: all three with tone on and noise off.
    chip.write(7, 0b111_000)
    chip.write(2, 200)
    chip.write(9, 15)
    chip.write(4, 100)
    chip.write(10, 8)
    var heard = run(&chip)
    #expect(heard[0] == 0)
    #expect(heard[1] == 1)
    #expect(heard[2] > 0.1 && heard[2] < 0.2)

    // Asking again starts afresh: with B turned off, it is dark the next time.
    chip.write(9, 0)
    heard = run(&chip)
    #expect(heard[1] == 0)
    #expect(heard[2] > 0.1)

    // A tone too high to hear, as tunes use to hold a channel open, is not a sound: only what is done
    // to its volume is. Here nothing is, and then it is moved between two levels.
    chip.write(0, 1)
    chip.write(8, 15)
    heard = run(&chip)
    #expect(heard[0] == 0)
    for step in 0 ..< 2000 {
        chip.write(8, step % 40 < 20 ? 15 : 11)
        _ = chip.sample()
    }
    levels.withUnsafeMutableBufferPointer { chip.takeLevels(into: $0.baseAddress!) }
    #expect(levels[0] > 0.5 && levels[0] < 1)

    // A channel with neither tone nor noise is a steady level, which is silence; with the envelope
    // going round on it, it is a sound.
    chip.write(7, 0b111_111)
    chip.write(8, 15)
    heard = run(&chip)
    #expect(heard[0] == 0)
    chip.write(11, 40)
    chip.write(13, 8)
    chip.write(8, 16)
    heard = run(&chip)
    #expect(heard[0] == 1)
}

@Test func tickLevelsHoldForAsLongAsTheTick() {
    var levels = TickLevels(voices: 2)
    var taken = [Float](repeating: -1, count: 2)
    func take(_ levels: inout TickLevels) -> [Float] {
        taken.withUnsafeMutableBufferPointer { levels.take(into: $0.baseAddress!) }
        return taken
    }
    levels.now = [0.5, 0]
    levels.tickMade()
    levels.now = [0.2, 0.7]
    levels.tickMade()
    // The most each voice has been in the ticks made since they were last taken.
    #expect(take(&levels) == [0.5, 0.7])
    // No new tick: the one that is still being given out.
    #expect(take(&levels) == [0.2, 0.7])
    levels.now = [0, 0]
    levels.tickMade()
    #expect(take(&levels) == [0.2, 0.7])
    #expect(take(&levels) == [0, 0])
}
