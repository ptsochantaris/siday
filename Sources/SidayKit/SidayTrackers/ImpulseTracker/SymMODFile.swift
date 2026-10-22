// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// how it reads a module of Symphonie's and what it makes of one (`soundlib/Load_symmod.cpp`, by Devin
// Acker and the OpenMPT developers, which follows Patrick Meng's own Java player and Symphonie's
// Amiga source), and how such a module's samples are made of others (`IntMixer.h`, `MixerInterface.h`,
// `SampleConvertFixedPoint.hpp`).

/// A module of Symphonie's or Symphonie Pro's, Patrick Meng's trackers for the Amiga.
///
/// Symphonie did not play its notes on the Amiga's four voices but mixed them itself, as many
/// channels as were asked for, and its modules are written for that: up to 256 channels, a fixed
/// length to every track, samples of sixteen bits as often as eight, kept in whatever kind of
/// sound file they came in, and an echo over the whole sound. Its instruments are made from its
/// samples as they are loaded, by what the tracker does to them first: a sample played backwards or
/// upside down, through a filter of one kind or another, turned up past the top and squashed, or
/// mixed out of other instruments' samples (its "virtual" instruments), or blended from one loop to
/// another (its "transwave" ones).
///
/// There is no replayer of Symphonie's to hand. OpenMPT reads these files into a module of its own
/// kind, with Impulse Tracker's ways of playing, and its way of reading them is followed here as
/// closely as it goes: every sample made as OpenMPT makes it, every track's events made into the
/// commands it makes of them, and the whole played by Impulse Tracker's replayer as an MPTM file is
/// played (see `MPTMFile`), with OpenMPT's echo for Symphonie's (`OpenMPTSymMODEcho`). OpenMPT
/// gives these files a few things that no file of its own has, and the replayer has been taught
/// them (`IT2Module.playsAsSymphonie`, and `IT2Symphonie.swift`).
///
/// What OpenMPT leaves out is left out here too: Symphonie's DSP delay, its stereo detune and
/// phase, its fades of a sample's level as it plays (the "emphasis" command), and the commands it
/// adds to a note's pitch and volume by, which the file says. Its fine slides of volume and of pitch,
/// which Symphonie makes as it mixes and not tick by tick, are, as OpenMPT makes them, the nearest
/// slides an Impulse Tracker module has.
enum SymMODFile {
    /// True for a file that says it is one of these.
    static func isOne(_ data: [UInt8]) -> Bool {
        var r = SymMODBytes(data)
        return r.magic(Array("SymM".utf8)) && r.u32be() == 1 && r.u32be() == 0xFFFF_FFFF && (1 ... 256).contains(r.u32be())
    }

    // MARK: The file's parts

    /// One of Symphonie's events, which are its tracks' cells and its virtual instruments' parts.
    struct Event: Hashable, Comparable {
        var command: UInt8 = 0, note: Int8 = 0, param: UInt8 = 0, inst: UInt8 = 0

        init(command: UInt8 = 0, note: Int8 = 0, param: UInt8 = 0, inst: UInt8 = 0) {
            self.command = command
            self.note = note
            self.param = param
            self.inst = inst
        }

        init(_ d: [UInt8], _ at: Int) {
            command = at < d.count ? d[at] : 0
            note = at + 1 < d.count ? Int8(bitPattern: d[at + 1]) : 0
            param = at + 2 < d.count ? d[at + 2] : 0
            inst = at + 3 < d.count ? d[at + 3] : 0
        }

        static func < (a: Event, b: Event) -> Bool {
            (a.command, a.note, a.param, a.inst) < (b.command, b.note, b.param, b.inst)
        }

        /// Commands that are the whole tune's, and not the channel's.
        var isGlobal: Bool {
            if command == Command.setSpeed || command == Command.dspEcho || command == Command.dspDelay { return true }
            return command == Command.keyOn && (param == Volume.speedUp || param == Volume.speedDown)
        }
    }

