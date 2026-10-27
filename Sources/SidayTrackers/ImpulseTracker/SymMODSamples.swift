// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// how a module of Symphonie's keeps its samples and what is done to them as it is read
// (`soundlib/Load_symmod.cpp`, by Devin Acker and the OpenMPT developers), the kinds of sound file it
// keeps them in (`soundlib/SampleFormats.cpp`, `WAVTools.cpp`, `SampleIO.cpp`, `ModSampleCopy.h`),
// what is done to a sample's sound (`modsmp_ctrl.cpp`, `ModSample.cpp`), and the mixing a sample is
// made of others by (`IntMixer.h`, `MixerInterface.h`, `SampleConvertFixedPoint.hpp`).

/// A window on some bytes, read from the front, as OpenMPT reads the parts of a file: nought beyond
/// the end, and a part that is said to run past the end ending with it. (A whole number in a browser
/// has 32 bits: no length or place is made that could pass them.)
struct SymMODBytes {
    let data: [UInt8]
    let start: Int, end: Int
    var at: Int
    /// True once more has been asked of it than it has: for a file, that it is cut short.
    var overran = false

    init(_ data: [UInt8]) {
        self.data = data
        start = 0
        end = data.count
        at = 0
    }

    init(_ data: [UInt8], from: Int, count: Int) {
        self.data = data
        start = max(0, min(from, data.count))
        end = start + max(0, min(count, data.count - start))
        at = start
    }

    /// A window with nothing in it, which is what OpenMPT has for a part a file does not have.
    static let none = SymMODBytes([])

    var length: Int { end - start }
    var left: Int { end - at }
    /// True if it has anything in it: a part of no length is no part.
    var isValid: Bool { end > start }

    func canRead(_ count: Int) -> Bool { count >= 0 && count <= left }

    mutating func skip(_ count: Int) {
        if count > left { overran = true }
        at = count >= left ? end : at + max(0, count)
    }
    mutating func rewind() { at = start }

    /// To a place counted from the window's start; nowhere if it is beyond the end.
    mutating func seek(_ offset: Int) {
        if offset >= 0, offset <= length { at = start + offset }
    }

    mutating func u8() -> Int {
        guard at < end else {
            overran = true
            return 0
        }
        at += 1
        return Int(data[at - 1])
    }

    mutating func u16be() -> Int {
        let high = u8()
        return high << 8 | u8()
    }

    mutating func u16le() -> Int {
        let low = u8()
        return low | u8() << 8
    }

    mutating func u32be() -> UInt32 {
        let high = UInt32(u16be())
        return high << 16 | UInt32(u16be())
    }

    mutating func u32le() -> UInt32 {
        let low = UInt32(u16le())
        return low | UInt32(u16le()) << 16
    }

    /// The next so many bytes, as a window of their own; the window moves on past them.
    mutating func chunk(_ count: Int) -> SymMODBytes {
        let part = SymMODBytes(data, from: at, count: min(max(0, count), left))
        skip(count)
        return part
    }

    /// True, having passed over them, if the next bytes are these.
    mutating func magic(_ bytes: [UInt8]) -> Bool {
        guard left >= bytes.count else { return false }
        for i in bytes.indices where data[at + i] != bytes[i] { return false }
        at += bytes.count
        return true
    }

    /// The byte at a place counted from the window's start; nought beyond it.
    func byte(_ offset: Int) -> UInt8 {
        offset >= 0 && offset < length ? data[start + offset] : 0
    }

    /// A length as a whole number that a browser can hold.
    static func length(_ value: UInt32) -> Int {
        Int(min(value, 0x7FFF_FFFF))
    }

    /// The parts of an IFF or RIFF file from here to its end: each a name of four letters, a length
    /// and that many bytes, and a byte more after an odd one. The name is kept as it reads, the first
    /// byte the highest.
    mutating func parts(bigEndian: Bool, align: Int = 2) -> [(id: UInt32, data: SymMODBytes)] {
        var parts: [(id: UInt32, data: SymMODBytes)] = []
        while canRead(8) {
            let id = u32be()
            let size = Self.length(bigEndian ? u32be() : u32le())
            parts.append((id, chunk(size)))
            if align > 1, size % align != 0 { skip(align - size % align) }
        }
        return parts
    }

