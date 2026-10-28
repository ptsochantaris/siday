// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import AVFoundation
import Foundation
import SidayPlayer
import Synchronization

/// The app's sound: SidayPlayer's `SongKeeper` on a thread of its own, which renders each song whole and
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
        case mt32ROMs(MT32ROMSet?)
        case keptLevel(key: String, text: String?)
        case stop
        /// What was found of a tune's songs by playing them through, away from this thread.
        case measured(tune: Int, key: String, measures: SongMeasures)
    }

    /// What the screen is told: the keeper's news, and that the last of a song has been heard.
    enum News: Sendable {
        case keeper(SongKeeper.Event)
        case ended(tune: Int, serial: Int)
        /// How many voices have a light now.
        case voices(Int)
        /// Another app has taken the sound (a call, or other music played): the player is to pause.
        case interrupted
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
        if paused { letGo() } else { take() }
    }

    /// Whether the sound is going out: only while something is to be heard, so that other apps'
    /// sound is left alone until then (on an iPhone or iPad, playing stops theirs, as Music's does).
    private var running = false
    /// Letting go of the sound, once the fade of a pause is over.
    private var letting: DispatchWorkItem?

    private func take() {
        letting?.cancel()
        letting = nil
        guard source != nil, !running else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        try? audio.start()
        running = audio.isRunning
    }

    private func letGo() {
        guard running, letting == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, running, ring.paused.load(ordering: .acquiring) else { return }
            letting = nil
            audio.pause()
            running = false
            #if os(iOS)
            // (And the app whose sound was stopped is told it can carry on.)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
        letting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
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
        // (The session is made active only when there is something to hear: see `take()`.)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            // The system has stopped the sound: what is playing is paused, and played again when asked.
            running = false
            letting?.cancel()
            letting = nil
            let tell = tell
            MainActor.assumeIsolated { tell(.interrupted) }
        }
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
                if case let .measure(tune, name, bytes, companions) = event { measure(tune: tune, name: name, bytes: bytes, companions: companions) }
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
        case let .mt32ROMs(roms):
            keeper.setMT32ROMs(roms)
            measuring.async { [measuredPlayer] in measuredPlayer.setMT32ROMs(roms) }
        case let .keptLevel(key, text):
            keeper.setKeptLevel(key: key, text: text, now: time)
        case let .measured(tune, key, measures):
            keeper.adopt(tune: tune, key: key, measures: measures)
        case .stop:
            newRun(serial + 1)
            keeper.stop()
            now.withLock { $0 = Heard() }
            voicesTold = 0
            Task { @MainActor [tell] in tell(.voices(0)) }
        }
    }

    /// Where a tune's songs are played through to find how long they are (`SongKeeper.Event.measure`),
    /// which can take a second or two: on a thread of its own, so that the sound is not held up by it.
    /// Only the latest tune asked for is, if several are asked for while one is being played through.
    private let measuring = DispatchQueue(label: "siday measuring", qos: .utility)
    private let measuredPlayer = TunePlayer()
    private let latestMeasured = Mutex(0)

    private func measure(tune: Int, name: String, bytes: [UInt8], companions: [[UInt8]?]) {
        latestMeasured.withLock { $0 = tune }
        measuring.async { [self] in
            guard latestMeasured.withLock({ $0 }) == tune else { return }
            measuredPlayer.companions = companions
            guard let (key, measures) = measuredPlayer.measure(bytes, name: name) else { return }
            send(.measured(tune: tune, key: key, measures: measures))
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
