// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import AVFoundation
import Foundation
import SidayKit
import Synchronization

/// What is being heard at this moment, for the screen to show: where in the song, the spectrum
/// analyser's bars, and what each voice with a light is doing. (Of the sound that is coming out of
/// the speaker now, not of what was last sent: see `PlaybackEngine.latency`.)
nonisolated struct Heard: Sendable {
    var tune = 0
    var serial = 0
    var position = 0.0
    /// The analyser's bars and then their caps, 0 to 1.
    var bars: [Float] = []
    var caps: [Float] = []
    /// For each voice with a light: its brightness, 0 to 1; its pitch in semitones (60 is middle
    /// C), 0 for none; whether a note was started on it; the side it is heard from, -1 to 1; what it
    /// is playing; and whether the listener has left it out.
    var levels: [Float] = []
    var pitches: [Float] = []
    var struck: [Bool] = []
    var sides: [Float] = []
    var kinds: [VoiceKind] = []
    var muted: [Bool] = []
    /// Each voice's scope, `ChannelWaves.points` points of it from -1 to 1, one voice after another.
    var scopes: [Float] = []
    /// True if the listener has paused, or nothing is playing.
    var resting = true

    init() {}

    /// Unpacks a chunk as the engine sent it.
    init(_ sent: SongKeeper.Sent) {
        tune = sent.tune
        serial = sent.serial
        position = sent.position
        let bands = sent.bars.count / 2
        bars = sent.bars.prefix(bands).map { Float($0) / 255 }
        caps = sent.bars.dropFirst(bands).map { Float($0) / 255 }
        let count = sent.voices.count / 6
        let rows = (0 ..< 6).map { row in Array(sent.voices[(row * count) ..< ((row + 1) * count)]) }
        muted = rows[5].map { $0 != 0 }
        levels = rows[0].map { Float($0) / 255 }
        pitches = rows[1].map { Float($0) / 2 }
        struck = rows[2].map { $0 != 0 }
        sides = rows[3].map { (Float($0) - 128) / 127 }
        kinds = rows[4].map { $0 == 2 ? .speaker : $0 != 0 ? .sample : .chip }
        scopes = (sent.scopes ?? []).map { (Float($0) - 128) / 127 }
        resting = false
    }
}

/// What a voice plays, as its light shows it.
nonisolated enum VoiceKind: Sendable, Equatable {
    /// A sound a chip makes of itself: a square wave, an FM voice, a waveform drawn in a tracker.
    case chip
    /// A recording of a sound.
    case sample
    /// The clicks of a loudspeaker that the computer's own code moves in and out: a beeper.
    case speaker
}