    static func id(_ letters: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in letters.utf8.prefix(4) { value = value << 8 | UInt32(byte) }
        return value
    }
}

/// A sample as OpenMPT holds one while it reads a module of Symphonie's: its sound, eight bits or
/// sixteen, of one side or two in turn, and the little more about it that playing it needs.
struct SymMODSound {
    var length = 0
    var stereo = false
    var sixteen = false
    var bytes: [Int8] = []
    var words: [Int16] = []
    /// OpenMPT's volume of 256 and global volume of 64; its rate at middle C.
    var volume = 256, globalVolume = 64
    var rate: UInt32 = 8363
    var loops = false, loopStart = 0, loopEnd = 0
    /// Where a key let go goes on from (OpenMPT's first "cue point"); nil for none.
    var cue: Int?
    /// A sample's own vibrato, as OpenMPT numbers its waves (sine, square, ramp up, ramp down, at random).
    var vibratoType = 0, vibratoSweep = 0, vibratoDepth = 0, vibratoRate = 0
    /// What the mixer finds just past the end of each side: what the sound last ended with when OpenMPT
    /// last made ready its loops, which it does after some changes to the sound and not after others,
    /// or nought for sound in memory just taken.
    var after: (Int, Int) = (0, 0)
    /// True for a sample in a kind of file that OpenMPT reads and this does not (a WAV file of
    /// floating point or of more than sixteen bits, say): it is silent.
    var unread = false

    var channels: Int { stereo ? 2 : 1 }
    var hasData: Bool { length > 0 && (sixteen ? words.count : bytes.count) >= length * channels }

    /// A point of the sound, as OpenMPT's mixer reads it: past the end, what lies there.
    @inline(__always) func point(_ frame: Int, side: Int = 0) -> Int {
        if frame >= length { return side == 0 ? after.0 : after.1 }
        let i = frame * channels + side
        return sixteen ? Int(words[i]) : Int(bytes[i])
    }

    /// What OpenMPT's `PrecomputeLoops` does that matters here: the end of each side is held in what lies past it.
    mutating func heldAtEnd() {
        guard hasData else { return }
        after = (point(length - 1), stereo ? point(length - 1, side: 1) : 0)
    }

    /// Sound in new memory, which is nought past its end.
    mutating func replaced() {
        after = (0, 0)
    }

    // MARK: Reading the sound

    /// How a sample's points are kept in a file.
    struct Layout {
        var sixteen = false, stereo = false
        /// Two sides one after another, and not in turn.
        var split = false
        var bigEndian = false, unsigned = false
    }

    /// OpenMPT's `SampleIO::ReadSample` for plain sound: as many frames as `length` says, or fewer
    /// for a long sample that the bytes there are run short of; and what the bytes run short of is
    /// silence. Nought if nothing was read.
    @discardableResult
    mutating func read(_ r: inout SymMODBytes, _ layout: Layout) -> Int {
        guard r.isValid else { return 0 }
        length = min(length, Self.mostFrames)
        let size = layout.sixteen ? 2 : 1, sides = layout.stereo ? 2 : 1
        let wanted = Int64(length) * Int64(size * sides)
        let available = Int(min(Int64(r.left), wanted))
        guard available >= 1 else { return 0 }
        if length > 0x40000 { length = min(length, (available + size * sides - 1) / (size * sides)) }
        guard length >= 1 else { return 0 }
        sixteen = layout.sixteen
        stereo = layout.stereo
        bytes = []
        words = []
        let points = length * sides
        func value(_ i: Int) -> Int {
            let at = r.at + i * size
            if layout.sixteen {
                let a = Int(r.data[at]), b = Int(r.data[at + 1])
                let raw = layout.bigEndian ? a << 8 | b : b << 8 | a
                return layout.unsigned ? raw - 0x8000 : Int(Int16(truncatingIfNeeded: raw))
            }
            let raw = Int(r.data[at])
            return layout.unsigned ? raw - 0x80 : Int(Int8(truncatingIfNeeded: raw))
        }
        let count = available / size
        if layout.sixteen { words = [Int16](repeating: 0, count: points) } else { bytes = [Int8](repeating: 0, count: points) }
        func put(_ i: Int, _ v: Int) {
            if layout.sixteen { words[i] = Int16(truncatingIfNeeded: v) } else { bytes[i] = Int8(truncatingIfNeeded: v) }
        }
        if layout.stereo, layout.split {
            // (All of the left, then all of the right, each as far as the bytes go.)
            let leftCount = min(length, count), rightCount = min(length, count - leftCount)
            for i in 0 ..< leftCount { put(i * 2, value(i)) }
            for i in 0 ..< rightCount { put(i * 2 + 1, value(length + i)) }
        } else {
            for i in 0 ..< min(points, count) { put(i, value(i)) }
        }
        r.skip(available)
        after = (0, 0)
        return available
    }

