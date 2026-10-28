// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayCodecs
import SidayFoundation
import SidayMIDI
import SidaySC55

/// Plays a MIDI file on a Roland SC-55, the first Sound Canvas (`SC55Synth`, a port of Nuked SC-55), given its
/// ROMs: a file written for General MIDI or for GS as composed for it; one written for Yamaha XG as a GS
/// synthesiser played it, as General MIDI; and one written for the MT-32, when siday has no MT-32's ROMs, as
/// an SC-55's owner played it, the SC-55 set to its MT-32 sounds as Mark Fontana's SCMODE set it.
///
/// The SC-55 is a controller running its firmware, which takes MIDI at its serial port, and the PCM chip it
/// programs. Time is kept in the chip's frames, 64,000 a second: the sequencer's seconds are counted into
/// them, and the bytes of each message reach the serial port one after another as down a MIDI cable, ten bits
/// a byte at 31,250 a second, each at the frame it arrives by. The firmware is started first (a second of its
/// time) and the song is sent from then on. The chip's output is brought to 48,000 frames a second through
/// siday's windowed-sinc resampler, the one recordings are played through.
///
/// A voice here is one of the SC-55's sixteen parts. Which part each of the chip's 24 voices plays is read
/// from where the firmware keeps it (see `SC55Synth`), and a part's sound is its voices' added together
/// after their envelopes, before their pan and effects: its lamp, its scope, and what is taken out when it
/// is muted. Its pitch, its notes struck and its pan are those its MIDI channel is sent (part n is played by
/// channel n unless a file says otherwise, which few do).
final class MIDISC55Renderer: Renderer {
    private(set) var info: TuneInfo
    private(set) var knownLength: Double?
    private(set) var loopLength: Double?
    private(set) var hasEnded = false
    private(set) var currentSubsong = 0
    private(set) var songs: [SongInfo]

    private let file: MIDIFile
    private let prelude: [[UInt8]]
    /// When the first note of each song's music is struck (see `MIDISequencer.firstNotes`).
    private var firstNotes: [Double?] = []
    private let roms: SC55ROMSet
    private let mono: Bool
    /// True for a file written for the MT-32, played on the SC-55's MT-32 sounds (see `mt32Setup`).
    private let mt32Mode: Bool
    private var synth: SC55Synth
    private var sequencer: MIDISequencer
    private var receiver: Receiver

    static let rate = SC55Synth.sampleRate
    private static let granularity = 1.0 / Double(rate)
    /// No more than this long between the sequencer's looks at what is due.
    private static let maxDelay = 512.0 / Double(rate)
    private var delay = 0.0, carry = 0.0, eaten = 0.0
    /// The sequencer's time in the chip's frames, counted from when the firmware was started: the frame the
    /// messages it hands on now are sent at.
    private var now = 0
    /// The frame the song starts at: 0, or after the MT-32 setup.
    private var songStart = 0
    /// When the MIDI cable is next free, in 25ths of a frame (a byte takes 512 of them: 320 microseconds).
    private var cable = 0
    private static let byteTime = 512

    /// The chip's output, as floating point, kept for the resampler: `inputStart` is the frame of the first
    /// kept, and `inputCount` are kept.
    private var inputLeft: UnsafeMutablePointer<Float>
    private var inputRight: UnsafeMutablePointer<Float>
    private var inputStart = 0, inputCount = 0
    private static let inputCapacity = 8192
    private let block: UnsafeMutablePointer<Int32>
    static let blockFrames = 1024
    private let resampler = Resampler(from: rate, to: outputSampleRate)
    /// Output frames made, and the frame the song ends at once it is known.
    private var framesMade = 0
    private var endFrame: Int?
    /// Sound is faded over the last fifth of a second after the song's last message.
    private static let fadeLength = outputSampleRate / 5

    /// Set by measure, so that a MIDI file is about as loud on the SC-55 as on FM (see `MIDIFMRenderer.gain`):
    /// of sixty of the collection's, the first minute of the middle one is 4.5 dB quieter on the SC-55 at the
    /// level of its DAC (full scale at 1: the chip's 20-bit samples taken 16 bits at a time), and is raised
    /// by that much.
    static let gain: Float = 1.68

