// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-3.0-or-later
//
// How the sequencer and the chip are kept in step is libADLMIDI's (adl_playFormat in src/adlmidi.cpp,
// Copyright (c) 2015-2026 Vitaly Novichkov, under the GNU General Public License, version 3 or any
// later version): see `ADLMIDISynth`.

import SidayChips
import SidayFoundation
import SidayMIDI

/// Plays a MIDI file on an OPL3, with libADLMIDI's General MIDI synthesiser (`ADLMIDISynth`) and The
/// Fat Man's instruments: the sound most heard of MIDI files on a PC with a Sound Blaster 16 and no
/// other synthesiser, as Windows 95 and 98 played them.
///
/// Time is kept as libADLMIDI keeps it: the chip makes the samples up to the moment the next event is
/// due (no more than 512 at a time), and then the events of that moment are played and the
/// synthesiser's vibrato and the like move on by the time that has passed.
///
/// A voice here is a MIDI channel, one of the sixteen parts a file is written in: the chip's eighteen
/// channels are taken by whichever notes need them, so it is the MIDI channels that stay one
/// instrument, one line of the music, from start to end. What is said of a voice is of the chip's
/// channels playing for it.
final class MIDIFMRenderer: Renderer {
    private(set) var info: TuneInfo
    private(set) var knownLength: Double?
    private(set) var loopLength: Double?
    private(set) var hasEnded = false
    private(set) var currentSubsong = 0

    private let file: MIDIFile
    private let prelude: [[UInt8]]
    /// When the first note of each song's music is struck (see `MIDISequencer.firstNotes`).
    private var firstNotes: [Double?] = []
    /// True for a tune heard in mono: the OPL3's two sides together.
    private let mono: Bool
    private let card = OPLCard()
    private var synth: ADLMIDISynth
    private var sequencer: MIDISequencer
    private(set) var songs: [SongInfo]

    /// libADLMIDI's timing, at the chip's rate.
    private static let rate = 49716
    private static let minDelay = 1.0 / Double(rate), maxDelay = 512.0 / Double(rate)
    private var delay = 0.0, carry = 0.0
    /// The time the samples now being made take, which passes for the sequencer once they are made.
    private var eaten = 0.0
    private var tickDue = true
    /// The chip's samples made so far.
    private var made = 0
    /// libADLMIDI's chip runs a sample behind what it gives out, the first it gives out being of none:
    /// so the chip's first sample is left unmade here, and every register is written after as many of
    /// the chip's samples as in libADLMIDI. True once it has been.
    private var behind = false
    /// Sound is faded over the last fifth of a second after the song's last message.
    private static let fadeLength = rate / 5

    /// Set by measure, so that the middle MIDI file is about as loud as the middle of the other kinds,
    /// by how loud they are heard (LUFS): of a hundred of the collection's, the middle one's first minute
    /// is as loud as the middle CMF tune's measured the same way (and CMF tunes are at the common level).
    /// A General MIDI file keeps many of the chip's eighteen channels sounding at once, and so needs
    /// less than the chip's usual gain (see `OPLTune.gain`).
    static let gain: Float = 1.0

    init(_ data: [UInt8], companion: [UInt8]?, options: LoadOptions = LoadOptions()) throws {
        mono = options.stereo == .mono
        file = try MIDIFile(data)
        // A file of no notes (one of system exclusive messages alone, to set a synthesiser up for the
        // songs beside it) has nothing to be heard.
        guard file.tracks.contains(where: { track in track.events.contains { $0.kind == .noteOn } }) else {
            throw TuneError.malformed("a MIDI file with no notes")
        }
        let besides = companion.map { MIDIFile.messages(ofCompanion: $0) } ?? []
        let origin = MIDIOrigin(file, companion: besides)
        // A file of messages beside the song is sent before it only if it sends none of its own.
        prelude = file.sendsSystemExclusive ? [] : besides

        var info = TuneInfo(format: "MID")
        info.title = file.title
        info.comment = file.copyright
        info.chips = [.opl3]
        info.detail = Self.detail(origin)
        info.shortfalls = file.shortfalls
        info.playedOtherwiseWith = [.sc55]
        if origin.standard == .mt32, origin.mt32Messages > 0 {
            info.playedOtherwiseWith = [.mt32, .sc55]
            info.shortfalls.append("It was written for the Roland MT-32, and the sounds it sets the MT-32 up with"
                + (origin.byCompanion ? " (in the file of them beside it)" : "")
                + " are not heard on FM: its parts are played with General MIDI's instruments of the same numbers."
                + " Given the ROMs of a CM-32L or LAPC-I once (dropped on the player, or with --roms), siday keeps them and plays it on that synthesiser;"
                + " given a Roland SC-55's, on the Sound Canvas's own MT-32 sounds.")
        } else {
            // (The Sound Canvas is siday's General MIDI synthesiser: on FM, any other file is played as
            // a Sound Blaster played it, and says where it would be heard as it was written.)
            let written = switch origin.standard {
            case .gs: "It was written for Roland's GS, the Sound Canvas's own, and is played on FM with General MIDI's instruments."
            case .xg: "It was written for Yamaha's XG, and is played on FM as General MIDI."
            default: "It is played on FM, as a Sound Blaster played General MIDI."
            }
            info.shortfalls.append(written
                + " Given the ROMs of a Roland SC-55 once (dropped on the player, or with --roms), siday keeps them and plays it on the Sound Canvas, the General MIDI synthesiser of its day.")
        }
        self.info = info

        songs = file.songs.map { SongInfo(title: $0.title) }
        synth = ADLMIDISynth(bank: .fatMan, card: card)
        sequencer = MIDISequencer(file.songs[0], of: file, prelude: prelude)
        firstNotes = MIDISequencer.firstNotes(of: data, prelude: prelude, granularity: Self.minDelay)
        for index in songs.indices { songs[index].length = measure(index).length }
        select(subsong: 0)
    }

