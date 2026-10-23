// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import AudioToolbox
import SidayPlayer
import Foundation
import Synchronization

/// Single-producer, single-consumer ring of interleaved stereo floats.
/// The producer is the emulation thread; the consumer is the Core Audio render callback.
final class SampleRing: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int // in floats, power of two
    private let mask: Int
    private let head = Atomic<Int>(0) // written by producer
    private let tail = Atomic<Int>(0) // written by consumer
    private let flushRequested = Atomic<Bool>(false)
    let paused = Atomic<Bool>(false)
    /// Stereo frames handed to the device since the last flush.
    let framesPlayed = Atomic<Int>(0)
    let underruns = Atomic<Int>(0)

    init(frames: Int) {
        var n = 1
        while n < frames * 2 { n <<= 1 }
        capacity = n
        mask = n - 1
        storage = .allocate(capacity: n)
        storage.initialize(repeating: 0, count: n)
    }

    deinit {
        storage.deallocate()
    }

    /// Frames that can be written without blocking.
    var writableFrames: Int {
        (capacity - (head.load(ordering: .relaxed) &- tail.load(ordering: .acquiring))) / 2
    }

    var bufferedFrames: Int {
        (head.load(ordering: .acquiring) &- tail.load(ordering: .acquiring)) / 2
    }

    func write(_ source: UnsafePointer<Float>, frames: Int) {
        let h = head.load(ordering: .relaxed)
        for i in 0 ..< frames * 2 {
            storage[(h &+ i) & mask] = source[i]
        }
        head.store(h &+ frames * 2, ordering: .releasing)
    }

    /// Discards everything not yet played. Called by the producer; carried out by the consumer.
    func flush() {
        flushRequested.store(true, ordering: .releasing)
    }

    var isFlushing: Bool { flushRequested.load(ordering: .acquiring) }

    // Consumer side.
    func read(into destination: UnsafeMutablePointer<Float>, frames: Int) {
        if flushRequested.load(ordering: .acquiring) {
            tail.store(head.load(ordering: .acquiring), ordering: .releasing)
            framesPlayed.store(0, ordering: .relaxed)
            flushRequested.store(false, ordering: .releasing)
        }
        var t = tail.load(ordering: .relaxed)
        let available = paused.load(ordering: .relaxed) ? 0 : (head.load(ordering: .acquiring) &- t)
        let take = min(available, frames * 2)
        for i in 0 ..< take {
            destination[i] = storage[(t &+ i) & mask]
        }
        if take < frames * 2 {
            (destination + take).update(repeating: 0, count: frames * 2 - take)
            if !paused.load(ordering: .relaxed) { underruns.add(1, ordering: .relaxed) }
        }
        t &+= take
        tail.store(t, ordering: .releasing)
        framesPlayed.add(take / 2, ordering: .relaxed)
    }
}

/// Default-output Core Audio unit pulling interleaved stereo Float32 from a `SampleRing`.
final class AudioOutput: @unchecked Sendable {
    private var unit: AudioUnit?
    let ring: SampleRing
    /// For testing the player where nothing is to be heard: with SIDAY_SOUND_TO set to a file's path,
    /// no sound is played, and what would have been is written to that file instead, as stereo Float32,
    /// taken from the ring at the pace a sound card would take it.
    private var stand: Thread?
    private let standing = Atomic<Bool>(false)

    enum Failure: Error, CustomStringConvertible {
        case coreAudio(String, OSStatus)

        var description: String {
            switch self {
            case let .coreAudio(what, status): "audio output: \(what) failed (\(status))"
            }
        }
    }

    init(ring: SampleRing) throws {
        self.ring = ring
        if let path = ProcessInfo.processInfo.environment["SIDAY_SOUND_TO"] {
            FileManager.default.createFile(atPath: path, contents: nil)
            guard let file = FileHandle(forWritingAtPath: path) else { throw Failure.coreAudio("opening \(path)", -1) }
            standing.store(true, ordering: .relaxed)
            let thread = Thread { [self] in
                let frames = 512
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
                defer { buffer.deallocate() }
                let start = DispatchTime.now().uptimeNanoseconds
                var taken = 0
                while standing.load(ordering: .relaxed) {
                    ring.read(into: buffer, frames: frames)
                    file.write(Data(bytes: buffer, count: frames * 8))
                    taken += frames
                    let due = start + UInt64(taken) * 1_000_000_000 / UInt64(outputSampleRate)
                    let now = DispatchTime.now().uptimeNanoseconds
                    if due > now { usleep(useconds_t((due - now) / 1000)) }
                }
                try? file.close()
            }
            thread.start()
            stand = thread
            return
        }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw Failure.coreAudio("finding the default output", -1)
        }
        var instance: AudioUnit?
        var status = AudioComponentInstanceNew(component, &instance)
        guard status == noErr, let instance else { throw Failure.coreAudio("opening the output", status) }
        unit = instance

        var format = AudioStreamBasicDescription(
            mSampleRate: Double(outputSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                      &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw Failure.coreAudio("setting the stream format", status) }

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frameCount, ioData in
                let ring = Unmanaged<SampleRing>.fromOpaque(refCon).takeUnretainedValue()
                guard let ioData, let raw = ioData.pointee.mBuffers.mData else { return noErr }
                ring.read(into: raw.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(ring).toOpaque()
        )
        status = AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                      &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw Failure.coreAudio("installing the render callback", status) }
        status = AudioUnitInitialize(instance)
        guard status == noErr else { throw Failure.coreAudio("initialising the output", status) }
        status = AudioOutputUnitStart(instance)
        guard status == noErr else { throw Failure.coreAudio("starting the output", status) }
    }

    func stop() {
        standing.store(false, ordering: .relaxed)
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }
}

/// Writes 16-bit stereo PCM.
struct WAVWriter {
    /// Little-endian, whatever the machine.
    private var samples: [Int16] = []

    mutating func append(_ buffer: UnsafePointer<Float>, frames: Int) {
        for i in 0 ..< frames * 2 {
            let clipped = max(-1, min(1, buffer[i]))
            samples.append(Int16(clipped * 32767).littleEndian)
        }
    }

    func write(to url: URL) throws {
        var header = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { header.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        header.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        header.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2)
        u32(outputSampleRate); u32(outputSampleRate * 4); u16(4); u16(16)
        header.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBytes { header.append(contentsOf: $0) }
        try header.write(to: url)
    }
}
