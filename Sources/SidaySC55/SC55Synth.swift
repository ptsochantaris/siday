// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// The SC-55, as Nuked SC-55 emulates it: its controller running its firmware, which takes MIDI at its serial
/// port and programs the PCM chip, which makes the sound, 64,000 frames a second.
///
/// MIDI bytes are handed to it with the frame of its output they are to reach it before (`schedule`): the
/// synthesiser takes each at the step after it has made that many frames.
public final class SC55Synth {
    public static let sampleRate = 64000

    let pcm: SC55PCM
    let mcu: SC55MCU

    /// Frames made since the synthesiser was started.
    public private(set) var framesMade = 0

    /// Bytes waiting for their frame, in order.
    private var scheduled: [(frame: Int, byte: UInt8)] = []
    private var scheduledNext = 0
    /// A frame made beyond what was asked for (the chip makes two at a time), handed out first next time.
    private var carry: (Int32, Int32)?

    public init(roms: SC55ROMSet) {
        pcm = SC55PCM(waves: roms.waves)
        mcu = SC55MCU(rom1: roms.program, rom2: roms.extraProgram, pcm: pcm)
        mcu.reset()
    }

    /// How long the firmware is given to start before it is sent anything: a second of the controller's time
    /// (twelve of its 20 MHz cycles a step). It takes MIDI from about a third of a second; a note sent then
    /// sounds within a decibel of one sent fourteen seconds later, as Nuked SC-55's renderer sends it.
    public static let startSteps = 1_666_667

    /// Starts the firmware (see `startSteps`).
    public func start() { run(steps: Self.startSteps) }

    /// Runs the controller `steps` instructions, throwing away what is made.
    public func run(steps: Int) {
        for _ in 0 ..< steps {
            mcu.step()
            pcm.outputCount = 0
        }
    }

    /// Hands MIDI bytes to the serial port, to be taken once `frame` frames have been made.
    public func schedule(_ bytes: [UInt8], at frame: Int) {
        if scheduledNext > 0, scheduledNext == scheduled.count {
            scheduled.removeAll(keepingCapacity: true)
            scheduledNext = 0
        }
        for byte in bytes { scheduled.append((frame, byte)) }
    }

    /// Makes `frames` frames, left and right, the chip's 20-bit samples shifted up 12.
    public func render(into buffer: UnsafeMutablePointer<Int32>, frames: Int) {
        var done = 0
        if frames > 0, let (left, right) = carry {
            buffer[0] = left
            buffer[1] = right
            carry = nil
            done = 1
        }
        let pcm = pcm, mcu = mcu
        while done < frames {
            pcm.outputCount = 0
            while pcm.outputCount == 0 {
                while scheduledNext < scheduled.count, scheduled[scheduledNext].frame <= framesMade + pcm.outputCount {
                    mcu.post(scheduled[scheduledNext].byte)
                    scheduledNext += 1
                }
                mcu.step()
            }
            for i in 0 ..< pcm.outputCount {
                if done < frames {
                    buffer[done * 2] = pcm.output[i * 2]
                    buffer[done * 2 + 1] = pcm.output[i * 2 + 1]
                    done += 1
                } else {
                    carry = (pcm.output[i * 2], pcm.output[i * 2 + 1])
                }
            }
            framesMade += pcm.outputCount
        }
    }

    // MARK: Parts

    /// Where firmware 1.21 keeps the part each of the PCM chip's slots plays, in its static RAM (0xA318), found
    /// by playing notes on each part and looking.
    static let partTableAddress = 0xA318 - 0x8000

    /// A part's number, 0 to 15 for parts 1 to 16, as the firmware numbers it (as GS numbers its blocks: the
    /// rhythm part, part 10, first).
    @inline(__always) static func block(ofPart part: Int) -> Int { part == 9 ? 0 : part < 9 ? part + 1 : part }

    /// True while the parts' sound is measured, for their lamps and scopes.
    public var watchesParts = false {
        didSet { updatePartWatching() }
    }

    /// The parts not heard, 0 to 15 for parts 1 to 16.
    public func setMutedParts(_ muted: [Bool]) {
        var mask: UInt32 = 0
        for part in 0 ..< 16 where part < muted.count && muted[part] { mask |= 1 << UInt32(Self.block(ofPart: part)) }
        pcm.mutedParts = mask
        updatePartWatching()
    }

    private func updatePartWatching() {
        let needed = watchesParts || pcm.mutedParts != 0
        pcm.partTable = needed ? mcu.sram + Self.partTableAddress : nil
        if watchesParts, pcm.partRounds == nil {
            pcm.partRounds = .allocate(capacity: SC55PCM.partRoundCapacity * 16)
            pcm.partRoundCount = 0
        }
    }

    /// Each part's sound, round by round of the chip (32,000 a second), since they were last taken: `body` is
    /// given each part (0 to 15, parts 1 to 16), the rounds, and the samples, 16 apart.
    public func takePartSounds(_ body: (_ part: Int, _ rounds: Int, _ samples: UnsafePointer<Int32>) -> Void) {
        guard let rounds = pcm.partRounds else { return }
        for part in 0 ..< 16 { body(part, pcm.partRoundCount, rounds + Self.block(ofPart: part)) }
        pcm.partRoundCount = 0
    }

    /// The loudest each part has been since they were last taken (0 to 15, parts 1 to 16), 20-bit samples.
    public func takePartPeaks(_ body: (_ part: Int, _ peak: Int32) -> Void) {
        for part in 0 ..< 16 {
            let block = Self.block(ofPart: part)
            body(part, pcm.partPeaks[block])
            pcm.partPeaks[block] = 0
        }
    }
}
