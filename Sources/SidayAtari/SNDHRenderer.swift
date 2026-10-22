// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from AtariAudio, Copyright (c) Arnaud Carré, used under the MIT licence (see THIRD-PARTY.md).

import SidayFoundation

/// The clock of the Atari STE's processor, which sets how long a frame of its screen lasts, and so
/// how often a tune that plays once a frame is called.
public let atariSTCPUHz = 8_021_247

/// Plays SNDH files, the music of the Atari ST, on the emulated machine.
public final class SNDHRenderer: Renderer {
    private let file: SNDHFile
    private let machine: STMachine
    /// Samples of output between one call of the tune's player and the next.
    private let samplesPerTick: Int
    private var untilTick = 0
    /// False once the tune's code has failed to come back from a call: there is no more to hear.
    private var playing = false
    /// The machine's output is sixteen bits wide and uses most of them. This brings its tunes to the
    /// level the same chip's tunes have on the other machines here, measured as an average over a
    /// hundred or so of each.
    private let gain: Float = 0.37 / 32768.0

    public private(set) var info: TuneInfo
    public private(set) var currentSubsong = 0
    public var subsongCount: Int { file.songs }
    public var defaultSubsong: Int { file.firstSong - 1 }
    public var hasEnded: Bool { !playing }

    public var knownLength: Double? { length(of: currentSubsong) }

    public var songs: [SongInfo] {
        (0 ..< subsongCount).map { SongInfo(length: length(of: $0)) }
    }

    private func length(of song: Int) -> Double? {
        guard song < file.ticks.count else { return nil }
        if file.ticks[song] > 0 { return Double(file.ticks[song]) * Double(samplesPerTick) / Double(outputSampleRate) }
        return file.seconds[song] > 0 ? Double(file.seconds[song]) : nil
    }

    public init(_ data: [UInt8], options _: LoadOptions = LoadOptions()) throws {
        file = try SNDHFile(data)
        guard Int(STMachine.loadAddress) + file.image.count <= STMachine.ramSize else {
            throw TuneError.unsupported("too big for the machine's memory")
        }
        // A frame of the screen is 313 lines of 512 cycles: that is the fiftieth of a second a tune means.
        // (Worked out in sixty-four bits: the numbers are too big for a 32-bit machine's own.)
        samplesPerTick = max(1, Int(Int64(outputSampleRate) * 313 * 512 * 50 / (Int64(file.tickRate) * Int64(atariSTCPUHz))))
        machine = STMachine(hostRate: outputSampleRate)

        var info = TuneInfo(format: "SNDH")
        info.title = file.title
        info.author = file.composer
        var detail = [file.year, "Atari ST"].filter { !$0.isEmpty }
        if file.tickRate != 50 { detail.append("\(file.tickRate) Hz") }
        info.detail = detail.joined(separator: ", ")
        self.info = info

        select(subsong: defaultSubsong)
        guard playing else { throw TuneError.unsupported("the tune's player does not start") }
    }

    public func select(subsong: Int) {
        currentSubsong = min(max(0, subsong), subsongCount - 1)
        untilTick = 0
        // The song is asked for by number, counted from 1, at the first of the file's three ways in.
        playing = machine.start(file.image) && machine.call(STMachine.loadAddress, d0: UInt32(currentSubsong + 1))
    }

    public func setMuted(_ muted: [Bool]) {
        machine.setMuted(muted)
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if playing, untilTick == 0 {
                // The third way in plays one tick.
                playing = machine.tick(STMachine.loadAddress + 8)
                untilTick = samplesPerTick
            }
            guard playing else {
                (buffer + done * 2).update(repeating: 0, count: (frames - done) * 2)
                if let waves {
                    for voice in 0 ..< 4 { waves.silence(voice, count: frames - done) }
                    waves.advance(by: frames - done)
                }
                return
            }
            let count = min(untilTick, frames - done)
            if let waves {
                make(count, into: buffer + done * 2, keeping: waves)
            } else {
                for frame in done ..< done + count {
                    let sample = machine.nextFiltered() * gain
                    buffer[frame * 2] = sample
                    buffer[frame * 2 + 1] = sample
                }
            }
            done += count
            untilTick -= count
        }
    }

    /// So many samples, keeping the voices' sound in `waves` as they are made: kept out of `render`,
    /// so that the loop it runs when they are not kept is as it was.
    @inline(never) private func make(_ count: Int, into buffer: UnsafeMutablePointer<Float>, keeping waves: ChannelWaves) {
        for frame in 0 ..< count {
            let sample = machine.nextFiltered(keeping: waves) * gain
            buffer[frame * 2] = sample
            buffer[frame * 2 + 1] = sample
        }
    }

    /// Where each voice's sound is kept for its scope, once asked: the machine keeps it as it makes
    /// each sample. The machine is the same one from one song to the next, and so is this.
    private var waves: ChannelWaves?

    public func keepChannelWaves() -> ChannelWaves? {
        if waves == nil { waves = machine.makeWaves() }
        return waves
    }

    /// The sound chip's three channels, and the samples an STE can play beside them.
    public var channelCount: Int { 4 }
    public var channelsAlwaysShown: Int { 3 }

    /// The chip's three make their own sound; the fourth is the STE's samples.
    public func takeChannelsSampled(into sampled: UnsafeMutablePointer<Bool>) {
        for voice in 0 ..< 4 { sampled[voice] = voice == 3 }
    }

    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        machine.takeLevels(into: levels)
    }

    public func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        machine.takeNotes(pitches: pitches, struck: struck)
    }

    /// The machine's output as it comes, for the next `frames` samples: for comparing with other players.
    public func renderRaw(frames: Int) -> [Int16] {
        var output: [Int16] = []
        output.reserveCapacity(frames)
        while output.count < frames {
            if playing, untilTick == 0 {
                playing = machine.tick(STMachine.loadAddress + 8)
                untilTick = samplesPerTick
            }
            guard playing else { break }
            let count = min(untilTick, frames - output.count)
            for _ in 0 ..< count { output.append(machine.nextSample()) }
            untilTick -= count
        }
        return output
    }
}