    init(_ data: [UInt8], companion: [UInt8]?, roms: SC55ROMSet, options: LoadOptions = LoadOptions()) throws {
        mono = options.stereo == .mono
        self.roms = roms
        file = try MIDIFile(data)
        guard file.tracks.contains(where: { track in track.events.contains { $0.kind == .noteOn } }) else {
            throw TuneError.malformed("a MIDI file with no notes")
        }
        let besides = companion.map { MIDIFile.messages(ofCompanion: $0) } ?? []
        let origin = MIDIOrigin(file, companion: besides)
        prelude = file.sendsSystemExclusive ? [] : besides
        mt32Mode = origin.standard == .mt32 && origin.mt32Messages > 0

        var info = TuneInfo(format: "MID")
        info.title = file.title
        info.comment = file.copyright
        info.chips = [.sc55]
        info.detail = (origin.declared ? "Written for " + origin.standard.name : "General MIDI")
            + "; played on the " + roms.name + (mt32Mode ? ", set to its MT-32 sounds" : "")
        info.shortfalls = file.shortfalls
        if origin.standard == .xg {
            info.shortfalls.append("It was written for Yamaha's XG, whose sounds and effects the Sound Canvas does not have: it is played as General MIDI, as a GS synthesiser played it.")
        }
        if mt32Mode {
            info.playedOtherwiseWith = [.mt32]
            info.shortfalls.append("It was written for the Roland MT-32, and the sounds it sets the MT-32 up with"
                + (origin.byCompanion ? " (in the file of them beside it)" : "")
                + " are not heard on the Sound Canvas: its parts are played with the Sound Canvas's own MT-32 sounds, as SCMODE set them up."
                + " Given the ROMs of a CM-32L or LAPC-I once (dropped on the player, or with --roms), siday keeps them and plays it on that synthesiser.")
        }
        self.info = info

        songs = file.songs.map { SongInfo(title: $0.title) }
        inputLeft = .allocate(capacity: Self.inputCapacity)
        inputRight = .allocate(capacity: Self.inputCapacity)
        block = .allocate(capacity: Self.blockFrames * 2)
        synth = SC55Synth(roms: roms)
        sequencer = MIDISequencer(file.songs[0], of: file, prelude: prelude)
        receiver = Receiver()
        firstNotes = MIDISequencer.firstNotes(of: data, prelude: prelude, granularity: Self.granularity)
        for index in songs.indices { songs[index].length = measure(index).length }
        select(subsong: 0)
    }

    deinit {
        inputLeft.deallocate()
        inputRight.deallocate()
        block.deallocate()
    }

    /// How long a song is as it is heard, as `MIDIFMRenderer` measures it, at the chip's granularity.
    private func measure(_ index: Int) -> (length: Double?, loop: Double?, unheard: Double) {
        let measured = MIDISequencer.measure(file.songs[index], of: file, prelude: prelude, granularity: Self.granularity)
        let unheard = MIDISequencer.unheardStart(firstNote: index < firstNotes.count ? firstNotes[index] : measured.firstNote)
        return (measured.length.map { $0 - unheard }, measured.loop, unheard)
    }

    /// Takes each message as the sequencer hands it on, for the renderer to send down the cable, and keeps
    /// what each channel is doing, for the parts' pitches, notes and sides.
    final class Receiver: MIDIReceiver {
        unowned(unsafe) var renderer: MIDISC55Renderer?
        /// The keys held on each channel, the notes struck since they were last taken, and the pans.
        var held = [[UInt8]](repeating: [], count: 16)
        var struck: UInt16 = 0
        var pans = [UInt8](repeating: 64, count: 16)

        func receive(_ event: MIDIEvent) {
            guard let renderer else { return }
            if event.kind == .systemExclusive {
                // (An escape, F7 and bytes, is no message of the Sound Canvas's.)
                guard event.bytes.first == 0xF0 else { return }
                renderer.send(event.bytes)
            } else if event.isChannelMessage {
                renderer.send(event.shortMessage)
                let channel = Int(event.channel & 15)
                switch event.kind {
                case .noteOn where event.data2 > 0:
                    held[channel].removeAll { $0 == event.data1 }
                    held[channel].append(event.data1)
                    struck |= 1 << UInt16(channel)
                case .noteOn, .noteOff:
                    held[channel].removeAll { $0 == event.data1 }
                case .controller where event.data1 == 120 || event.data1 == 123:
                    held[channel] = []
                case .controller where event.data1 == 10:
                    pans[channel] = event.data2
                default: break
                }
            }
        }

        /// The synthesiser is not told of the song's start: it is as the file's own messages leave it.
        func songBegins() {}
    }

    /// Sends a message down the cable, its bytes reaching the serial port one after another from `now`.
    func send(_ bytes: [UInt8]) {
        var time = max(now * 25, cable)
        for byte in bytes {
            synth.schedule([byte], at: time / 25)
            eventLog?(time / 25, byte)
            time += Self.byteTime
        }
        cable = time
    }

    var subsongCount: Int { songs.count }

