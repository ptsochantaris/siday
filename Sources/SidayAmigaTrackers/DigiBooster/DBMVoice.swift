// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from libdigibooster3 1.2, the replayer of DigiBooster 3 that its makers published
// (copyright (c) 2014 Grzegorz Kraszewski, under the two-clause BSD licence: see THIRD-PARTY.md):
// its dsp_wavetable.c, dsp_linresampler.c, dsp_panoramizer.c and dsp_echo.c, which pass the sound
// of a track from one to the next, as here, with the same whole numbers.

import SidayFoundation

/// What plays a track's instrument, as DigiBooster 3 has it: its sample read out, round its loop or
/// back and forth, forwards or backwards; brought to the output's rate between each two of its
/// samples; and put between the speakers, not by making one side louder but by being heard a
/// little later on the other, a third of a millisecond at most. (How loud each side is comes after,
/// in the mixing.) Each step asks the one before it for as much as it needs, and says whether the
/// sample is still playing.
final class DBMVoice {
    // MARK: The sample (the replayer's "unroller")

    private struct TurnPoint {
        /// The first sample after it.
        var position: Int32 = 0
        var jump: Int32 = 0
        /// The way it is met going, and the way it goes on.
        var meets = forwards, leaves = forwards
        var count: Int32 = 0
    }

    private static let forwards = 1, backwards = 2

    private var data: UnsafeMutablePointer<Int16>
    private var length: Int32 = 0
    private var position: Int32 = 0
    private var loopFirst: Int32 = 0, loopLast: Int32 = -1
    private var direction = forwards
    private var loopType = 0
    private var reversed = false
    private var first = TurnPoint(), second = TurnPoint()
    private var hasFirst = false, hasSecond = false

    // MARK: Bringing it to the output's rate (the "resampler")

    private let buffer = Memory<Int16>(capacity: 1024)
    /// Where it is among the samples in hand, and how far it goes for each it makes: in 65,536ths.
    private var at: UInt32 = 0
    var step: UInt32 = 65536
    private var flushed = true

    // MARK: Putting it between the speakers (the "panoramizer")

    private let delays = Memory<Int16>(capacity: 1088)
    private var delayLeft = 0, delayRight = 0
    private let phases: UnsafePointer<Int16>

    init(phases: UnsafePointer<Int16>, silence: UnsafeMutablePointer<Int16>) {
        self.phases = phases
        data = silence
        for i in 0 ..< 1088 { delays.pointer[i] = 0 }
        for i in 0 ..< 1024 { buffer.pointer[i] = 0 }
    }

    /// Made afresh for a sample, as the replayer makes a new one for every note given an instrument.
    func start(_ sample: UnsafeMutablePointer<Int16>, frames: Int32, loopStart: Int32, loopLength: Int32, loopType: Int) {
        data = sample
        length = frames
        self.loopType = loopType
        if loopType == 0 {
            loopFirst = 0
            loopLast = -1
        } else {
            loopFirst = loopStart
            loopLast = loopStart &+ loopLength &- 1
        }
        reversed = false
        position = 0
        direction = Self.forwards
        regenerate()
        step = 65536
        at = 0
        flushed = true
        for i in 0 ..< 8 { buffer.pointer[i] = 0 }
        for i in 0 ..< 64 { delays.pointer[i] = 0 }
        delayLeft = 0
        delayRight = 0
    }

    private func regenerate() {
        if loopType == 0 {
            hasFirst = false
            hasSecond = false
        } else if loopType == 1 {
            if reversed {
                first = TurnPoint(position: loopFirst, jump: loopLast &- loopFirst &+ 1, meets: Self.backwards, leaves: Self.backwards, count: 0x7FFF_FFFF)
            } else {
                first = TurnPoint(position: loopLast &+ 1, jump: loopFirst &- loopLast &- 1, meets: Self.forwards, leaves: Self.forwards, count: 0x7FFF_FFFF)
            }
            hasFirst = true
            hasSecond = false
        } else {
            first = TurnPoint(position: loopFirst, jump: 0, meets: Self.backwards, leaves: Self.forwards, count: 0x7FFF_FFFF)
            second = TurnPoint(position: loopLast &+ 1, jump: 0, meets: Self.forwards, leaves: Self.backwards, count: 0x7FFF_FFFF)
            hasFirst = true
            hasSecond = true
        }
    }