    /// Symphonie's commands, by its numbers.
    enum Command {
        static let keyOn: UInt8 = 0, volSlideUp: UInt8 = 1, volSlideDown: UInt8 = 2, pitchSlideUp: UInt8 = 3, pitchSlideDown: UInt8 = 4
        static let replayFrom: UInt8 = 5, fromAndPitch: UInt8 = 6, setFromAdd: UInt8 = 7, fromAdd: UInt8 = 8, setSpeed: UInt8 = 9
        static let addPitch: UInt8 = 10, addVolume: UInt8 = 11, tremolo: UInt8 = 12, vibrato: UInt8 = 13, sampleVib: UInt8 = 14
        static let pitchSlideTo: UInt8 = 15, retrig: UInt8 = 16, emphasis: UInt8 = 17, addHalfTone: UInt8 = 18, cv: UInt8 = 19, cvAdd: UInt8 = 20
        static let filter: UInt8 = 23, dspEcho: UInt8 = 24, dspDelay: UInt8 = 25
    }

    /// What a key-on's volume means above 200.
    enum Volume {
        static let command: UInt8 = 200, stopSample: UInt8 = 254, contSample: UInt8 = 253, keyOff: UInt8 = 251
        static let speedDown: UInt8 = 250, speedUp: UInt8 = 249, setPitch: UInt8 = 248
        static let pitchUp: UInt8 = 247, pitchDown: UInt8 = 246, pitchUp2: UInt8 = 245, pitchDown2: UInt8 = 244, pitchUp3: UInt8 = 243, pitchDown3: UInt8 = 242
    }

    /// An instrument as the file gives it: 256 bytes.
    struct Instrument {
        private(set) var d: [UInt8]

        init(_ d: [UInt8], at: Int) {
            self.d = (0 ..< 256).map { at + $0 < d.count ? d[at + $0] : 0 }
        }

