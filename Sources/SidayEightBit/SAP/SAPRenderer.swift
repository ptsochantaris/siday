// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ASAP (Another Slight Atari Player), Copyright (C) 2010-2026 Piotr Fusik, used under
// the GNU General Public License, version 2 or later (see THIRD-PARTY.md).

import SidayFoundation

/// Plays SAP files, the music of the 8-bit Ataris, on the emulated machine.
public final class SAPRenderer: Renderer, ReferenceComparable {
    private let file: SAPFile
    private let machine: SAPMachine
    /// False once a song's code has failed to come back from being started: there is no more to hear.
    private var playing = false
    private var made: UnsafeMutablePointer<Int16>
    private var madeCapacity = 0
    /// The machine's output is sixteen bits wide, and its tunes as ASAP makes them about 7 dB louder
    /// than the others here: this brings them to the same level, by the middle of two hundred.
    private let gain: Float = 0.46 / 32768.0

    public private(set) var info: TuneInfo
    public private(set) var currentSubsong = 0
    public var subsongCount: Int { file.songs }
    public var defaultSubsong: Int { file.defaultSong }
    public var hasEnded: Bool { !playing }
    public var knownLength: Double? { length(of: currentSubsong) }

    public var songs: [SongInfo] {
        (0 ..< subsongCount).map { SongInfo(length: length(of: $0)) }
    }

    private func length(of song: Int) -> Double? {
        guard song < file.durations.count, let milliseconds = file.durations[song], milliseconds > 0 else { return nil }
        return Double(milliseconds) / 1000
    }

    /// True if the two POKEYs of a stereo tune are to be heard together.
    private let mono: Bool
    /// How much of the difference between the two sides of a stereo tune is kept: from 0, none, to
    /// 1/2, all of it, each POKEY on its own side as the stereo upgrade had them.
    private let side: Float

    public init(_ data: [UInt8], options: LoadOptions = LoadOptions()) throws {
        file = try SAPFile(data)
        mono = options.stereo == .mono
        side = Float(max(0, min(1, options.sbProSeparation))) * 0.5
        machine = SAPMachine(file, sampleRate: outputSampleRate)
        madeCapacity = 4096
        made = .allocate(capacity: madeCapacity * 2)

        var info = TuneInfo(format: "SAP")
        info.title = file.title
        info.author = file.author
        var detail = [file.date, file.ntsc ? "Atari 8-bit, NTSC" : "Atari 8-bit"].filter { !$0.isEmpty }
        if file.stereo { detail.append("two POKEYs") }
        let lines = file.ntsc ? 262 : 312
        if file.fastplay != lines, file.kind != .d || file.player >= 0 {
            let rate = (file.ntsc ? 1_789_772.0 : 1_773_447.0) / Double(114 * file.fastplay)
            detail.append("\(Int(rate.rounded())) Hz")
        }
        info.detail = detail.joined(separator: ", ")
        self.info = info

        select(subsong: defaultSubsong)
        guard playing else { throw TuneError.unsupported("the tune's code does not come back from being started") }
    }

    deinit {
        made.deallocate()
    }

    public func select(subsong: Int) {
        currentSubsong = min(max(0, subsong), subsongCount - 1)
        playing = (try? machine.start(song: currentSubsong)) ?? false
        lightMoves = 0
        noteMoves = 0
        framesOfMoves = 0
        speakerWasSounding = false
    }

    private func make(_ frames: Int) {
        if frames > madeCapacity {
            made.deallocate()
            madeCapacity = frames
            made = .allocate(capacity: madeCapacity * 2)
        }
        machine.generate(into: made, blocks: frames)
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        guard playing else {
            buffer.update(repeating: 0, count: frames * 2)
            if let waves {
                for voice in 0 ..< channelCount { waves.silence(voice, count: frames) }
                waves.advance(by: frames)
            }
            return
        }
        make(frames)
        framesOfMoves += frames
        if file.stereo, mono {
            for i in 0 ..< frames {
                let sample = (Float(made[i * 2]) + Float(made[i * 2 + 1])) * 0.5 * gain
                buffer[i * 2] = sample
                buffer[i * 2 + 1] = sample
            }
        } else if file.stereo {
            // (Brought nearer together, as far as the listener asks.)
            for i in 0 ..< frames {
                let l = Float(made[i * 2]) * gain, r = Float(made[i * 2 + 1]) * gain
                let middle = (l + r) * 0.5, apart = (l - r) * side
                buffer[i * 2] = middle + apart
                buffer[i * 2 + 1] = middle - apart
            }
        } else {
            for i in 0 ..< frames {
                let sample = Float(made[i]) * gain
                buffer[i * 2] = sample
                buffer[i * 2 + 1] = sample
            }
        }
    }