    /// A note struck: what is in hand is thrown away, and the sample starts from so far in, from its
    /// end if it is to be played backwards.
    func trigger(backwards: Bool, offset: Int32) {
        flushed = true
        for i in 0 ..< 64 { delays.pointer[i] = 0 }
        reversed = backwards
        direction = backwards ? Self.backwards : Self.forwards
        regenerate()
        position = backwards ? length &- offset : offset
        if position > length {
            position = length
        } else if position < 0 {
            position = 0
        }
    }

    /// Where it is put between the speakers, from -128 to 128.
    func setPanning(_ panning: Int32) {
        delayLeft = 0
        delayRight = 0
        // (A file can say more than DigiBooster can; the replayer would read past its table.)
        if panning < 0 {
            delayRight = Int(phases[Int(min(128, -Int(panning))) - 1])
        } else if panning > 0 {
            delayLeft = Int(phases[Int(min(128, Int(panning))) - 1])
        }
    }

    /// So many of the sample's own samples, from where it is. False if it came to its end.
    private func unroll(_ dest: UnsafeMutablePointer<Int16>, _ count: Int) -> Bool {
        var staysOn = true
        var samples = count
        var out = dest
        while samples > 0 {
            var chunk = samples
            var execute = 0
            var padding = 0
            if direction == Self.forwards {
                if hasFirst, first.meets == Self.forwards, first.position >= position, Int(first.position) < Int(position) + chunk {
                    execute = 1
                    chunk = Int(first.position - position)
                }
                if hasSecond, second.meets == Self.forwards, second.position >= position, Int(second.position) < Int(position) + chunk {
                    execute = 2
                    chunk = Int(second.position - position)
                }
                padding = Int(position) + chunk - Int(length)
                if padding > 0 {
                    staysOn = false
                    chunk -= padding
                }
                if chunk > 0 {
                    let from = data + Int(position)
                    for i in 0 ..< chunk { out[i] = from[i] }
                    out += chunk
                }
                if padding > 0 {
                    for i in 0 ..< padding { out[i] = 0 }
                    out += padding
                }
                position = Int32(Int(position) + chunk)
            } else {
                if hasFirst, first.meets == Self.backwards, Int(first.position) > Int(position) - chunk, first.position <= position {
                    execute = 1
                    chunk = Int(position - first.position)
                }
                if hasSecond, second.meets == Self.backwards, Int(second.position) > Int(position) - chunk, second.position <= position {
                    execute = 2
                    chunk = Int(position - second.position)
                }
                padding = chunk - Int(position)
                if padding > 0 {
                    staysOn = false
                    chunk -= padding
                }
                if chunk > 0 {
                    let from = data + Int(position)
                    for i in 0 ..< chunk { out[i] = from[-1 - i] }
                    out += chunk
                }
                if padding > 0 {
                    for i in 0 ..< padding { out[i] = 0 }
                    out += padding
                }
                position = Int32(Int(position) - chunk)
            }
            samples -= chunk
            if padding > 0 { samples -= padding }
            if execute == 1, first.count > 0 {
                position = position &+ first.jump
                direction = first.leaves
                first.count -= 1
            } else if execute == 2, second.count > 0 {
                position = position &+ second.jump
                direction = second.leaves
                second.count -= 1
            }
        }
        return staysOn
    }

    /// So many samples at the output's rate. False if the sample came to its end while they were made.
    private func resample(_ dest: UnsafeMutablePointer<Int16>, _ count: Int) -> Bool {
        var leaveActive = true
        let buffer = buffer.pointer
        for i in 0 ..< count {
            if flushed {
                for k in 0 ..< 8 { buffer[k] = 0 }
                leaveActive = unroll(buffer + 8, 1016)
                at = 0
                flushed = false
            }
            // (Once for any step a note can have; more only where the replayer would read on past
            // what it has in hand.)
            while at >= 1008 << 16 {
                for k in 0 ..< 16 { buffer[k] = buffer[1008 + k] }
                leaveActive = unroll(buffer + 16, 1008)
                at -= 1008 << 16
            }
            let index = Int(at >> 16) + 8
            let s0 = Int32(buffer[index]), s1 = Int32(buffer[index + 1])
            let dy = Int32(bitPattern: UInt32(bitPattern: s1 &- s0) &* (at & 0xFFFF))
            dest[i] = Int16(truncatingIfNeeded: s0 &+ (dy >> 16))
            at &+= step
        }
        return leaveActive
    }