    /// OpenMPT's longest sample, in frames.
    static let mostFrames = 0x1000_0000

    // MARK: Kinds of sample file

    /// An IFF file of the Amiga's: 8SVX, 16SV or MAUD. Nil if it is not one, or wants what it has not got.
    static func iff(_ file: SymMODBytes) -> SymMODSound? {
        var r = file
        r.rewind()
        guard r.magic(Array("FORM".utf8)) else { return nil }
        _ = r.u32be()
        let kind = r.u32be()
        let svx = SymMODBytes.id("8SVX"), sv16 = SymMODBytes.id("16SV"), maud = SymMODBytes.id("MAUD")
        guard kind == svx || kind == sv16 || kind == maud else { return nil }
        var parts: [(id: UInt32, data: SymMODBytes)] = []
        // (A BODY of no length is as long as the rest of the file, in a broken file.)
        while r.canRead(8) {
            let id = r.u32be()
            var size = SymMODBytes.length(r.u32be())
            if size == 0, id == SymMODBytes.id("BODY") { size = Int.max }
            parts.append((id, r.chunk(size)))
            if size % 2 != 0 { r.skip(1) }
        }
        func part(_ name: String) -> SymMODBytes { parts.first { $0.id == SymMODBytes.id(name) }?.data ?? .none }

        var layout = Layout(bigEndian: true)
        var data: SymMODBytes
        var frames = 0, loopStart = 0, loopLength = 0, volume = 0
        if kind == maud {
            var header = part("MHDR")
            data = part("MDAT")
            guard header.length == 32, data.isValid else { return nil }
            frames = SymMODBytes.length(header.u32be())
            let bits = header.u16be()
            header.skip(2)
            _ = header.u32be()
            let divide = header.u16be(), information = header.u16be(), channels = header.u16be(), compression = header.u16be()
            guard divide != 0, channels == information + 1 else { return nil }
            layout.stereo = channels == 2
            if bits == 8, compression == 0 {
                layout.unsigned = true
            } else if bits == 16, compression == 0 {
                layout.sixteen = true
            } else if bits == 8, compression == 2 || compression == 3 {
                // (Its A-law and µ-law are not read.)
                return unreadSound
            } else {
                return nil
            }
        } else {
            var header = part("VHDR")
            var channel = part("CHAN")
            data = part("BODY")
            guard data.isValid, header.length >= 20 else { return nil }
            let oneShot = Int(header.u32be()), repeats = Int(header.u32be()), cycle = Int(header.u32be())
            _ = header.u16be()
            header.skip(2)
            volume = Int(min(header.u32be(), 0x7FFF_FFFF))
            layout.sixteen = kind == sv16
            layout.stereo = channel.u32be() == 6
            layout.split = true
            let frameBytes = (layout.sixteen ? 2 : 1) * (layout.stereo ? 2 : 1)
            loopStart = oneShot / frameBytes
            // (A cycle of more than 32 that the repeat is a whole number of is the loop.)
            loopLength = cycle > 32 && cycle < repeats && repeats % cycle == 0 ? cycle / frameBytes : repeats / frameBytes
            frames = data.length / frameBytes
        }
        var sound = SymMODSound()
        sound.length = frames
        if loopStart + 4 < loopStart + loopLength, loopStart + loopLength <= frames {
            sound.loops = true
            sound.loopStart = loopStart
            sound.loopEnd = loopStart + loopLength
        }
        sound.volume = (volume + 128) / 256
        if sound.volume == 0 || sound.volume > 256 { sound.volume = 256 }
        sound.read(&data, layout)
        sound.heldAtEnd()
        return sound
    }