    /// The machine's output as it comes, one sample a POKEY, for the next `frames` samples: for
    /// comparing with ASAP.
    public func renderRaw(frames: Int) -> [Int16] {
        guard playing else { return [] }
        let width = file.stereo ? 2 : 1
        var output = [Int16](repeating: 0, count: frames * width)
        output.withUnsafeMutableBufferPointer { machine.generate(into: $0.baseAddress!, blocks: frames) }
        return output
    }

    // MARK: Voices

    /// A POKEY's four channels, or two POKEYs' eight; and the console's one-bit loudspeaker, which
    /// some tunes play on beside them or, as a ZX Spectrum's beeper is played, alone. That is shown
    /// once it is heard.
    public var channelCount: Int { speaker + 1 }
    public var channelsAlwaysShown: Int { speaker }
    public var speakerChannel: Int? { speaker }
    private var speaker: Int { file.stereo ? 8 : 4 }

    /// How often the loudspeaker has gone in or out, for its light and its pitch, and over how long.
    private var lightMoves = 0, noteMoves = 0, framesOfMoves = 0
    private var speakerWasSounding = false

    private func takeSpeakerMoves() {
        let moves = machine.pokeys.base.takeSpeakerMoves()
        lightMoves += moves
        noteMoves += moves
    }

    public func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        machine.pokeys.base.takeLevels(into: levels)
        if file.stereo { machine.pokeys.extra.takeLevels(into: levels + 4) }
        // The loudspeaker is in or out, with nothing between: it is sounding if it is moving.
        takeSpeakerMoves()
        levels[speaker] = lightMoves > 1 ? 1 : lightMoves == 1 ? 0.5 : 0
        lightMoves = 0
    }

    public func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        machine.pokeys.base.takeStruck(into: struck)
        if file.stereo { machine.pokeys.extra.takeStruck(into: struck + 4) }
        for voice in 0 ..< speaker {
            let pokey = voice < 4 ? machine.pokeys.base : machine.pokeys.extra
            pitches[voice] = ChannelPitch.note(ofHz: pokey.pitch(of: voice & 3, clock: machine.clock))
        }
        // A loudspeaker that goes in and out so many times a second is a tone of half as many cycles.
        takeSpeakerMoves()
        let sounding = noteMoves >= 4 && framesOfMoves > 0
        pitches[speaker] = sounding ? ChannelPitch.note(ofHz: Double(noteMoves) * 0.5 * Double(outputSampleRate) / Double(framesOfMoves)) : 0
        struck[speaker] = sounding && !speakerWasSounding
        speakerWasSounding = sounding
        noteMoves = 0
        framesOfMoves = 0
    }

    /// A stereo tune's POKEYs are each on its own side, however near they are brought to one another.
    public func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        for voice in 0 ..< channelCount { sides[voice] = file.stereo && voice < speaker ? voice < 4 ? -1 : 1 : 0 }
    }

    public func takeChannelsSampled(into sampled: UnsafeMutablePointer<Bool>) {
        for voice in 0 ..< speaker {
            sampled[voice] = (voice < 4 ? machine.pokeys.base : machine.pokeys.extra).isSampled(voice & 3)
        }
        sampled[speaker] = false
    }

    /// Where each voice's sound is kept for its scope, once asked: each channel's level, from nought to
    /// fifteen, and the loudspeaker, in or out. The machine is the same from one song to the next, and
    /// so is this.
    private var waves: ChannelWaves?

    public func keepChannelWaves() -> ChannelWaves? {
        if waves == nil {
            let waves = ChannelWaves(voices: channelCount, rate: Double(outputSampleRate), fullSwing: 7.5)
            waves.setVoice(speaker, rate: Double(outputSampleRate), fullSwing: 0.5)
            machine.keepVoices(in: waves)
            self.waves = waves
        }
        return waves
    }

    public func setMuted(_ muted: [Bool]) {
        var mask = 0
        for (voice, out) in muted.enumerated() where out && voice < speaker { mask |= 1 << voice }
        machine.pokeys.base.leaveOut(mask & 0xF)
        machine.pokeys.extra.leaveOut(mask >> 4)
        machine.speakerLeftOut = speaker < muted.count && muted[speaker]
    }
}
