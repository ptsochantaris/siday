// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation
import SidayMIDI
import SidayMT32

/// Plays a MIDI file written for the MT-32 on the synthesiser of the MT-32's later kind, the LAPC-I's and
/// the CM-32L's (`MT32Synth`, a port of Munt's mt32emu), given its ROMs.
///
/// Time is kept in the synthesiser's own samples, 32,000 a second: the sequencer's seconds are counted
/// into them, and each message is handed to the synthesiser with the sample it reaches it at, which it
/// plays when its rendering comes to that sample. Its output, through the model of the LAPC-I's
/// analogue stage, is made at 48,000 samples a second, siday's own rate, so nothing is resampled.
///
/// A voice here is one of the synthesiser's nine parts, eight that each play one timbre and the rhythm
/// part, as the MT-32 has them and its front panel shows them: which MIDI channel plays which part is the
/// file's to set, and a part is one instrument from start to end.
final class MIDILA32Renderer: Renderer {
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
    private let roms: MT32ROMSet
    private let mono: Bool
    private var synth: MT32Synth
    private var sequencer: MIDISequencer
    private var receiver: Receiver

    private static let rate = MT32Synth.sampleRate
    private static let granularity = 1.0 / Double(rate)
    /// No more than this long between the sequencer's looks at what is due.
    private static let maxDelay = 512.0 / Double(rate)
    private var delay = 0.0, carry = 0.0, eaten = 0.0
    /// The sequencer's time in the synthesiser's samples: the sample the messages it hands on now reach
    /// the synthesiser at.
    private var now: UInt32 = 0
    /// Frames of output handed out, and the frame the song ends at once it is known.
    private var framesMade = 0
    /// Frames the synthesiser has made, and how many of its last block have been handed out.
    private var synthFrames = 0
    private var blockRead = MIDILA32Renderer.blockFrames
    private var endFrame: Int?
    /// Sound is faded over the last fifth of a second after the song's last message.
    private static let fadeLength = outputSampleRate / 5

    /// The output of the synthesiser, a block at a time.
    private let block: UnsafeMutablePointer<Int16>
    static let blockFrames = 1024

    /// Set by measure, so that the middle MT-32 file is about as loud as the middle of the other kinds
    /// (see `MIDIFMRenderer.gain`).
    static let gain: Float = 1.0

    init(_ data: [UInt8], companion: [UInt8]?, roms: MT32ROMSet, options: LoadOptions = LoadOptions()) throws {
        mono = options.stereo == .mono
        self.roms = roms
        file = try MIDIFile(data)
        guard file.tracks.contains(where: { track in track.events.contains { $0.kind == .noteOn } }) else {
            throw TuneError.malformed("a MIDI file with no notes")
        }
        let besides = companion.map { MIDIFile.messages(ofCompanion: $0) } ?? []
        let origin = MIDIOrigin(file, companion: besides)
        prelude = file.sendsSystemExclusive ? [] : besides

        var info = TuneInfo(format: "MID")
        info.title = file.title
        info.comment = file.copyright
        info.chips = [.la32]
        info.detail = (origin.declared ? "Written for " + origin.standard.name : "General MIDI (the file does not say otherwise)")
            + "; played on the LA32 synthesiser of the LAPC-I (" + roms.control.name + ")"
        info.shortfalls = file.shortfalls
        self.info = info

        songs = file.songs.map { SongInfo(title: $0.title) }
        block = .allocate(capacity: Self.blockFrames * 2)
        synth = MT32Synth(roms: roms)
        sequencer = MIDISequencer(file.songs[0], of: file, prelude: prelude)
        receiver = Receiver()
        firstNotes = MIDISequencer.firstNotes(of: data, prelude: prelude, granularity: Self.granularity)
        for index in songs.indices { songs[index].length = measure(index).length }
        select(subsong: 0)
    }

    deinit { block.deallocate() }

    /// How long a song is as it is heard, as `MIDIFMRenderer` measures it, at the synthesiser's
    /// granularity.
    private func measure(_ index: Int) -> (length: Double?, loop: Double?, unheard: Double) {
        let measured = MIDISequencer.measure(file.songs[index], of: file, prelude: prelude, granularity: Self.granularity)
        let unheard = MIDISequencer.unheardStart(firstNote: index < firstNotes.count ? firstNotes[index] : measured.firstNote)
        return (measured.length.map { $0 - unheard }, measured.loop, unheard)
    }