    /// True for a file written for the MT-32, by its own messages or those of the file beside it, which sets
    /// the MT-32 up: one that the LAPC-I's synthesiser plays, when siday has its ROMs.
    static func isWrittenForMT32(_ data: [UInt8], companion: [UInt8]?) -> Bool {
        guard let file = try? MIDIFile(data) else { return false }
        let origin = MIDIOrigin(file, companion: companion.map { MIDIFile.messages(ofCompanion: $0) } ?? [])
        return origin.standard == .mt32 && origin.mt32Messages > 0
    }

    /// What is said of the tune: what it was written for, and what it is played on.
    static func detail(_ origin: MIDIOrigin) -> String {
        let written = origin.declared ? "Written for " + origin.standard.name : "General MIDI"
        return written + "; played on an OPL3 with The Fat Man's instruments, as Windows 9x played it"
    }

    /// How long a song is as it is heard, from a little before its first note (see
    /// `MIDISequencer.unheardStart`), with the length of its loop and how much of its start is unheard.
    private func measure(_ index: Int) -> (length: Double?, loop: Double?, unheard: Double) {
        let measured = MIDISequencer.measure(file.songs[index], of: file, prelude: prelude, granularity: Self.minDelay)
        let unheard = MIDISequencer.unheardStart(firstNote: index < firstNotes.count ? firstNotes[index] : measured.firstNote)
        return (measured.length.map { $0 - unheard }, measured.loop, unheard)
    }

    var subsongCount: Int { songs.count }

    func select(subsong: Int) {
        currentSubsong = max(0, min(subsong, songs.count - 1))
        card.reset()
        card.setMuted(mutedChannels)
        synth = ADLMIDISynth(bank: .fatMan, card: card)
        sequencer = MIDISequencer(file.songs[currentSubsong], of: file, prelude: prelude)
        let measured = measure(currentSubsong)
        knownLength = measured.length
        loopLength = measured.loop
        delay = 0
        carry = 0
        eaten = 0
        tickDue = true
        made = 0
        behind = false
        hasEnded = false
        lastLoopCount = 0
        playUnheard(seconds: measured.unheard)
    }