    func select(subsong: Int) {
        currentSubsong = max(0, min(subsong, songs.count - 1))
        synth = SC55Synth(roms: roms)
        synth.start()
        synth.watchesParts = waves != nil || watchingLevels
        synth.setMutedParts(mutedParts)
        receiver = Receiver()
        receiver.renderer = self
        sequencer = MIDISequencer(file.songs[currentSubsong], of: file, prelude: prelude)
        let measured = measure(currentSubsong)
        knownLength = measured.length
        loopLength = measured.loop
        delay = 0
        carry = 0
        eaten = 0
        now = 0
        cable = 0
        inputStart = 0
        inputCount = 0
        framesMade = 0
        endFrame = nil
        hasEnded = false
        waves?.ahead = 0
        songStart = 0
        if mt32Mode {
            for message in Self.mt32Setup { send(message) }
            // The song starts half a second after the setup has crossed the cable.
            songStart = cable / 25 + Self.rate / 2
            now = songStart
        }
        unheardFrames = Int((Double(songStart) / Double(Self.rate) + measured.unheard) * Double(outputSampleRate))
        playUnheard(frames: unheardFrames)
    }

    /// The output frames played unheard at the last `select`: the setup before the song is heard.
    private(set) var unheardFrames = 0

    /// What Mark Fontana's SCMODE (1.0, 1992) sends to set a Sound Canvas to "MT-32 emulation mode", read in its
    /// code: a GS reset, and then to each of the channels 1 to 10, the MT-32's parts, bank 127 (the Sound
    /// Canvas's MT-32 sounds; bank 0 for channel 10), the MT-32's first program and pan for that part (program
    /// 127 on channel 10, the CM-64/CM-32L rhythm set), and a reverb send of 64.
    static let mt32Setup: [[UInt8]] = {
        var messages: [[UInt8]] = [[0xF0, 0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7F, 0x00, 0x41, 0xF7]]
        let programs: [UInt8] = [0x00, 0x44, 0x30, 0x5F, 0x4E, 0x29, 0x03, 0x6E, 0x7A, 0x7F]
        let pans: [UInt8] = [0x40, 0x36, 0x36, 0x36, 0x36, 0x12, 0x5B, 0x00, 0x7F, 0x40]
        for channel in 0 ..< 10 {
            let c = UInt8(channel)
            messages.append([0xB0 | c, 0x00, channel == 9 ? 0x00 : 0x7F])
            messages.append([0xC0 | c, programs[channel]])
            messages.append([0xB0 | c, 0x0A, pans[channel]])
            messages.append([0xB0 | c, 0x5B, 0x40])
        }
        return messages
    }()