    /// Hands each message to the synthesiser, at the sample it is due.
    final class Receiver: MIDIReceiver {
        unowned(unsafe) var synth: MT32Synth?
        var now: UInt32 = 0
        /// Told of every message as it is handed on, with its sample: for comparing with Munt.
        var log: ((UInt32, [UInt8]) -> Void)?

        func receive(_ event: MIDIEvent) {
            guard let synth else { return }
            if event.kind == .systemExclusive {
                // (An escape, F7 and bytes, is no message of the MT-32's.)
                guard event.bytes.first == 0xF0 else { return }
                log?(now, event.bytes)
                synth.playSysex(event.bytes, at: now)
            } else if event.isChannelMessage {
                let bytes = event.shortMessage
                log?(now, bytes)
                var message = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                if bytes.count > 2 { message |= UInt32(bytes[2]) << 16 }
                synth.playMessage(message, at: now)
            }
        }

        /// The synthesiser is not told of the song's start: it is as the file's own messages leave it.
        func songBegins() {}
    }

    var subsongCount: Int { songs.count }

    func select(subsong: Int) {
        currentSubsong = max(0, min(subsong, songs.count - 1))
        synth = MT32Synth(roms: roms)
        synth.setMutedParts(mutedParts)
        synth.keepsPartSamples = waves != nil
        receiver = Receiver()
        receiver.synth = synth
        receiver.log = eventLog
        sequencer = MIDISequencer(file.songs[currentSubsong], of: file, prelude: prelude)
        let measured = measure(currentSubsong)
        knownLength = measured.length
        loopLength = measured.loop
        delay = 0
        carry = 0
        eaten = 0
        now = 0
        framesMade = 0
        synthFrames = 0
        blockRead = Self.blockFrames
        endFrame = nil
        hasEnded = false
        waves?.ahead = 0
        playUnheard(seconds: measured.unheard)
    }