    /// A WAV file. Nil if it is not one, or is of a kind that is not read here.
    static func wav(_ file: SymMODBytes) -> SymMODSound? {
        var r = file
        r.rewind()
        let magic = r.u32be()
        _ = r.u32le()
        let kind = r.u32be()
        guard magic == SymMODBytes.id("RIFF") || magic == SymMODBytes.id("LIST"), kind == SymMODBytes.id("WAVE") || kind == SymMODBytes.id("wave") else { return nil }
        let headerEnd = r.at
        var parts = r.parts(bigEndian: false)
        // (A file whose data part has an odd length and no byte after it, as some write them.)
        if parts.count >= 4, parts[1].id == SymMODBytes.id("data"), parts[1].data.length % 2 != 0, parts[2].data.length == 0, parts[3].id == SymMODBytes.id("    ") {
            r.at = headerEnd
            parts = r.parts(bigEndian: false, align: 1)
        }
        func part(_ name: String) -> SymMODBytes { parts.first { $0.id == SymMODBytes.id(name) }?.data ?? .none }
        var format = part("fmt ")
        guard format.length >= 16 else { return nil }
        let tag = format.u16le(), channels = format.u16le()
        _ = format.u32le()
        _ = format.u32le()
        let blockAlign = format.u16le(), bits = format.u16le()
        // (The kinds OpenMPT reads: PCM, floating point, IMA's ADPCM, MP3, A-law and µ-law, or any of
        // them in the "extensible" kind. Of them only PCM of eight or sixteen bits is read here: no
        // file to hand has any other.)
        let pcm = 1, float = 3, adpcm = 0x11, mp3 = 0x55, aLaw = 6, uLaw = 7, extensible = 0xFFFE
        let known = [pcm, float, adpcm, mp3, aLaw, uLaw]
        guard channels >= 1, channels <= 2, bits != 0 || tag == mp3, bits >= 32 || tag != float, bits <= 64, known.contains(tag) || tag == extensible else { return nil }
        guard tag == pcm, bits <= 16 else { return unreadSound }
        var data = part("data")
        if !data.isValid { data = part("pcm ") }
        let pointSize = (channels * bits + 7) / 8
        var frames = 0
        if pointSize != 0 {
            frames = blockAlign == 0 || blockAlign / channels >= 2 * pointSize ? data.length / pointSize : data.length / blockAlign
        }
        var sound = SymMODSound()
        sound.length = frames
        // What OpenMPT's own WAV files say of a sample besides its sound.
        var extra = part("xtra")
        if extra.length >= 16 {
            _ = extra.u32le()
            _ = extra.u16le()
            sound.volume = min(extra.u16le(), 256)
            sound.globalVolume = min(extra.u16le(), 64)
            _ = extra.u16le()
            sound.vibratoType = extra.u8()
            sound.vibratoSweep = extra.u8()
            sound.vibratoDepth = extra.u8()
            sound.vibratoRate = extra.u8()
        }
        sound.read(&data, Layout(sixteen: bits > 8, stereo: channels > 1, unsigned: bits <= 8))
        sound.heldAtEnd()
        return sound
    }

