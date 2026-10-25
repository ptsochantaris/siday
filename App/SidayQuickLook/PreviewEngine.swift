// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import AVFoundation
import Foundation
import SidayPlayer
import Synchronization

/// A preview's sound: SidayPlayer's `TunePlayer` on a thread of its own, which makes the song a little
/// ahead of what is heard and writes it into a `SoundRing`, and the system's audio output, which plays
/// from that. The app's engine makes each song whole and keeps it, so that the listener can move about
/// in it; a preview has nowhere to move to, and an extension is given little memory, so this keeps
/// nothing that has been heard, and makes nothing until play is pressed.
nonisolated final class PreviewEngine: @unchecked Sendable {
    /// What the preview is told, on the main thread.
    enum News: Sendable {
        /// The tune is loaded: what is known of it, or why it does not play.
        case loaded(Tune?, problem: String?)
        /// The last of the song has been heard.
        case ended
    }

    private enum Command {
        case load(bytes: [UInt8], name: String, companions: [[UInt8]?])
        case restart
        case stop
    }

    /// Frames made at a time; and how far ahead of what is heard to make them, about a sixth of a second.
    private static let chunkFrames = 1024
    private static let ahead = 8 * chunkFrames

    private let ring = SoundRing()
    private let audio = AVAudioEngine()
    private let commands = Mutex<[Command]>([])
    private let wake = DispatchSemaphore(value: 0)
    /// What is being heard, for the screen to read whenever it draws.
    private let now = Mutex(Heard())
    private let playing = Atomic<Bool>(false)
    private let tell: @Sendable @MainActor (News) -> Void

    /// The main thread's: whether the sound is going out, and the letting go of it once a pause has faded.
    private var running = false
    private var letting: DispatchWorkItem?

    /// - Parameter silent: the sound is made and played, and nothing but silence reaches the speaker (for tests).
    init(silent: Bool, tell: @escaping @Sendable @MainActor (News) -> Void) {
        self.tell = tell
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(outputSampleRate), channels: 2)!
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
        ring.paused.store(true, ordering: .releasing)
        // (The thread keeps the engine until it is told to stop: a preview's engine goes when the preview does.)
        let thread = Thread { self.run() }
        thread.name = "siday preview"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    // MARK: The main thread's

    func load(_ bytes: [UInt8], name: String, companions: [[UInt8]?]) {
        send(.load(bytes: bytes, name: name, companions: companions))
    }

    /// The song from its beginning again.
    func restart() {
        send(.restart)
    }

    /// Stops for good: the thread ends, and the sound with it.
    func stop() {
        play(false)
        send(.stop)
    }

    private func send(_ command: Command) {
        commands.withLock { $0.append(command) }
        wake.signal()
    }

    /// What is being heard at this moment.
    var heard: Heard { now.withLock { $0 } }

    /// Plays, or pauses: the sound fades over a moment, and goes out only while there is something to
    /// hear, so that other sound is left alone until then.
    func play(_ on: Bool) {
        playing.store(on, ordering: .releasing)
        ring.paused.store(!on, ordering: .releasing)
        wake.signal()
        if on {
            letting?.cancel()
            letting = nil
            guard !running else { return }
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            try? audio.start()
            running = audio.isRunning
        } else {
            now.withLock { $0.resting = true }
            guard running, letting == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, running, ring.paused.load(ordering: .acquiring) else { return }
                letting = nil
                audio.pause()
                running = false
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                #endif
            }
            letting = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    // MARK: The engine's thread

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
        let player = TunePlayer()
        _ = player.setOutput(.abc)
        let chunk = UnsafeMutablePointer<Float>.allocate(capacity: Self.chunkFrames * 2)
        defer { chunk.deallocate() }
        /// What was made and not yet heard: where each chunk ends in the ring, and what it holds.
        var waiting: [(end: Int, heard: Heard)] = []
        /// Which voices have a light: those every tune of the kind has, and the rest once they are heard.
        var shown: [Bool] = []
        var loaded = false, over = false, toldOver = false
        while true {
            for command in commands.withLock({ list in defer { list = [] }; return list }) {
                switch command {
                case let .load(bytes, name, companions):
                    player.companions = companions
                    loaded = player.load(bytes, name: name)
                    let tune = loaded ? player.renderer.map { renderer in
                        Tune(renderer.info, songs: player.subsongCount > 1 ? renderer.songs : [], song: player.subsong, length: player.length)
                    } : nil
                    let problem = loaded ? nil : player.problem
                    shown = (0 ..< player.voiceCount).map { $0 < player.lightsAlwaysShown }
                    waiting = []
                    ring.drop()
                    over = false
                    toldOver = false
                    told(.loaded(tune, problem: problem))
                case .restart:
                    player.select(player.subsong)
                    waiting = []
                    ring.drop()
                    over = false
                    toldOver = false
                case .stop:
                    return
                }
            }
            // A little more of the song, while it plays and is not far enough ahead.
            let read = ring.read.load(ordering: .acquiring)
            if playing.load(ordering: .acquiring), loaded, !over, ring.written.load(ordering: .relaxed) - read < Self.ahead {
                over = !player.pull(into: chunk, frames: Self.chunkFrames)
                player.present(chunk, frames: Self.chunkFrames)
                player.takeVoices()
                player.takeScopes()
                ring.write(chunk, count: Self.chunkFrames)
                waiting.append((ring.written.load(ordering: .relaxed), heard(player, &shown)))
                continue
            }
            // What is coming out of the speaker now.
            let due = read - latency
            var latest: Heard?
            while let first = waiting.first, first.end <= due {
                latest = first.heard
                waiting.removeFirst()
            }
            if let latest, playing.load(ordering: .acquiring) { now.withLock { $0 = latest } }
            if over, !toldOver, waiting.isEmpty, read >= ring.written.load(ordering: .acquiring) {
                toldOver = true
                told(.ended)
            }
            _ = wake.wait(timeout: .now() + .milliseconds(5))
        }
    }

    /// What the chunk just made holds of the voices with a light, as the screen is to show them.
    private func heard(_ player: TunePlayer, _ shown: inout [Bool]) -> Heard {
        let count = min(shown.count, player.voiceCount)
        let rows = player.voicesTaken
        let points = ChannelWaves.points
        var heard = Heard()
        heard.tune = 1
        heard.serial = 1
        heard.position = player.position
        heard.resting = false
        for voice in 0 ..< count {
            // (A voice counts as heard once its light has been as bright as the app's engine asks.)
            if rows.count >= count * 5, rows[voice] >= 24 { shown[voice] = true }
            guard shown[voice], rows.count >= count * 5 else { continue }
            heard.levels.append(Float(rows[voice]) / 255)
            heard.pitches.append(Float(rows[count + voice]) / 2)
            heard.struck.append(rows[count * 2 + voice] != 0)
            heard.sides.append((Float(rows[count * 3 + voice]) - 128) / 127)
            let kind = rows[count * 4 + voice]
            heard.kinds.append(kind == 2 ? .speaker : kind != 0 ? .sample : .chip)
            heard.muted.append(false)
            if player.scopes.count >= (voice + 1) * points {
                heard.scopes += player.scopes[(voice * points) ..< ((voice + 1) * points)].map { (Float($0) - 128) / 127 }
            }
        }
        return heard
    }

    private func told(_ news: News) {
        let tell = tell
        DispatchQueue.main.async { tell(news) }
    }
}