    /// Plays the start of the song that is not heard: the setup, before the first note.
    private func playUnheard(frames total: Int) {
        var frames = total
        guard frames > 0 else { return }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 1024 * 2)
        defer { scratch.deallocate() }
        while frames > 0 {
            let count = min(frames, 1024)
            render(into: scratch, frames: count)
            frames -= count
        }
    }

    var endsByLooping: Bool { file.songs[currentSubsong].loopsForEver }
    var loopCount: Int { sequencer.loopCount }

    /// Plays the sequencer on until every message due before the chip's frame `frame` has been sent.
    private func sequence(until frame: Int) {
        while endFrame == nil, now < frame {
            delay = sequencer.tick(eaten, granularity: Self.granularity, to: receiver)
            if sequencer.atEnd {
                // A second after the last message, as the sequencer says, in output frames.
                let end = Double(now) + delay * Double(Self.rate)
                endFrame = Int(end * Double(outputSampleRate) / Double(Self.rate))
                return
            }
            let eat = min(delay, Self.maxDelay)
            carry += Double(Self.rate) * eat
            let frames = Int(carry)
            carry -= Double(frames)
            eaten = eat
            now += frames
        }
    }

    /// Has the chip make its next block of frames, and keeps them for the resampler.
    private func renderBlock() {
        let first = inputStart + inputCount
        sequence(until: first + Self.blockFrames)
        synth.render(into: block, frames: Self.blockFrames)
        rawLog?(block, Self.blockFrames)
        if inputCount + Self.blockFrames > Self.inputCapacity {
            // Only what the filter still needs is kept.
            let keep = Self.inputCapacity - Self.blockFrames
            let drop = inputCount - keep
            inputLeft.update(from: inputLeft + drop, count: keep)
            inputRight.update(from: inputRight + drop, count: keep)
            inputStart += drop
            inputCount = keep
        }
        // Full scale is the DAC's: the chip's 20-bit samples (shifted up 12 here) taken 16 bits at a time.
        let scale = Self.gain / Float(1 << 30)
        for i in 0 ..< Self.blockFrames {
            inputLeft[inputCount + i] = Float(block[i * 2]) * scale
            inputRight[inputCount + i] = Float(block[i * 2 + 1]) * scale
        }
        inputCount += Self.blockFrames
        if let waves {
            var made = 0
            synth.takePartSounds { part, rounds, samples in
                for i in 0 ..< rounds { waves.store(part, at: i, Float(samples[i * 16])) }
                made = rounds
            }
            waves.advance(by: made)
            waves.ahead += Self.blockFrames * outputSampleRate / Self.rate
        }
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        resampler.weights.withUnsafeBufferPointer { weights in
            render(into: buffer, frames: frames, weights: weights.baseAddress!)
        }
    }

    /// Each output frame is made from the chip's frames around its place, weighted by the resampler's row
    /// for that place (one of three: 64,000 to 48,000 is 4 to 3).
    private func render(into buffer: UnsafeMutablePointer<Float>, frames: Int, weights: UnsafePointer<Float>) {
        let taps = resampler.taps, width = 2 * taps
        let places = resampler.places, step = resampler.step
        for n in 0 ..< frames {
            if let endFrame, framesMade >= endFrame {
                hasEnded = true
                (buffer + n * 2).update(repeating: 0, count: (frames - n) * 2)
                keepSilence(frames: frames - n)
                return
            }
            let position = framesMade * step
            let base = position / places, row = position % places
            // The chip's frames from `taps - 1` before the output frame's place to `taps` after it (before the
            // first, silence).
            while inputStart + inputCount <= base + taps { renderBlock() }
            let rowWeights = weights + row * width
            let from = base - taps + 1 - inputStart
            let first = max(0, -from)
            var left: Float = 0, right: Float = 0
            for k in first ..< width {
                left += inputLeft[from + k] * rowWeights[k]
                right += inputRight[from + k] * rowWeights[k]
            }
            if let endFrame {
                let remaining = endFrame - framesMade
                if remaining < Self.fadeLength {
                    let level = Float(remaining) / Float(Self.fadeLength)
                    left *= level
                    right *= level
                }
            }
            if mono {
                buffer[n * 2] = (left + right) * 0.5
                buffer[n * 2 + 1] = (left + right) * 0.5
            } else {
                buffer[n * 2] = left
                buffer[n * 2 + 1] = right
            }
            framesMade += 1
            waves?.ahead -= 1
        }
    }

    // MARK: Checking

    /// Told of every byte sent to the serial port, with the chip's frame it arrives by (counted from when
    /// the firmware was started), from the next `select` on.
    var eventLog: ((Int, UInt8) -> Void)?
    /// Told of every block of the chip's own output, its 32-bit frames, before it is resampled: for comparing
    /// with Nuked SC-55's.
    var rawLog: ((UnsafePointer<Int32>, Int) -> Void)?

    // MARK: Voices

    var channelCount: Int { 16 }
    private var mutedParts = [Bool](repeating: false, count: 16)
    private var watchingLevels = false

    func setMuted(_ muted: [Bool]) {
        mutedParts = (0 ..< 16).map { $0 < muted.count && muted[$0] }
        synth.setMutedParts(mutedParts)
    }

    private var waves: ChannelWaves?

    func keepChannelWaves() -> ChannelWaves? {
        if waves == nil {
            waves = ChannelWaves(voices: 16, rate: Double(Self.rate / 2), fullSwing: 131_072)
            synth.watchesParts = true
        }
        return waves
    }

    private var silencePart = 0.0

    private func keepSilence(frames: Int) {
        guard let waves else { return }
        silencePart += Double(frames) * Double(Self.rate / 2) / Double(outputSampleRate)
        let count = Int(silencePart)
        silencePart -= Double(count)
        for part in 0 ..< 16 { waves.silence(part, count: count) }
        waves.advance(by: count)
    }

    func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        if !watchingLevels {
            watchingLevels = true
            synth.watchesParts = true
        }
        synth.takePartPeaks { part, peak in levels[part] = min(1, Float(peak) / Float(1 << 17)) }
    }

    func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        for part in 0 ..< 16 {
            // A part's pitch is its highest key not yet let go.
            pitches[part] = Float(receiver.held[part].max() ?? 0)
            struck[part] = receiver.struck & (1 << UInt16(part)) != 0
        }
        receiver.struck = 0
    }

    /// Where the part is: its channel's pan, 0 at the left to 127 at the right.
    func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        for part in 0 ..< 16 { sides[part] = (Float(receiver.pans[part]) - 64) / 64 }
    }

    func takeChannelsSampled(into sampled: UnsafeMutablePointer<Bool>) {
        for part in 0 ..< 16 { sampled[part] = true }
    }

    var channelsAreSampled: Bool { true }
}
