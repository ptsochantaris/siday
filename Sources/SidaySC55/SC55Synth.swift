// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// The SC-55 or the SC-55mkII, as Nuked SC-55 emulates them: the controller running its firmware, which takes
/// MIDI at its serial port (the SC-55mkII's through its second processor) and programs the PCM chip, which
/// makes the sound: 64,000 frames a second on the SC-55, 66,207 on the SC-55mkII.
///
/// MIDI bytes are handed to it with the frame of its output they are to reach it before (`schedule`): the
/// synthesiser takes each at the step after it has made that many frames.
public final class SC55Synth {
    /// The frames a second it makes. The PCM chip makes two each time round its voices, which takes 25 of the
    /// controller's cycles a voice and one more: the SC-55's firmware has it go round 24 voices, 625 cycles at
    /// 20 MHz; the SC-55mkII's 28, 725 cycles, so that its 66,207 frames a second (as Nuked SC-55 has them)
    /// are of a controller at 24 MHz.
    public static func sampleRate(of model: SC55Model) -> Int { model == .sc55 ? 64000 : 66207 }

    public let model: SC55Model
    public var sampleRate: Int { Self.sampleRate(of: model) }

    let pcm: SC55PCM
    let mcu: SC55MCU

    /// Frames made since the synthesiser was started.
    public private(set) var framesMade = 0

    /// Bytes waiting for their frame, in order.
    private var scheduled: [(frame: Int, byte: UInt8)] = []
    private var scheduledNext = 0
    /// A frame made beyond what was asked for (the chip makes two at a time), handed out first next time.
    private var carry: (Int32, Int32)?

    /// The state it starts in, if the ROM set has it (`SC55ROMSet.started`).
    private let started: [UInt8]

    public init(roms: SC55ROMSet) {
        model = roms.model
        let mk2 = roms.model == .sc55mk2
        pcm = SC55PCM(waves: roms.waves, unscrambled: roms.unscrambledWaves, mk2: mk2)
        mcu = SC55MCU(rom1: roms.program, rom2: roms.extraProgram, subROM: mk2 ? roms.subProgram : nil, pcm: pcm)
        mcu.reset()
        started = roms.started
        partTableAddress = (mk2 ? 0xA368 : 0xA318) - 0x8000
    }

    /// How long the firmware is given to start before it is sent anything: a second of the controller's time
    /// (twelve of its cycles a step, at 20 MHz on the SC-55, at 24 on the SC-55mkII). The SC-55 takes MIDI
    /// from about a third of a second; a note sent then sounds within a decibel of one sent fourteen seconds
    /// later, as Nuked SC-55's renderer sends it.
    public static func startSteps(of model: SC55Model) -> Int { model == .sc55 ? 1_666_667 : 2_000_000 }

    /// The SC-55mkII's firmware leaves some of its settings as its memory has them when it starts, where it
    /// should set them (Nuked SC-55's README tells of it), and a memory that has never been written has them
    /// wrong: a tune is played a semitone flat, as if the master tune were at its lowest. So once it has
    /// started it is sent a GS reset, as jcmoyer's Nuked SC-55 renderer sends one, and given four seconds of
    /// its time to take it: it loses a note sent in the first second after it and plays one sent in the next
    /// out of tune, and one sent after four sounds within a tenth of a decibel of one sent after eleven, as
    /// that renderer sends it, and at the same pitch.
    static let mk2Reset: [UInt8] = [0xF0, 0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7F, 0x00, 0x41, 0xF7]
    static let mk2ResetSteps = 8_000_000

    /// Starts the firmware (see `startSteps`, and on the SC-55mkII `mk2Reset`); or, if the ROM set has the
    /// state it is in once it has, puts that back, which is the same.
    public func start() {
        if started.isEmpty {
            run(steps: Self.startSteps(of: model))
            if model == .sc55mk2 {
                for byte in Self.mk2Reset { mcu.post(byte) }
                run(steps: Self.mk2ResetSteps)
            }
        } else {
            var state = SC55State(started)
            mcu.keep(&state)
            pcm.keep(&state)
            mcu.sub?.keep(&state)
        }
    }

    /// Its state as it is, for `SC55ROMSet.started`. (The second processor is brought up to the controller's
    /// time first, as it would be at the end of the controller's step.)
    var state: [UInt8] {
        var state = SC55State()
        mcu.sub?.catchUp(to: mcu.cycles)
        mcu.keep(&state)
        pcm.keep(&state)
        mcu.sub?.keep(&state)
        return state.bytes
    }

    /// The wave ROMs as the chip reads them, for `SC55ROMSet.unscrambledWaves`.
    var unscrambledWaves: [UInt8] { [UInt8](UnsafeBufferPointer(start: pcm.waves, count: 3 << 20)) }

    /// Runs the controller `steps` instructions, throwing away what is made.
    public func run(steps: Int) {
        var left = steps
        while left > 0 {
            left -= mcu.step(most: left)
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
            // (The bytes due are the same until the chip next gives frames, so are posted before the steps.)
            while scheduledNext < scheduled.count, scheduled[scheduledNext].frame <= framesMade {
                mcu.post(scheduled[scheduledNext].byte)
                scheduledNext += 1
            }
            while pcm.outputCount == 0 { mcu.step() }
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

    /// Where the firmware keeps the part each of the PCM chip's slots plays, in its static RAM: 0xA318 for the
    /// SC-55's 1.21, 0xA368 for the SC-55mkII's 1.01, found by playing notes on each part and looking.
    let partTableAddress: Int

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
        pcm.partTable = needed ? mcu.sram + partTableAddress : nil
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