    /// Plays the start of the song that is not heard: the synthesiser's setup, before the first note.
    /// (Its blocks are rendered as ever, so what is heard is the same as Munt's from there on.)
    private func playUnheard(seconds: Double) {
        var frames = Int(seconds * Double(outputSampleRate))
        guard frames > 0 else { return }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.blockFrames * 2)
        defer { scratch.deallocate() }
        while frames > 0 {
            let count = min(frames, Self.blockFrames)
            render(into: scratch, frames: count)
            frames -= count
        }
    }

    var endsByLooping: Bool { file.songs[currentSubsong].loopsForEver }
    var loopCount: Int { sequencer.loopCount }

    /// Plays the sequencer on until every message due before the synthesiser's sample `sample` has been
    /// handed to it.
    private func sequence(until sample: UInt32) {
        while endFrame == nil, Int32(bitPattern: now &- sample) < 0 {
            receiver.now = now
            delay = sequencer.tick(eaten, granularity: Self.granularity, to: receiver)
            if sequencer.atEnd {
                // A second after the last message, as the sequencer says.
                endFrame = synthFrames + Int(Double(Int32(bitPattern: now &- synth.renderedSampleCount)) * Double(outputSampleRate) / Double(Self.rate)
                    + delay * Double(outputSampleRate))
                return
            }
            let eat = min(delay, Self.maxDelay)
            carry += Double(Self.rate) * eat
            let samples = Int(carry)
            carry -= Double(samples)
            eaten = eat
            now &+= UInt32(samples)
        }
    }

    /// Renders the next block of the synthesiser into `block`, keeping each part's sound for its scope.
    /// It is always rendered a block of the same length at a time, whatever it is asked for: the
    /// synthesiser draws random numbers for its partials in turn, a block at a time, so its sound depends
    /// on how much of it is made at once, and is the same every time only if that is.
    private func renderBlock() {
        sequence(until: synth.renderedSampleCount &+ UInt32(synth.inputCount(for: Self.blockFrames)))
        let before = synth.renderedSampleCount
        synth.render(into: block, frames: Self.blockFrames)
        synthFrames += Self.blockFrames
        blockRead = 0
        if let waves {
            let made = Int(synth.renderedSampleCount &- before)
            synth.takePartSamples(made) { part, samples in
                for i in 0 ..< made { waves.store(part, at: i, Float(samples[i])) }
            }
            waves.advance(by: made)
            waves.ahead += Self.blockFrames
        }
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if let endFrame, framesMade >= endFrame {
                hasEnded = true
                (buffer + done * 2).update(repeating: 0, count: (frames - done) * 2)
                keepSilence(frames: frames - done)
                return
            }
            if blockRead == Self.blockFrames { renderBlock() }
            var count = min(frames - done, Self.blockFrames - blockRead)
            if let endFrame { count = min(count, endFrame - framesMade) }
            if count <= 0 { continue }
            let out = buffer + done * 2
            let from = block + blockRead * 2
            for i in 0 ..< count {
                var level = Self.gain / 32768
                if let endFrame {
                    let remaining = endFrame - (framesMade + i)
                    if remaining < Self.fadeLength { level *= Float(remaining) / Float(Self.fadeLength) }
                }
                let left = Float(from[i * 2]) * level, right = Float(from[i * 2 + 1]) * level
                if mono {
                    out[i * 2] = (left + right) * 0.5
                    out[i * 2 + 1] = (left + right) * 0.5
                } else {
                    out[i * 2] = left
                    out[i * 2 + 1] = right
                }
            }
            blockRead += count
            framesMade += count
            waves?.ahead -= count
            done += count
        }
    }

    // MARK: Checking

    /// Told of every message handed to the synthesiser, with its sample, from the next `select` on.
    var eventLog: ((UInt32, [UInt8]) -> Void)?

    /// The synthesiser's own output, before it is turned to floating point and faded, to the song's end or
    /// `frames`: for comparing with Munt's, rendered a block at a time as it is.
    func renderRaw(frames: Int) -> [Int16] {
        var raw: [Int16] = []
        raw.reserveCapacity(frames * 2)
        while raw.count < frames * 2 {
            if let endFrame, framesMade >= endFrame { break }
            if blockRead == Self.blockFrames { renderBlock() }
            var count = min(frames - raw.count / 2, Self.blockFrames - blockRead)
            if let endFrame { count = min(count, endFrame - framesMade) }
            if count <= 0 { continue }
            raw.append(contentsOf: UnsafeBufferPointer(start: block + blockRead * 2, count: count * 2))
            blockRead += count
            framesMade += count
        }
        return raw
    }

    // MARK: Voices

    var channelCount: Int { 9 }
    private var mutedParts = [Bool](repeating: false, count: 9)

    func setMuted(_ muted: [Bool]) {
        mutedParts = (0 ..< 9).map { $0 < muted.count && muted[$0] }
        synth.setMutedParts(mutedParts)
    }

    private var waves: ChannelWaves?

    func keepChannelWaves() -> ChannelWaves? {
        if waves == nil {
            waves = ChannelWaves(voices: 9, rate: Double(Self.rate), fullSwing: 8192)
            synth.keepsPartSamples = true
        }
        return waves
    }

    private var silencePart = 0.0

    private func keepSilence(frames: Int) {
        guard let waves else { return }
        silencePart += Double(frames) * Double(Self.rate) / Double(outputSampleRate)
        let count = Int(silencePart)
        silencePart -= Double(count)
        for part in 0 ..< 9 { waves.silence(part, count: count) }
        waves.advance(by: count)
    }

    func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        synth.takePartLevels { part, peak in levels[part] = min(1, Float(peak) / 8192) }
    }

    func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        let starts = synth.takePartNoteStarts()
        for part in 0 ..< 9 {
            // A part's pitch is its highest key not yet let go.
            pitches[part] = Float(synth.highestKey(ofPart: part) ?? 0)
            struck[part] = starts & (1 << part) != 0
        }
    }

    /// Where the part is: the MT-32's pan, 0 to 14, from the right to the left. (The rhythm part's keys
    /// each have their own; it is shown in the middle.)
    func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        for part in 0 ..< 8 { sides[part] = Float(7 - synth.pan(ofPart: part)) / 7 }
        sides[8] = 0
    }

    func takeChannelsSampled(into sampled: UnsafeMutablePointer<Bool>) {
        for part in 0 ..< 9 { sampled[part] = synth.isPartPlayingPCM(part) }
    }
}

extension MT32Synth {
    func inputCount(for frames: Int) -> Int { analogInputCount(for: frames) }
}