    /// Plays the start of the song that is not heard: the synthesiser's setup, before the first note.
    private func playUnheard(seconds: Double) {
        var frames = Int(seconds * Double(outputSampleRate))
        guard frames > 0 else { return }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 4096 * 2)
        defer { scratch.deallocate() }
        while frames > 0 {
            let count = min(frames, 4096)
            render(into: scratch, frames: count)
            frames -= count
        }
    }

    var endsByLooping: Bool { file.songs[currentSubsong].loopsForEver }
    var loopCount: Int { sequencer.loopCount }
    private var lastLoopCount = 0

    /// One step of libADLMIDI's playing loop: the events due are played, and the chip is given the
    /// samples to the next.
    private func step() {
        if tickDue {
            delay = sequencer.tick(eaten, granularity: Self.minDelay, to: synth)
            synth.tickIterators(eaten)
            tickDue = false
            updateVoices()
        }
        let eat = min(delay, Self.maxDelay)
        delay -= eat
        carry += Double(Self.rate) * eat
        let samples = Int(carry)
        carry -= Double(samples)
        if sequencer.atEnd, delay <= 0 {
            hasEnded = true
            return
        }
        eaten = eat
        tickDue = true
        card.samplesLeft = samples
        if !behind, samples > 0 {
            card.samplesLeft -= 1
            behind = true
        }
        made += card.samplesLeft
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            while card.samplesLeft == 0, !hasEnded { step() }
            if hasEnded {
                (buffer + done * 2).update(repeating: 0, count: (frames - done) * 2)
                keepSilence(frames: frames - done)
                return
            }
            // The last second, after the song's last message, is faded at its end.
            let fade = sequencer.atEnd ? Self.fadeLength : 0
            let after = sequencer.atEnd ? Int(delay * Double(Self.rate)) : 0
            let made = card.renderStereo(into: buffer + done * 2, frames: frames - done, gain: Self.gain, fade: fade, after: after)
            if mono {
                for i in done ..< done + made {
                    let both = (buffer[i * 2] + buffer[i * 2 + 1]) * 0.5
                    buffer[i * 2] = both
                    buffer[i * 2 + 1] = both
                }
            }
            done += made
        }
    }

    // MARK: Voices

    var channelCount: Int { 16 }

    /// Which MIDI channel each of the chip's channels is playing for, kept for the card's scopes.
    private let voiceOf: UnsafeMutablePointer<Int> = {
        let pointer = UnsafeMutablePointer<Int>.allocate(capacity: 18)
        pointer.initialize(repeating: -1, count: 18)
        return pointer
    }()
    private var mutedChannels: [Bool] = []
    private var mutedVoices = [Bool](repeating: false, count: 16)

    deinit { voiceOf.deallocate() }

    /// Brings what the card knows of the voices up to date with the notes the synthesiser has placed:
    /// the chip's channels left out are those playing for a voice left out.
    private func updateVoices() {
        var changed = false
        for channel in 0 ..< 18 {
            let owner = synth.chipChannelOwner[channel] & 15
            let voice = synth.chipChannelOwner[channel] < 0 ? -1 : owner
            if voiceOf[channel] != voice {
                voiceOf[channel] = voice
                changed = true
            }
        }
        if changed, mutedVoices.contains(true) { applyMutes() }
    }

    private func applyMutes() {
        mutedChannels = (0 ..< 18).map { voiceOf[$0] >= 0 && mutedVoices[voiceOf[$0]] }
        card.setMuted(mutedChannels)
    }

    func setMuted(_ muted: [Bool]) {
        mutedVoices = (0 ..< 16).map { $0 < muted.count && muted[$0] }
        applyMutes()
    }

    private var waves: ChannelWaves?
    private var silencePart = 0.0

    func keepChannelWaves() -> ChannelWaves? {
        if waves == nil {
            let waves = ChannelWaves(voices: 16, rate: card.rate, fullSwing: 4000)
            card.keepWaves(in: waves, first: 0, voices: 16, voiceOf: voiceOf)
            self.waves = waves
        }
        return waves
    }

    private func keepSilence(frames: Int) {
        guard let waves else { return }
        silencePart += Double(frames) * card.rate / Double(outputSampleRate)
        let count = Int(silencePart)
        silencePart -= Double(count)
        for voice in 0 ..< 16 {
            waves.silence(voice, count: count)
            waves.advance(voice, by: count)
        }
    }

    func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        var chip = [Float](repeating: 0, count: 18)
        chip.withUnsafeMutableBufferPointer { card.takeLevels(into: $0.baseAddress!, voices: 18) }
        for voice in 0 ..< 16 { levels[voice] = 0 }
        for channel in 0 ..< 18 where voiceOf[channel] >= 0 {
            levels[voiceOf[channel]] = max(levels[voiceOf[channel]], chip[channel])
        }
    }

    func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        var chipPitches = [Float](repeating: 0, count: 18)
        var chipStruck = [Bool](repeating: false, count: 18)
        chipPitches.withUnsafeMutableBufferPointer { p in
            chipStruck.withUnsafeMutableBufferPointer { s in card.takeNotes(pitches: p.baseAddress!, struck: s.baseAddress!, voices: 18) }
        }
        for voice in 0 ..< 16 {
            pitches[voice] = 0
            struck[voice] = synth.struckChannels & (1 << UInt32(voice)) != 0
        }
        synth.struckChannels = 0
        // A voice's pitch is its highest note sounding.
        for channel in 0 ..< 18 where voiceOf[channel] >= 0 && chipPitches[channel] > 0 {
            pitches[voiceOf[channel]] = max(pitches[voiceOf[channel]], chipPitches[channel])
        }
    }

    /// Where the part is: the OPL3 puts a channel on the left, the right or both, by the part's pan.
    func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        for voice in 0 ..< 16 {
            let pan = synth.midiChannels[voice].panning
            sides[voice] = pan < 48 ? -1 : pan >= 80 ? 1 : 0
        }
    }

    // MARK: Checking

    /// Every register the synthesiser writes in the first `seconds` of the first song, with the chip's
    /// sample it is written at: for comparing with libADLMIDI's.
    func registerWrites(seconds: Double) -> [(sample: Int, register: UInt16, value: UInt8)] {
        var writes: [(sample: Int, register: UInt16, value: UInt8)] = []
        var at = 0
        let synth = ADLMIDISynth(bank: .fatMan, card: nil, log: { register, value in writes.append((at, register, value)) })
        let sequencer = MIDISequencer(file.songs[0], of: file, prelude: prelude)
        var delay = 0.0, carry = 0.0, eaten = 0.0, behind = false
        while at < Int(seconds * Double(Self.rate)) {
            delay = sequencer.tick(eaten, granularity: Self.minDelay, to: synth)
            synth.tickIterators(eaten)
            let eat = min(delay, Self.maxDelay)
            delay -= eat
            carry += Double(Self.rate) * eat
            let samples = Int(carry)
            carry -= Double(samples)
            if sequencer.atEnd, delay <= 0 { break }
            eaten = eat
            at += behind || samples == 0 ? samples : samples - 1
            if samples > 0 { behind = true }
        }
        return writes
    }
}