    /// An AIFF or AIFF-C file. Nil if it is not one, or is of a kind that is not read here.
    static func aiff(_ file: SymMODBytes) -> SymMODSound? {
        var r = file
        r.rewind()
        guard r.magic(Array("FORM".utf8)) else { return nil }
        _ = r.u32be()
        let kind = r.u32be()
        guard kind == SymMODBytes.id("AIFF") || kind == SymMODBytes.id("AIFC") else { return nil }
        let parts = r.parts(bigEndian: true)
        func part(_ name: String) -> SymMODBytes { parts.first { $0.id == SymMODBytes.id(name) }?.data ?? .none }
        var common = part("COMM")
        guard common.length >= 18 else { return nil }
        let channels = common.u16be()
        let frames = SymMODBytes.length(common.u32be())
        let bits = common.u16be()
        common.skip(10)
        guard frames != 0, channels >= 1, channels <= 2, bits >= 1, bits <= 64 else { return nil }
        var layout = Layout(sixteen: bits > 8, stereo: channels == 2, bigEndian: true)
        if kind == SymMODBytes.id("AIFC") {
            guard common.canRead(4) else { return nil }
            let compression = common.u32be()
            if compression == SymMODBytes.id("twos") {
                layout.bigEndian = false
            } else if compression == SymMODBytes.id("raw ") {
                layout.unsigned = true
            } else if ["fl32", "FL32", "fl64", "FL64", "alaw", "ALAW", "ulaw", "ULAW"].contains(where: { SymMODBytes.id($0) == compression }) {
                // (Floating point, A-law and µ-law are not read here.)
                return unreadSound
            }
        }
        // (Nor more than sixteen bits: no file to hand has any of these.)
        guard bits <= 16 else { return unreadSound }
        var sound = part("SSND")
        guard sound.length >= 8 else { return nil }
        let offset = SymMODBytes.length(sound.u32be())
        _ = sound.u32be()
        if sound.canRead(offset) { sound.skip(offset) }
        var made = SymMODSound()
        made.length = frames
        made.read(&sound, layout)
        made.heldAtEnd()
        return made
    }

    /// A sample of a kind that is not read.
    private static var unreadSound: SymMODSound {
        var sound = SymMODSound()
        sound.unread = true
        return sound
    }

    /// What Symphonie itself writes: Maestro's sixteen bits, or "16BT", or else eight bits and no
    /// more. Nil only if there was nothing to read.
    static func raw(_ file: SymMODBytes) -> SymMODSound? {
        var r = file
        r.rewind()
        var layout = Layout(sixteen: true, bigEndian: true)
        var nought = 0
        if r.magic(Array("MAESTRO".utf8)) {
            r.seek(12)
            if r.u32be() == 0 { layout.stereo = true }
            r.seek(24)
        } else if r.magic(Array("16BT".utf8)) {
            r.rewind()
            // (Symphonie's way of starting a sound smoothly would see to these.)
            nought = 4
        } else {
            layout.sixteen = false
        }
        var sound = SymMODSound()
        sound.length = r.left / ((layout.stereo ? 2 : 1) * (layout.sixteen ? 2 : 1))
        guard sound.read(&r, layout) > 0 else { return nil }
        for i in 0 ..< min(nought / 2, sound.words.count) { sound.words[i] = 0 }
        return sound
    }

    /// The sound of a sample of two sides as two of one: the left and the right.
    func split() -> (left: SymMODSound, right: SymMODSound) {
        var left = self, right = self
        left.stereo = false
        right.stereo = false
        if sixteen {
            left.words = (0 ..< length).map { words[$0 * 2] }
            right.words = (0 ..< length).map { words[$0 * 2 + 1] }
        } else {
            left.bytes = (0 ..< length).map { bytes[$0 * 2] }
            right.bytes = (0 ..< length).map { bytes[$0 * 2 + 1] }
        }
        left.heldAtEnd()
        right.heldAtEnd()
        return (left, right)
    }

    // MARK: What is done to the sound

    /// Played backwards, frame by frame.
    mutating func reverse() {
        guard hasData, length >= 2 else { return }
        if sixteen {
            if stereo { reverseFrames(&words, 2) } else { words.reverse() }
        } else {
            if stereo { reverseFrames(&bytes, 2) } else { bytes.reverse() }
        }
        heldAtEnd()
    }

    private func reverseFrames<T>(_ points: inout [T], _ width: Int) {
        var a = 0, b = length - 1
        while a < b {
            for k in 0 ..< width { points.swapAt(a * width + k, b * width + k) }
            a += 1
            b -= 1
        }
    }

    /// Turned upside down, as OpenMPT does it: each point's bits the other way.
    mutating func invert() {
        guard hasData else { return }
        if sixteen {
            for i in words.indices { words[i] = ~words[i] }
        } else {
            for i in bytes.indices { bytes[i] = ~bytes[i] }
        }
        heldAtEnd()
    }

    /// Eight bits made sixteen, in new memory.
    mutating func widen() {
        guard !sixteen else { return }
        words = bytes.map { Int16($0) << 8 }
        bytes = []
        sixteen = true
        replaced()
    }
}