/// The app's sound: SidayKit's `SongKeeper` on a thread of its own, which renders each song whole and
/// sends it a little ahead into a `SoundRing`, and the system's audio output, which plays from that.
/// It is the arrangement the web player has, of a worker and an audio thread: nothing is loaded or
/// rendered on the audio thread itself.
nonisolated final class PlaybackEngine: @unchecked Sendable {
    /// What the listener asks for, as the main thread hands it over.
    enum Command: Sendable {
        case load(tune: Int, serial: Int, name: String, bytes: [UInt8], companions: [[UInt8]?], subsong: Int)
        case seek(position: Double, serial: Int)
        case mute(light: Int, solo: Bool)
        case output(OutputStyle)
        case settings([Double])
        case songLengths([UInt8]?)
        case keptLevel(key: String, text: String?)
        case stop
    }

    /// What the screen is told: the keeper's news, and that the last of a song has been heard.
    enum News: Sendable {
        case keeper(SongKeeper.Event)
        case ended(tune: Int, serial: Int)
        /// How many voices have a light now.
        case voices(Int)
    }

    private let ring = SoundRing()
    private let audio = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let commands = Mutex<[Command]>([])
    private let wake = DispatchSemaphore(value: 0)
    /// What is being heard, for the screen to read whenever it draws.
    private let now = Mutex(Heard())
    /// Where news is sent: on the main thread.
    private let tell: @Sendable @MainActor (News) -> Void

    init(tell: @escaping @Sendable @MainActor (News) -> Void) {
        self.tell = tell
        let thread = Thread { [unowned self] in run() }
        thread.name = "siday engine"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    // MARK: The main thread's

    func send(_ command: Command) {
        commands.withLock { $0.append(command) }
        wake.signal()
    }

    /// What is being heard at this moment.
    var heard: Heard { now.withLock { $0 } }

    /// Pauses, or plays again: the sound fades over a moment.
    func pause(_ paused: Bool) {
        ring.paused.store(paused, ordering: .releasing)
        if paused { now.withLock { $0.resting = true } }
    }

    /// The player's own volume, 0 to 1, as it is heard: on a curve, as the ear hears loudness.
    func setVolume(_ volume: Double) {
        audio.mainMixerNode.outputVolume = silent ? 0 : Float(volume * volume)
    }

    /// True for a test: the sound is made and played, and nothing but silence reaches the speaker,
    /// whatever the volume is set to.
    private var silent = false

    /// Starts the sound going to the system's output. Silent (for tests), it is made and played, and
    /// nothing is heard.
    func startOutput(silent: Bool) {
        guard source == nil else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(outputSampleRate), channels: 2)!
        self.silent = silent
        let ring = ring
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard list.count >= 2, let left = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.fill(left: left, right: right, count: Int(frameCount))
            if silent {
                left.update(repeating: 0, count: Int(frameCount))
                right.update(repeating: 0, count: Int(frameCount))
            }
            return noErr
        }
        audio.attach(node)
        audio.connect(node, to: audio.mainMixerNode, format: format)
        if silent { audio.mainMixerNode.outputVolume = 0 }
        source = node
        try? audio.start()
    }

    // MARK: The engine's thread

    /// The chunks sent and not yet heard, where each ends in the ring, and those heard a moment ago,
    /// which the screen shows once the speaker is playing them.
    private var queued: [(sent: SongKeeper.Sent, end: Int)] = []
    private var serial = 0
    private var tune = 0

    /// How long sound takes from the ring to the ear, in frames.
    private var latency: Int {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let seconds = session.outputLatency + session.ioBufferDuration
        #else
        let seconds = audio.outputNode.presentationLatency
        #endif
        return Int(max(0, seconds) * Double(outputSampleRate))
    }

    private func run() {
        let keeper = SongKeeper()
        let start = Date()
        func clock() -> Double { Date().timeIntervalSince(start) }
        var lastLatency = 0
        var latencyAsked = -1.0
        while true {
            let time = clock()
            for command in commands.withLock({ list in defer { list = [] }; return list }) {
                obey(command, keeper, time)
            }
            if keeper.isWorking { keeper.work(chunks: 4, now: time) }
            // What is heard has made room for more.
            let read = ring.read.load(ordering: .acquiring)
            while let first = queued.first, first.end <= read {
                queued.removeFirst()
                keeper.played(serial: first.sent.serial, now: time)
            }
            take(keeper)
            for event in keeper.events {
                let news = News.keeper(event)
                Task { @MainActor [tell] in tell(news) }
            }
            keeper.events.removeAll()
            // What the speaker is playing now, for the screen; and the end of the song, once it is heard.
            if time - latencyAsked > 0.5 {
                lastLatency = latency
                latencyAsked = time
            }
            // (Once there is nothing left to read, the sound already read goes on coming out.)
            let dry = ring.dry.load(ordering: .relaxed)
            show(heardAt: read - lastLatency + min(dry, lastLatency), dry: dry >= lastLatency)
            if !keeper.isWorking { _ = wake.wait(timeout: .now() + .milliseconds(5)) }
        }
    }

    private func obey(_ command: Command, _ keeper: SongKeeper, _ time: Double) {
        switch command {
        case let .load(tune, serial, name, bytes, companions, subsong):
            newRun(serial)
            self.tune = tune
            keeper.load(tune: tune, serial: serial, name: name, bytes: bytes, companions: companions, subsong: subsong, now: time)
        case let .seek(position, serial):
            newRun(serial)
            keeper.seek(to: position, serial: serial, now: time)
        case let .mute(light, solo):
            keeper.mute(light: light, solo: solo)
        case let .output(style):
            keeper.setOutput(style)
        case let .settings(values):
            keeper.setSettings(values)
        case let .songLengths(bytes):
            keeper.setSongLengths(bytes.map { SongLengthDatabase($0) })
        case let .keptLevel(key, text):
            keeper.setKeptLevel(key: key, text: text, now: time)
        case .stop:
            newRun(serial + 1)
            keeper.stop()
            now.withLock { $0 = Heard() }
            voicesTold = 0
            Task { @MainActor [tell] in tell(.voices(0)) }
        }
    }

    /// Another run of sound: what was waiting to be heard is dropped.
    private func newRun(_ serial: Int) {
        self.serial = serial
        ring.drop()
        queued.removeAll()
        ended = nil
    }

    /// Moves what the keeper has sent into the ring.
    private func take(_ keeper: SongKeeper) {
        guard !keeper.outbox.isEmpty else { return }
        var taken = 0
        for sent in keeper.outbox {
            guard sent.serial == serial else {
                taken += 1
                continue
            }
            let frames = sent.samples.count / 2
            guard ring.room >= frames else { break }
            sent.samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: frames) }
            queued.append((sent, ring.written.load(ordering: .relaxed)))
            history.append((sent, ring.written.load(ordering: .relaxed)))
            taken += 1
        }
        keeper.outbox.removeFirst(taken)
    }

    /// Chunks sent lately, and where each ends in the ring, for showing each as it is heard.
    private var history: [(sent: SongKeeper.Sent, end: Int)] = []
    /// The run whose last chunk has been heard, once it has.
    private var ended: Int?
    /// How many voices with a light the main thread was last told of.
    private var voicesTold = 0

    private func show(heardAt frame: Int, dry: Bool) {
        // (The chunk being heard is the first that ends after the frame being heard.)
        while history.count > 1, history[0].end <= frame { history.removeFirst() }
        guard let chunk = history.first(where: { $0.end > frame }) ?? history.last, chunk.sent.serial == serial else { return }
        let resting = ring.paused.load(ordering: .relaxed)
        let showing = now.withLock { $0.serial == chunk.sent.serial && $0.position == chunk.sent.position && $0.resting == resting }
        if !showing {
            var heard = Heard(chunk.sent)
            heard.resting = resting
            now.withLock { $0 = heard }
            if heard.levels.count != voicesTold {
                voicesTold = heard.levels.count
                let news = News.voices(voicesTold)
                Task { @MainActor [tell] in tell(news) }
            }
        }
        // The song's last chunk has been read, and has come out of the speaker: the song is over.
        if chunk.sent.last, dry, ended != serial, ring.read.load(ordering: .acquiring) >= chunk.end {
            ended = serial
            let news = News.ended(tune: chunk.sent.tune, serial: chunk.sent.serial)
            Task { @MainActor [tell] in tell(news) }
        }
    }
}