    /// So many frames of the instrument's sound, left and right in turn. False if it came to its end
    /// while the last part of them was made.
    func pull(_ dest: UnsafeMutablePointer<Int16>, _ frames: Int) -> Bool {
        var leaveActive = true
        var left = frames
        var out = dest
        let delays = delays.pointer
        while left > 0 {
            let chunk = min(left, 1024)
            leaveActive = resample(delays + 64, chunk)
            for i in 0 ..< chunk {
                out[i * 2] = delays[i + 64 - delayLeft]
                out[i * 2 + 1] = delays[i + 64 - delayRight]
            }
            for i in 0 ..< 64 { delays[i] = delays[chunk + i] }
            out += chunk * 2
            left -= chunk
        }
        return leaveActive
    }

    /// How many samples each side is put off by for each place from 1 to 128 to the side: a curve,
    /// to a third of a millisecond at the most.
    static func phaseTable(rate: Int) -> [Int16] {
        let most = rate * 333 / 1_000_000
        return (1 ... 128).map { Int16(($0 * $0 * most) >> 14) }
    }
}

/// A track's echo, as DigiBooster 3 has it, which is AHI's: what has been heard comes back after a
/// delay, some of it fed round again, some of it crossed to the other side. It comes after the
/// instrument and before the track's volume, and goes on sounding when the note is done.
final class DBMEcho {
    /// 1 for the echo the whole module shares the settings of, 2 for one of the track's own.
    let type: Int
    private let line: Memory<Int16>
    private let size: Int
    private var writeAt = 0
    private let rate: Int32
    private var delay: Int
    private var wet: Int32 = 128, dry: Int32 = 128
    private var crossBack: Int32 = 32640, crossFresh: Int32 = 32640, straightBack: Int32 = 128, straightFresh: Int32 = 128
    private var held = [Int16](repeating: 0, count: 32)

    init(rate: Int, type: Int) {
        self.type = type
        self.rate = Int32(rate)
        // (Half a second and a little more, which is more than the longest delay.)
        size = ((rate >> 1) + (rate >> 6) + 3) & ~4
        line = Memory<Int16>(capacity: size * 2)
        for i in 0 ..< size * 2 { line.pointer[i] = 0 }
        delay = (64 * rate + 250) / 500
    }

    /// The delay in units of two milliseconds, and how much is fed back, mixed in and crossed over,
    /// each from 0 to 255.
    func set(delay: Int32, feedback: Int32, mix: Int32, cross: Int32) {
        self.delay = Int((delay &* rate &+ 250) / 500)
        wet = mix
        dry = 256 - mix
        crossBack = cross &* feedback
        crossFresh = cross &* (256 - feedback)
        straightBack = (cross &- 256) &* feedback
        straightFresh = (cross &- 256) &* (feedback &- 256)
    }

    /// So many frames of the track's sound with its echo, from what the voice makes.
    func pull(_ dest: UnsafeMutablePointer<Int16>, _ frames: Int, from voice: DBMVoice?) {
        var left = frames
        var out = dest
        let line = line.pointer
        held.withUnsafeMutableBufferPointer { b in
            let b = b.baseAddress!
            while left > 0 {
                let chunk = min(16, left)
                if let voice {
                    _ = voice.pull(b, chunk)
                } else {
                    for i in 0 ..< chunk * 2 { b[i] = 0 }
                }
                for i in 0 ..< chunk {
                    var readAt = writeAt - delay
                    if readAt < 0 { readAt += size }
                    let l = Int32(b[i * 2]), r = Int32(b[i * 2 + 1])
                    let lDelayed = Int32(line[readAt * 2]), rDelayed = Int32(line[readAt * 2 + 1])
                    let al = l &* straightFresh &+ r &* crossFresh &+ lDelayed &* straightBack &+ rDelayed &* crossBack
                    let ar = r &* straightFresh &+ l &* crossFresh &+ rDelayed &* straightBack &+ lDelayed &* crossBack
                    line[writeAt * 2] = Int16(truncatingIfNeeded: al >> 16)
                    line[writeAt * 2 + 1] = Int16(truncatingIfNeeded: ar >> 16)
                    writeAt += 1
                    if writeAt == size { writeAt = 0 }
                    out[i * 2] = Int16(truncatingIfNeeded: (l &* dry &+ lDelayed &* wet) >> 8)
                    out[i * 2 + 1] = Int16(truncatingIfNeeded: (r &* dry &+ rDelayed &* wet) >> 8)
                }
                out += chunk * 2
                left -= chunk
            }
        }
    }
}