        private func u16(_ i: Int) -> Int { Int(d[i]) << 8 | Int(d[i + 1]) }
        private func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) << 16 | UInt32(u16(i + 2)) }

        // Its first 128 bytes: a name, or a virtual or transwave instrument's heading and parts.
        var headerIsValid: Bool { d[0] == 0x56 && d[1] == 0x69 && d[2] == 0x52 && d[3] == 0x54 && d[4] == 0 && u16(6) <= 1 && u16(12) == 0 && u16(16) == 20 }
        var headerIsVirtual: Bool { headerIsValid && u16(6) == 0 && u16(14) <= 20 && u16(18) == 4 }
        var headerIsTranswave: Bool { headerIsValid && u16(6) == 1 && u16(14) == 2 && u16(18) == 10 }
        var numEvents: Int { u16(14) }
        func event(_ i: Int) -> Event { Event(d, 20 + i * 4) }
        /// A transwave instrument's two loops: whose sample, and where its loop is, of 100 << 16.
        func transwave(_ i: Int) -> (source: Int, loopStart: UInt32, loopLength: UInt32) { (u16(20 + i * 16), u32(24 + i * 16), u32(28 + i * 16)) }

        var isVirtual: Bool { headerIsValid }
        var isEmpty: Bool { d[0] == 0 || type < 0 }

        var type: Int8 { Int8(bitPattern: d[128]) }
        var loopStartHigh: Int { Int(d[129]) }
        var loopLenHigh: Int { Int(d[130]) }
        var numRepetitions: Int { Int(d[131]) }
        var channel: UInt8 { d[132] }
        var volume: Int { Int(d[134]) }
        var finetune: Int8 { Int8(bitPattern: d[138]) }
        var transpose: Int8 { Int8(bitPattern: d[139]) }
        var sampleFlags: UInt8 { d[140] }
        var filter: Int8 { Int8(bitPattern: d[141]) }
        var instFlags: UInt8 { d[142] }
        var downsample: UInt8 { d[143] }
        var loopStartFine: Int { u16(150) }
        var loopLenFine: Int { u16(152) }
        var filterFlags: UInt8 { d[160] }
        var numFilterPoints: Int { Int(d[161]) }
        func filterPoint(_ i: Int) -> (cutoff: Int, resonance: Int) { (Int(d[162 + i * 2]), Int(d[163 + i * 2])) }
        var volFadeFlag: Int { Int(d[170]) }
        var volFadeFrom: Int { Int(d[171]) }
        var volFadeTo: Int { Int(d[172]) }

        /// What OpenMPT changes of an instrument as it makes it: how far it is played down, in
        /// octaves, and transposed, in semitones; each a byte, as the file has them.
        mutating func add(downsample: UInt8) { d[143] &+= downsample }
        mutating func add(transpose: Int8) { d[139] = UInt8(bitPattern: Int8(bitPattern: d[139]) &+ transpose) }
    }

    enum Kind {
        static let silent: Int8 = -8, kill: Int8 = -4, normal: Int8 = 0, loop: Int8 = 4, sustain: Int8 = 8
    }

    enum Side {
        static let mono: UInt8 = 0, stereoL: UInt8 = 1, stereoR: UInt8 = 2, lineSrc: UInt8 = 3
    }

    enum SampleFlag {
        static let playReverse: UInt8 = 1, asQueue: UInt8 = 2, mirrorX: UInt8 = 4, newLoopSystem: UInt8 = 16
    }

    enum InstFlag {
        static let noTranspose: UInt8 = 1, noDSP: UInt8 = 2, syncPlay: UInt8 = 4
    }

    /// A place in a sequence: which track, from which line and for how many, at what speed and
    /// transposed how far, and how many times over.
    struct Position {
        var loopNum = 0, pattern = 0, start = 0, length = 0, speed = 0, transpose = 0

        init(_ d: [UInt8], _ at: Int) {
            func u16(_ i: Int) -> Int { at + i + 1 < d.count ? Int(d[at + i]) << 8 | Int(d[at + i + 1]) : 0 }
            loopNum = u16(4)
            pattern = u16(8)
            start = u16(10)
            length = u16(12)
            speed = u16(14)
            transpose = Int(Int16(truncatingIfNeeded: u16(16)))
        }
    }

    /// What OpenMPT tells one place from another by, to make one pattern of those that are the same.
    struct PositionKey: Hashable {
        let pattern: Int, start: Int, length: Int, transpose: Int, speed: Int
    }

    /// A sequence: which of the places it plays, and how far it transposes them; or the end of them all.
    struct Sequence {
        var start = 0, length = 0, info = 0, transpose = 0

        init(_ d: [UInt8], _ at: Int) {
            func u16(_ i: Int) -> Int { at + i + 1 < d.count ? Int(d[at + i]) << 8 | Int(d[at + i + 1]) : 0 }
            start = u16(0)
            length = u16(2)
            info = Int(Int16(truncatingIfNeeded: u16(6)))
            transpose = Int(Int16(truncatingIfNeeded: u16(8)))
        }
    }

    /// A part of the file that may be packed: its length, and its bytes, or "PACK" and two bytes of
    /// 255, how long it is unpacked, and runs of bytes, of four bytes over and over, and of noughts.
    /// Empty for a part that runs past the end of the file, or that does not unpack to the length it
    /// says.
    static func decoded(_ r: inout SymMODBytes) -> [UInt8] {
        let packed = SymMODBytes.length(r.u32be())
        guard r.canRead(packed) else {
            r.skip(r.left)
            return []
        }
        var part = r.chunk(packed)
        guard packed >= 10, part.magic([0x50, 0x41, 0x43, 0x4B, 0xFF, 0xFF]) else { return Array(part.data[part.start ..< part.end]) }
        // (A run of four bytes says at the most 255 of them in six: no more than that can be unpacked.
        // And no more than a part of a module can need, against a file made to ask for more.)
        let unpacked = Int(min(Int64(SymMODBytes.length(part.u32be())), Int64(packed - 10) * 170, Int64(mostUnpacked)))
        var data = [UInt8](repeating: 0, count: unpacked)
        var offset = 0, remain = unpacked
        loop: while part.left > 0 {
            switch Int8(bitPattern: UInt8(part.u8())) {
            case 0: // so many bytes as they are
                let count = part.u8()
                guard remain >= count, part.canRead(count) else { break loop }
                for i in 0 ..< count { data[offset + i] = part.data[part.at + i] }
                part.skip(count)
                offset += count
                remain -= count
            case 1: // four bytes so many times
                let count = part.u8()
                guard remain >= count * 4, part.canRead(4) else { break loop }
                let word = (0 ..< 4).map { part.data[part.at + $0] }
                part.skip(4)
                for _ in 0 ..< count {
                    for k in 0 ..< 4 { data[offset + k] = word[k] }
                    offset += 4
                }
                remain -= count * 4
            case 2: // four bytes twice
                guard remain >= 8, part.canRead(4) else { break loop }
                for k in 0 ..< 8 { data[offset + k] = part.data[part.at + k % 4] }
                part.skip(4)
                offset += 8
                remain -= 8
            case 3: // so many noughts
                let count = part.u8()
                guard remain >= count else { break loop }
                offset += count
                remain -= count
            default: // the end, or what is not a run
                break loop
            }
        }
        return remain == 0 ? data : []
    }

    /// The most a packed part is taken to unpack to.
    private static let mostUnpacked = 1 << 27

    /// A sample's sound packed by Symphonie: each byte the difference from the one before.
    static func decodedSample8(_ r: inout SymMODBytes) -> [UInt8] {
        var data = decoded(&r)
        var last: UInt8 = 0
        for i in data.indices {
            last &+= data[i]
            data[i] = last
        }
        return data
    }

    /// The same for sixteen bits, in blocks of 4096 bytes: the low bytes' differences and then the
    /// high bytes', each from the byte before. What is left after the last whole block is left as it is.
    static func decodedSample16(_ r: inout SymMODBytes) -> [UInt8] {
        var data = decoded(&r)
        let block = 4096, half = block / 2
        var buffer = [UInt8](repeating: 0, count: block)
        for b in 0 ..< data.count / block {
            let offset = b * block
            var last: UInt8 = 0
            for i in 0 ..< half {
                last &+= data[offset + i]
                buffer[i * 2 + 1] = last
            }
            for i in 0 ..< half {
                last &+= data[offset + i + half]
                buffer[i * 2] = last
            }
            for i in 0 ..< block { data[offset + i] = buffer[i] }
        }
        return data
    }

    // MARK: Making the instruments' samples

    /// The samples as OpenMPT holds them as it reads the file, by its numbers for them from 1.
    struct Samples {
        var all: [SymMODSound] = [SymMODSound()]
        /// How many there are, which is more than have sound: OpenMPT's count.
        var count = 0

        subscript(_ index: Int) -> SymMODSound {
            get { index >= 0 && index < all.count ? all[index] : SymMODSound() }
            set {
                guard index >= 0 else { return }
                while all.count <= index { all.append(SymMODSound()) }
                all[index] = newValue
            }
        }
    }

    /// A virtual instrument's sample, mixed out of its parts as OpenMPT mixes it: each part another
    /// instrument's sample at the part's note against the first part's, at once, or one after
    /// another for an instrument that queues them, through OpenMPT's mixer at its straight lines
    /// between points, and at a level that leaves room for a filter after it. Nil if it has no parts;
    /// a sample of no sound if it has nothing to mix, which is what OpenMPT then leaves in its place.
    static func rendered(_ ins: Instrument, asQueue: Bool, from samples: Samples, boost: Int) -> (sound: SymMODSound, made: Bool)? {
        let count = ins.numEvents
        guard count >= 1, count <= 20, Int(ins.event(0).inst) < samples.count else { return nil }
        let events = (0 ..< count).map { ins.event($0) }
        let rateFactor = 1.0 / Double(max(samples[Int(events[0].inst) + 1].rate, 1))

        var target = SymMODSound()
        target.sixteen = true
        var total: Int64 = 0
        for event in events.prefix(asQueue ? events.count : 1) {
            guard Int(event.inst) < samples.count, event.note >= 0 else { continue }
            let source = samples[Int(event.inst) + 1]
            let frames = Double(source.length) * pow(2.0, Double(Int(event.note) - Int(events[0].note)) / -12.0) * Double(source.rate) * rateFactor
            total += Int64(saturatedFrames(frames))
        }
        let length = Int(min(total, Int64(SymMODSound.mostFrames)))
        target.length = length
        // (No sound, or more than a sample can have: the sample is left empty.)
        guard total > 0, total <= Int64(SymMODSound.mostFrames) else { return (target, false) }

        // Each part as a voice of OpenMPT's mixer: where it is in its sample, how far it goes for each
        // frame, as 32 bits and 32 of fraction, and when it starts.
        struct Voice {
            var source: Int = -1
            var position: Int64 = 0, increment: Int64 = 0
            var waiting = 0
            var volume: Int32 = 0
        }
        var voices = [Voice](repeating: Voice(), count: events.count)
        var lastOffset = 0
        for (index, event) in events.enumerated() {
            guard Int(event.inst) < samples.count, event.note >= 0 else { continue }
            var finetune = 0
            if event.param >= Volume.pitchDown3, event.param <= Volume.pitchUp {
                finetune = [-4, 4, -2, 2, -1, 1][Int(event.param - Volume.pitchDown3)]
            }
            let source = samples[Int(event.inst) + 1]
            let increment = pow(2.0, Double(Int(event.note) - Int(events[0].note)) / 12.0 + Double(finetune) / 96.0) * Double(source.rate) * rateFactor
            guard increment > 0 else { continue }
            var voice = Voice()
            // (A part whose sample has no sound is no part, but it is counted in the length.)
            voice.source = source.hasData ? Int(event.inst) + 1 : -1
            voice.increment = increment * 4_294_967_296.0 < 9.2e18 ? Int64(increment * 4_294_967_296.0) : Int64.max
            if asQueue {
                voice.waiting = lastOffset
                lastOffset = min(SymMODSound.mostFrames, lastOffset + saturatedFrames(Double(source.length) / (Double(voice.increment) / 4_294_967_296.0)))
            }
            var volume = Int32(4096 * boost / 10000)
            if !asQueue { volume /= Int32(count) }
            voice.volume = volume
            voices[index] = voice
        }

        var output = [Int16](repeating: 0, count: length)
        var mix = [Int32](repeating: 0, count: blockSize)
        var written = 0
        while written < length {
            let writeCount = min(blockSize, length - written)
            for i in 0 ..< writeCount { mix[i] = 0 }
            for v in voices.indices where voices[v].source >= 0 {
                if voices[v].waiting >= writeCount {
                    voices[v].waiting -= writeCount
                    continue
                }
                let s = samples[voices[v].source]
                let remaining = (Double(s.length) - Double(voices[v].position) / 4_294_967_296.0) / (Double(voices[v].increment) / 4_294_967_296.0)
                let count = min(writeCount - voices[v].waiting, saturatedFrames(remaining))
                var at = voices[v].waiting
                var position = voices[v].position
                let volume = voices[v].volume
                for _ in 0 ..< max(0, count) {
                    // OpenMPT's straight line between two points, of fourteen bits of fraction.
                    let whole = Int(truncatingIfNeeded: position >> 32)
                    let fraction = Int32(truncatingIfNeeded: (position & 0xFFFF_FFFF) >> 18)
                    let shift = s.sixteen ? 0 : 8
                    let a = Int32(truncatingIfNeeded: s.point(whole) << shift), b = Int32(truncatingIfNeeded: s.point(whole + 1) << shift)
                    let point = a &+ (fraction &* (b &- a)) / 16384
                    mix[at] = mix[at] &+ point &* volume
                    at += 1
                    position &+= voices[v].increment
                }
                voices[v].position = position
                voices[v].waiting = 0
                if position >> 32 >= Int64(s.length) { voices[v].source = -1 }
            }
            // From OpenMPT's 27 bits of fraction to sixteen bits, rounded and held within them.
            for i in 0 ..< writeCount {
                output[written + i] = Int16(max(-32768, min(32767, (mix[i] &+ 2048) >> 12)))
            }
            written += writeCount
        }
        target.words = output
        target.replaced()
        return (target, true)
    }

    /// OpenMPT's mixer works in blocks of so many frames.
    private static let blockSize = 512

    /// A number of frames from a fraction, rounded as OpenMPT rounds it, and within what a sample can be.
    private static func saturatedFrames(_ value: Double) -> Int {
        guard value.isFinite else { return value > 0 ? SymMODSound.mostFrames : 0 }
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        return rounded <= 0 ? 0 : rounded >= 4_294_967_295 ? Int.max >> 1 : Int(min(rounded, Double(Int32.max)))
    }

    /// A transwave instrument's sample: 80 turns round the first sample's loop, each a quarter as fast
    /// as the loop plays and so four times as long, the first all of it and the last all of the second
    /// sample's loop, read in step with it, and those between a blend of the two. Nil if the first
    /// loop has nothing in it, when OpenMPT leaves an empty sample in its place.
    static func transwave(_ ins: Instrument, _ first: SymMODSound, _ second: SymMODSound) -> SymMODSound? {
        func loop(_ i: Int, _ s: SymMODSound) -> (start: Int, length: Int) {
            let point = ins.transwave(i)
            let scale = Double(s.length) / Double(100 << 16)
            let start = truncatedFrames(scale * Double(min(UInt32(100 << 16), point.loopStart)))
            let length = truncatedFrames(scale * Double(min(UInt32(100 << 16), point.loopLength)))
            return (start, min(max(0, s.length - start), length))
        }
        let (start1, length1) = loop(0, first), (start2, length2) = loop(1, second)
        guard length1 >= 1, length1 <= SymMODSound.mostFrames / (4 * 80) else { return nil }
        let cycle = length1 * 4
        let factor1 = Double(length1) / Double(cycle), factor2 = Double(length2) / Double(cycle)
        var target = SymMODSound()
        target.sixteen = true
        target.length = cycle * 80
        var words = [Int16](repeating: 0, count: target.length)
        let ampFactor = 1.0 / Double(target.length)
        func interpolated(_ s: SymMODSound, _ offset: Double) -> Double {
            guard s.hasData else { return 0 }
            let whole = Int(offset)
            let fraction = offset - Double(whole)
            let shift = s.sixteen ? 0 : 8
            let a = Double(Int16(truncatingIfNeeded: s.point(whole) << shift)), b = Double(Int16(truncatingIfNeeded: s.point(whole + 1) << shift))
            return a * (1.0 - fraction) + b * fraction
        }
        for i in 0 ..< cycle {
            let v1 = interpolated(first, Double(start1) + Double(i) * factor1)
            let v2 = interpolated(second, Double(start2) + Double(i) * factor2)
            var at = i
            for _ in 0 ..< 80 {
                let amp = Double(at) * ampFactor
                words[at] = Int16(max(-32768, min(32767, (v1 * (1.0 - amp) + v2 * amp).rounded(.toNearestOrAwayFromZero))))
                at += cycle
            }
        }
        target.words = words
        target.replaced()
        return target
    }

    private static func truncatedFrames(_ value: Double) -> Int {
        value.isFinite && value > 0 ? Int(min(value, Double(Int32.max))) : 0
    }

    /// The loop an instrument gives its sample, by its new way, of 100 << 16 of the sample's length;
    /// or by its old, of 100, which is found as Symphonie found it, and then brought back to where the
    /// sample is nearly where the loop starts.
    static func loop(of ins: Instrument, _ s: SymMODSound) -> (start: Int, length: Int) {
        guard ins.type == Kind.loop || ins.type == Kind.sustain else { return (0, 0) }
        var start = min(ins.loopStartHigh, 100), length = min(ins.loopLenHigh, 100)
        if ins.sampleFlags & SampleFlag.newLoopSystem != 0 {
            let scale = Double(s.length) / Double(100 << 16)
            start = min(s.length, truncatedFrames(Double(start << 16 + ins.loopStartFine) * scale))
            length = min(s.length - start, truncatedFrames(Double(length << 16 + ins.loopLenFine) * scale))
        } else if s.hasData {
            // (In the order Symphonie's own source works them out, which loses some of the precision.)
            start = ((start << 7) / 100) * (s.length >> 7)
            length = max(0, min(s.length - start, ((length << 7) / 100) * (s.length >> 7)))
            let threshold = s.sixteen ? 6 * 256 : 6
            let atStart = s.point(start)
            while length > 0 {
                if abs(s.point(start + length) - atStart) < threshold { break }
                length -= 1
            }
        }
        return (start, length)
    }

    /// What OpenMPT does to an instrument's sample as it makes the instrument: the loop, the volume
    /// (some of it the sample's and some the instrument's), the tuning, and then the sound played
    /// backwards, upside down, through Symphonie's filters and fade, made as loud as it can be, and
    /// squashed for a volume above 100. And for a sample that is to loop so many times before it plays
    /// on, the loop written out so many times.
    /// - Returns: the instrument's volume of 64 and the plug-in it plays through.
    static func convert(_ ins: Instrument, _ s: inout SymMODSound) -> (volume: Int, plugIn: Int, cutoff: Int, resonance: Int) {
        s.loops = false
        let (loopStart, loopLength) = loop(of: ins, s)
        if ins.type == Kind.loop, loopLength > 0 {
            s.loops = true
            s.loopStart = loopStart
            s.loopEnd = loopStart + loopLength
        }

        // Of 0 to 199, 100 as it is: a volume below 100 is shared between the sample and the
        // instrument, and one above it is made in the sound itself, at the end.
        let volume = ins.volume
        let effective = volume > 0 && volume < 200 ? min(volume, 100) * 128 / 100 : 128
        s.globalVolume = max(effective, 64) / 2
        let instrumentVolume = min(effective, 64)

        s.rate = 40460
        let transpose = -Double(ins.downsample) + Double(ins.transpose) / 12.0 + Double(ins.finetune) / (128.0 * 12.0)
        let rate = (Double(s.rate) * pow(2.0, transpose)).rounded(.toNearestOrAwayFromZero)
        s.rate = rate <= 0 ? 0 : rate >= 4_294_967_295 ? UInt32.max : UInt32(rate)

        let noDSP = ins.instFlags & InstFlag.noDSP != 0
        let result = (volume: instrumentVolume, plugIn: noDSP ? 2 : 1, cutoff: noDSP ? 0x80 | 127 : 0, resonance: noDSP ? 0x80 : 0)

        guard s.hasData else { return result }
        if ins.sampleFlags & SampleFlag.playReverse != 0 { s.reverse() }
        if ins.sampleFlags & SampleFlag.mirrorX != 0 { s.invert() }

        // (Always to sixteen bits, for a sample of eight that is to be filtered or faded.)
        let fades = ins.volFadeFlag == 2 && ins.volFadeFrom <= 100 && ins.volFadeTo <= 100
        if !s.sixteen, ins.filterFlags != 0 || fades || ins.filter != 0 { s.widen() }

        if ins.filter < 0 {
            // A high pass, so many times over.
            for _ in 0 ..< -Int(ins.filter) {
                var mix = Int32(s.words[0])
                for i in s.words.indices {
                    mix = (Int32(s.words[i]) &- (mix >> 1)) >> 1
                    s.words[i] = Int16(truncatingIfNeeded: mix)
                }
            }
        }
        if fades {
            // From one level to another over the whole sample.
            let points = s.words.count
            var amp = Int32(ins.volFadeFrom) << 24
            let step = mulDivRounded(Int32(ins.volFadeTo - ins.volFadeFrom), 1 << 24, Int32(truncatingIfNeeded: points))
            for i in 0 ..< points {
                s.words[i] = Int16(truncatingIfNeeded: mulDivRounded(Int32(s.words[i]), amp, 100 << 24))
                amp &+= step
            }
        }
        if ins.filterFlags != 0, !s.words.isEmpty {
            // A resonant filter, its cutoff and resonance moving from one setting to the next over the sample.
            let points = Int32(truncatingIfNeeded: s.words.count)
            let first = ins.filterPoint(0), second = ins.filterPoint(1)
            var cutoff = Int32(first.cutoff) << 23, resonance = Int32(first.resonance) << 23
            let cutoffStep = ins.numFilterPoints > 1 ? mulDivRounded(Int32(second.cutoff - first.cutoff), 1 << 23, points) : 0
            let resonanceStep = ins.numFilterPoints > 1 ? mulDivRounded(Int32(second.resonance - first.resonance), 1 << 23, points) : 0
            let highPass = ins.filterFlags & 2 != 0
            var state: (Int32, Int32, Int32) = (0, 0, 0)
            for i in s.words.indices {
                let c = cutoff / (1 << 23), r = resonance / (1 << 23)
                cutoff &+= cutoffStep
                resonance &+= resonanceStep
                state.2 = (Int32(s.words[i]) >> 1) &- state.0
                state.1 &+= (c &* state.2) >> 8
                state.0 &+= (c &* state.1) >> 6
                state.0 &+= (r &* state.0) >> 6
                state.0 >>= 2
                s.words[i] = Int16(max(-32768, min(32767, highPass ? state.2 : state.0)))
            }
        }
        if ins.filter > 0 {
            // A low pass, so many times over.
            for _ in 0 ..< Int(ins.filter) {
                var mix = Int32(s.words[0])
                for i in s.words.indices {
                    mix = (Int32(s.words[i]) &+ Int32(s.words[i]) &+ mix) / 3
                    s.words[i] = Int16(truncatingIfNeeded: mix)
                }
            }
        }

        // Symphonie makes every sample as loud as it can be, the sides of a stereo one each alone.
        if s.sixteen { normalise(&s.words, top: 32767) } else { normalise(&s.bytes, top: 127) }

        // And makes one louder than that by squashing what goes over a knee.
        if volume > 100, volume < 200 {
            let knee = Int32(16384 * (200 - volume) / 100), kneeInv = 32768 - knee
            func amplified(_ point: Int32, _ scale: Int32) -> Int32 {
                var v = point * scale
                if v > knee {
                    v = (v - knee) * knee / kneeInv + kneeInv
                } else if v < -knee {
                    v = (v + knee) * knee / kneeInv - kneeInv
                } else {
                    v = v * kneeInv / knee
                }
                return v / scale
            }
            if s.sixteen {
                for i in s.words.indices { s.words[i] = Int16(max(-32768, min(32767, amplified(Int32(s.words[i]), 1)))) }
            } else {
                for i in s.bytes.indices { s.bytes[i] = Int8(max(-128, min(127, amplified(Int32(s.bytes[i]), 256)))) }
            }
        }

        s.cue = nil
        let repeats = ins.numRepetitions
        if ins.type == Kind.sustain, repeats > 0, loopLength > 0 {
            s.cue = loopStart + loopLength * (repeats + 1)
            // The loop, written out as many times again as it is to go round.
            guard SymMODSound.mostFrames / repeats >= loopLength, SymMODSound.mostFrames - repeats * loopLength >= s.length else { return result }
            func lengthened<T>(_ points: [T], _ width: Int) -> [T] {
                var made = Array(points[0 ..< (loopStart + loopLength) * width])
                for _ in 0 ..< repeats { made += points[loopStart * width ..< (loopStart + loopLength) * width] }
                made += points[(loopStart + loopLength) * width ..< points.count]
                return made
            }
            if s.sixteen { s.words = lengthened(s.words, s.channels) } else { s.bytes = lengthened(s.bytes, s.channels) }
            s.length += loopLength * repeats
            s.replaced()
        }
        return result
    }

    /// Every point times the top over the loudest, unless that is the top already, or nothing.
    private static func normalise<T: FixedWidthInteger & SignedInteger>(_ points: inout [T], top: Int) {
        guard let low = points.min(), let high = points.max() else { return }
        let most = max(-Int(low), Int(high))
        guard most < top, most != 0 else { return }
        for i in points.indices { points[i] = T(truncatingIfNeeded: Int(points[i]) * top / most) }
    }

    /// a × b ÷ c, rounded, as OpenMPT's `muldivr` has it.
    static func mulDivRounded(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 {
        guard c != 0 else { return 0 }
        let value = (Int64(a) * Int64(b) + Int64(c / 2)) / Int64(c)
        return Int32(clamping: value)
    }
}
