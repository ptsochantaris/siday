// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from it2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md): his C port of the replayer of Impulse Tracker 2.15, made from that tracker's
// own assembly. The names are the original's, as in the other ports here.

/// The file as the loader reads it: a place in it that moves as it is read, and that stops at the
/// end. Being at the end is its own condition, as it is in the original: a read that starts there
/// reads nothing, and one that runs into it gets what there was.
private struct IT2MemoryFile {
    let data: [UInt8]
    private(set) var position = 0

    init(_ data: [UInt8]) {
        self.data = data
    }

    /// True once a seek or a read has reached the end.
    var eof: Bool { position >= data.count }

    /// Goes to a place counted from the start; one beyond the end is the end.
    mutating func seek(_ offset: UInt64) {
        position = offset >= UInt64(data.count) ? data.count : Int(offset)
    }

    /// Goes forward; past the end is the end.
    mutating func skip(_ count: Int) {
        let left = data.count - position
        position = count >= left ? data.count : position + count
    }

    /// Copies out as many bytes as there are, up to `count`, and says how many that was.
    mutating func read(_ count: Int, into destination: UnsafeMutableRawPointer) -> Int {
        guard !eof, count > 0 else { return 0 }
        let n = min(count, data.count - position)
        data.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress! + position, byteCount: n) }
        position += n
        return n
    }

    /// Passes over `count` bytes and says where they began, or nil if they are not all there, in
    /// which case what there was of them has been passed over all the same.
    private mutating func take(_ count: Int) -> Int? {
        if eof { return nil }
        let at = position
        if count > data.count - position {
            position = data.count
            return nil
        }
        position += count
        return at
    }

    /// Where the next `count` bytes are, having passed over them; a file without them all is refused.
    mutating func bytes(_ count: Int) throws -> Int {
        guard let at = take(count) else { throw IT2Module.cutShort }
        return at
    }

    mutating func u8() throws -> UInt8 {
        try data[bytes(1)]
    }

    mutating func u16() throws -> UInt16 {
        let at = try bytes(2)
        return UInt16(data[at]) | UInt16(data[at + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        let at = try bytes(4)
        return UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24
    }

    /// For the reads whose failure the original does not look at.
    mutating func u16IfThere() -> UInt16? {
        guard let at = take(2) else { return nil }
        return UInt16(data[at]) | UInt16(data[at + 1]) << 8
    }
}

/// An IT file as the replayer holds one: its header, its list of patterns to play, its instruments,
/// its samples unpacked and made signed, and its patterns still packed as the file has them.
///
/// Impulse Tracker has room for 100 instruments, 100 samples and 200 patterns. Trackers after it
/// wrote files with more, and those are taken too, as far as the file format can number them: an
/// instrument, a sample and a pattern are each named by a single byte, some of whose values mean
/// other things. A file that ends before something its header points at is refused, but one that
/// ends part of the way through a sample's sound is played with what there is of it.
final class IT2Module {
    static let MAX_PATTERNS = 200, MAX_SAMPLES = 100, MAX_INSTRUMENTS = 100, MAX_ORDERS = 256
    /// The most a file can have and be played: beyond Impulse Tracker's own, up to what a byte can name.
    static let mostPatterns = 254, mostSamples = 253, mostInstruments = 254
    /// Room is left before and after each sample's sound for the mixer to read past its ends.
    static let SMP_DAT_OFFSET = 8, SAMPLE_PAD_LENGTH = 16
    /// The slowest a song can start at.
    static let MIN_BPM: UInt8 = 31
    /// How much of a file its MIDI settings take: 9 commands, 16 macros for SFx and 128 for Zxx, each 32 characters.
    static let midiDataLength = (9 + 16 + 128) * 32

    fileprivate static var cutShort: TuneError { .malformed("an IT file that ends too soon") }

    let title: String
    /// What wrote the file, as far as its header says. (Other programs write Impulse Tracker's own
    /// numbers there, so this is what the file claims and no more.)
    let madeWith: String
    // The header, by its own names.
    let OrdNum: Int, InsNum: Int, SmpNum: Int, PatNum: Int
    let Cwtv: UInt16, Cmwt: UInt16, Flags: UInt16, Special: UInt16
    let GlobalVol: UInt8, MixVolume: UInt8, InitialSpeed: UInt8, InitialTempo: UInt8, PanSep: UInt8
    let ChnlPan: [UInt8]
    let ChnlVol: [UInt8]
    /// Which pattern to play at each of 256 places; 255 ends the song, and fills the places the file leaves out.
    let Orders: [UInt8]
    /// The file's own MIDI settings, if it has them; they are what its Zxx and SFx effects send, which
    /// here means what they do to the filter. Nil for a file without them, which gets the tracker's.
    let midiData: [UInt8]?

    private let instruments: [IT2Instrument]
    private let samples: [IT2Sample]
    private let patterns: [[UInt8]?]
    private let rows: [UInt16]
    private let noInstrument = IT2Module.blankInstrument()

    /// How many samples and patterns there is room for: Impulse Tracker's 100 and 200, or as many as
    /// the file has if that is more. A number in the list of patterns at or beyond the second is a
    /// mark and not a pattern.
    var sampleLimit: Int { samples.count }
    var patternLimit: Int { patterns.count }
    /// The sample number that stands for a MIDI instrument's note on a channel, and the one that
    /// stands for it on a voice, which is one less. Impulse Tracker has 101 and 100, just past its
    /// samples; in a file with more samples than that they are 255 and 254, which no sample has.
    var midiSample: UInt8 { samples.count > Self.MAX_SAMPLES ? 255 : 101 }
    var midiVoiceSample: UInt8 { samples.count > Self.MAX_SAMPLES ? 254 : 100 }

    /// True if notes play instruments; false if they play samples directly.
    var usesInstruments: Bool { Flags & ITF_INSTR_MODE != 0 }

    /// An instrument, counted from nought. One the file does not have is empty: it plays nothing.
    func instrument(_ index: Int) -> IT2Instrument {
        index >= 0 && index < instruments.count ? instruments[index] : noInstrument
    }

    /// A sample, counted from nought. One the file does not have has no sound and no length; there
    /// is none beyond the hundredth.
    func sample(_ index: Int) -> IT2Sample? {
        index >= 0 && index < samples.count ? samples[index] : nil
    }

    /// A pattern, packed as the file has it, and how many rows it has. One the file does not have
    /// is the 64 rows of `EmptyPattern`.
    func pattern(_ index: Int) -> (data: [UInt8], rows: UInt16) {
        guard index >= 0, index < patterns.count, let data = patterns[index] else { return (Self.EmptyPattern, 64) }
        return (data, rows[index])
    }

    /// True if the file has this pattern; false if `pattern` gives the empty one in its place.
    func hasPattern(_ index: Int) -> Bool {
        index >= 0 && index < patterns.count && patterns[index] != nil
    }

    /// What is played for a pattern that is not there. Its first eight bytes are the heading a
    /// pattern has in Impulse Tracker's memory (its length, 64, and its rows, 64), which the port this
    /// is made from keeps although it reads a pattern from its first byte: so the first two rows are
    /// not quite empty. Each names channel 64 with nothing new, and what that channel last had is
    /// read again from the bytes that follow. The rows after them are empty.
    static let EmptyPattern: [UInt8] = [64, 0, 64, 0, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 64)

    init(_ data: [UInt8]) throws {
        // A file packed with MMCMP says so with "ziRCONia", whatever kind of module is inside.
        if data.count >= 8, data.starts(with: [0x7A, 0x69, 0x52, 0x43, 0x4F, 0x4E, 0x69, 0x61]) {
            throw TuneError.unsupported("a module packed with MMCMP")
        }
        guard data.count >= 4, data.starts(with: [0x49, 0x4D, 0x50, 0x4D]) else { // "IMPM"
            throw TuneError.malformed("not an IT file")
        }
        var m = IT2MemoryFile(data)

        // MARK: The header

        m.skip(4)
        _ = try m.bytes(25) // the song's name
        m.skip(1 + 2)
        let OrdNum = try Int(m.u16())
        let InsNum = try Int(m.u16())
        let SmpNum = try Int(m.u16())
        let PatNum = try Int(m.u16())
        let Cwtv = try m.u16()
        let Cmwt = try m.u16()
        let Flags = try m.u16()
        let Special = try m.u16()
        GlobalVol = try m.u8()
        MixVolume = try m.u8()
        InitialSpeed = try m.u8()
        let InitialTempo = try m.u8()
        PanSep = try m.u8()
        m.skip(1)
        _ = try m.u16() // the length of the song's message
        _ = try m.u32() // and where it is
        m.skip(4)
        let panAt = try m.bytes(MAX_HOST_CHANNELS)
        ChnlPan = Array(data[panAt ..< panAt + MAX_HOST_CHANNELS])
        let volAt = try m.bytes(MAX_HOST_CHANNELS)
        ChnlVol = Array(data[volAt ..< volAt + MAX_HOST_CHANNELS])

        // (Impulse Tracker does not look; it has no need to, having written the file.)
        guard OrdNum <= Self.MAX_ORDERS + 1, InsNum <= Self.mostInstruments, SmpNum <= Self.mostSamples, PatNum <= Self.mostPatterns else {
            throw TuneError.unsupported("an IT file with more orders, instruments, samples or patterns than an IT file can number")
        }
        self.OrdNum = OrdNum
        self.InsNum = InsNum
        self.SmpNum = SmpNum
        self.PatNum = PatNum
        self.Cwtv = Cwtv
        self.Cmwt = Cmwt
        self.Flags = Flags
        self.Special = Special
        // A file can say 31, which the tracker itself cannot be set to, and nothing lower will do.
        self.InitialTempo = max(InitialTempo, Self.MIN_BPM)
        title = ByteReader(data).ascii(at: 4, length: 25)
        madeWith = Self.tracker(Cwtv: Cwtv, Cmwt: Cmwt)

        // The list of patterns to play. The count of them includes the 255 that ends the list,
        // which is not read.
        var Orders = [UInt8](repeating: 255, count: Self.MAX_ORDERS)
        let OrdersToLoad = OrdNum - 1
        if OrdersToLoad > 0 {
            let at = try m.bytes(OrdersToLoad)
            for i in 0 ..< OrdersToLoad { Orders[i] = data[at + i] }
        }
        self.Orders = Orders

        // After the header come the list and then three tables of where things are in the file:
        // instruments, samples, patterns.
        let PtrListOffset = 192 + OrdNum
        m.seek(UInt64(PtrListOffset + (InsNum + SmpNum + PatNum) * 4))

        // A history of when the file was worked on, to be passed over.
        if Special & 2 != 0, let NumTimerData = m.u16IfThere() { m.skip(Int(NumTimerData) * 8) }

        // The MIDI settings. Of a file that ends part of the way through them, what there is
        // replaces as much of the tracker's own.
        var midiData: [UInt8]?
        if Special & 8 != 0, !m.eof {
            var area = [UInt8](repeating: 0, count: Self.midiDataLength)
            let got = area.withUnsafeMutableBytes { m.read(Self.midiDataLength, into: $0.baseAddress!) }
            if got < Self.midiDataLength {
                var whole = Self.defaultMIDIData()
                for i in 0 ..< got { whole[i] = area[i] }
                area = whole
            }
            midiData = area
        }
        self.midiData = midiData

        // (The song's message is not kept.)

        // MARK: Instruments

        let instruments = (0 ..< max(Self.MAX_INSTRUMENTS, InsNum)).map { _ in Self.blankInstrument() }
        for i in 0 ..< InsNum {
            m.seek(UInt64(PtrListOffset + i * 4))
            if m.eof { throw Self.cutShort }
            let InsOffset = try m.u32()
            if InsOffset == 0 { continue }
            m.seek(UInt64(InsOffset))
            if m.eof { throw Self.cutShort }
            if Cmwt >= 0x200 {
                try Self.readInstrument(&m, instruments[i])
            } else {
                try Self.readOldInstrument(&m, instruments[i])
            }
        }
        self.instruments = instruments

        // MARK: Samples

        let SmpPtrOffset = PtrListOffset + InsNum * 4
        let samples = (0 ..< max(Self.MAX_SAMPLES, SmpNum)).map { _ in IT2Sample() }
        for i in 0 ..< SmpNum {
            m.seek(UInt64(SmpPtrOffset + i * 4))
            if m.eof { throw Self.cutShort }
            let SmpOffset = try m.u32()
            if SmpOffset == 0 { continue }
            m.seek(UInt64(SmpOffset))
            if m.eof { throw Self.cutShort }

            let s = samples[i]
            m.skip(4)
            _ = try m.bytes(13) // its file's name
            s.GlobVol = try m.u8()
            s.Flags = try m.u8()
            s.Vol = try m.u8()
            _ = try m.bytes(26) // its name
            s.Cvt = try m.u8()
            s.DefPan = try m.u8()
            s.Length = try m.u32()
            s.LoopBegin = try m.u32()
            s.LoopEnd = try m.u32()
            s.C5Speed = try m.u32()
            s.SustainLoopBegin = try m.u32()
            s.SustainLoopEnd = try m.u32()
            s.OffsetInFile = try m.u32()
            s.AutoVibratoSpeed = try m.u8()
            s.AutoVibratoDepth = try m.u8()
            s.AutoVibratoRate = try m.u8()
            s.AutoVibratoWaveform = try m.u8()
        }

        // Their sound. No real file's samples come to more than this, uncompressed ones being in
        // the file byte for byte and compressed ones at no less than a bit for each sample; a file
        // that asks for more is asking for memory there is nothing to fill with.
        var budget = UInt64(data.count) * 64 + (16 << 20)
        for i in 0 ..< SmpNum {
            let s = samples[i]
            if s.OffsetInFile == 0 || s.Flags & SMPF_ASSOCIATED_WITH_HEADER == 0 { continue }
            // A sample whose sound would begin at or beyond the end of the file has none. (The player
            // this is ported from gives up on the whole file there, even for a sample of no length,
            // which is how ModPlug Tracker wrote its empty ones: one file in twenty-five.)
            m.seek(UInt64(s.OffsetInFile))
            if m.eof { continue }

            let Stereo = s.Flags & SMPF_STEREO != 0
            let Compressed = s.Flags & SMPF_COMPRESSED != 0
            let Sample16Bit = s.Flags & SMPF_16BIT != 0
            let SignedSamples = s.Cvt & 1 != 0
            let DeltaEncoded = s.Cvt & 4 != 0

            // These are left with the length they claim and no sound: a sample kept as differences
            // without being compressed, an empty one, and one in a form that is not handled (its
            // bytes the other way round, and stranger things).
            if DeltaEncoded, !Compressed { continue }
            if s.Length == 0 { continue }
            if s.Cvt & 0b1111_1010 != 0 { continue }

            // From here until the sound is in, `Length` counts bytes; the original doubles it in
            // 32 bits, so an absurd length wraps round.
            let length32 = Sample16Bit ? s.Length &<< 1 : s.Length
            let needed = (UInt64(length32) + UInt64(Self.SAMPLE_PAD_LENGTH)) * (Stereo ? 2 : 1)
            guard length32 <= 0x3FFF_FFF0, needed <= budget else {
                throw TuneError.malformed("an IT file with a sample longer than the file could hold")
            }
            budget -= needed
            let length = Int(length32)
            s.Length = length32

            let left = Self.allocate(length)
            s.OrigData = left
            s.Data = left + Self.SMP_DAT_OFFSET
            var right: UnsafeMutableRawPointer?
            if Stereo {
                let memory = Self.allocate(length)
                s.OrigDataR = memory
                s.DataR = memory + Self.SMP_DAT_OFFSET
                right = memory + Self.SMP_DAT_OFFSET
            }

            if Compressed {
                Self.LoadCompressedSample(&m, left + Self.SMP_DAT_OFFSET, right, length: length, Sample16Bit: Sample16Bit, DeltaEncoded: DeltaEncoded)
            } else {
                // The left of a stereo sample, whole, and then the right.
                _ = m.read(length, into: left + Self.SMP_DAT_OFFSET)
                if let right { _ = m.read(length, into: right) }
            }

            // An unsigned sample is made signed: the left of it only, as in the original, whose
            // stereo samples are an addition of its own.
            if !SignedSamples {
                let p = left + Self.SMP_DAT_OFFSET
                if Sample16Bit {
                    for j in 0 ..< length >> 1 {
                        p.storeBytes(of: p.load(fromByteOffset: j * 2, as: UInt16.self) ^ 0x8000, toByteOffset: j * 2, as: UInt16.self)
                    }
                } else {
                    for j in 0 ..< length {
                        p.storeBytes(of: p.load(fromByteOffset: j, as: UInt8.self) ^ 0x80, toByteOffset: j, as: UInt8.self)
                    }
                }
            }

            if Sample16Bit { s.Length >>= 1 } // and now it counts samples again
        }
        self.samples = samples

        // MARK: Patterns

        let PatPtrOffset = SmpPtrOffset + SmpNum * 4
        var patterns = [[UInt8]?](repeating: nil, count: max(Self.MAX_PATTERNS, PatNum))
        var rows = [UInt16](repeating: 0, count: max(Self.MAX_PATTERNS, PatNum))
        for i in 0 ..< PatNum {
            m.seek(UInt64(PatPtrOffset + i * 4))
            if m.eof { throw Self.cutShort }
            let PatOffset = try m.u32()
            if PatOffset == 0 { continue }
            m.seek(UInt64(PatOffset))
            if m.eof { throw Self.cutShort }

            let PatLength = try Int(m.u16())
            rows[i] = try m.u16() // (as many as it says: nothing holds it to the tracker's 200)
            if PatLength == 0 || rows[i] == 0 { continue }
            m.skip(4)
            let at = try m.bytes(PatLength)
            patterns[i] = Array(data[at ..< at + PatLength])
        }
        self.patterns = patterns
        self.rows = rows
    }

    // MARK: Instruments

    /// An instrument with nothing in it, which is what the replayer has for one the file leaves out.
    private static func blankInstrument() -> IT2Instrument {
        let ins = IT2Instrument()
        ins.PitchPanCenter = 0
        ins.GlobVol = 0
        ins.DefPan = 0
        return ins
    }

    /// The table of which note and sample each of 120 notes plays.
    private static func readSmpNoteTable(_ m: inout IT2MemoryFile, _ ins: IT2Instrument) throws {
        let at = try m.bytes(2 * 120)
        for k in 0 ..< 120 { ins.SmpNoteTable[k] = UInt16(m.data[at + k * 2]) | UInt16(m.data[at + k * 2 + 1]) << 8 }
    }

    private static func readEnvelope(_ m: inout IT2MemoryFile) throws -> IT2Envelope {
        var env = IT2Envelope()
        env.Flags = try m.u8()
        env.Num = try m.u8()
        env.LoopBegin = try m.u8()
        env.LoopEnd = try m.u8()
        env.SustainLoopBegin = try m.u8()
        env.SustainLoopEnd = try m.u8()
        for k in 0 ..< 25 {
            env.Magnitude[k] = try Int8(bitPattern: m.u8())
            env.Tick[k] = try m.u16()
        }
        m.skip(1)
        return env
    }

    /// An instrument as Impulse Tracker 2 writes it.
    private static func readInstrument(_ m: inout IT2MemoryFile, _ ins: IT2Instrument) throws {
        m.skip(4)
        _ = try m.bytes(13) // its file's name
        ins.NNA = try m.u8()
        ins.DCT = try m.u8()
        ins.DCA = try m.u8()
        ins.FadeOut = try m.u16()
        ins.PitchPanSep = try m.u8()
        ins.PitchPanCenter = try m.u8()
        ins.GlobVol = try m.u8()
        ins.DefPan = try m.u8()
        ins.RandVol = try m.u8()
        ins.RandPan = try m.u8()
        m.skip(4)
        _ = try m.bytes(26) // its name
        ins.FilterCutoff = try m.u8()
        ins.FilterResonance = try m.u8()
        ins.MIDIChn = try m.u8()
        ins.MIDIProg = try m.u8()
        ins.MIDIBank = try m.u16()
        try readSmpNoteTable(&m, ins)
        ins.VolEnv = try readEnvelope(&m)
        ins.PanEnv = try readEnvelope(&m)
        ins.PitchEnv = try readEnvelope(&m)
    }

    /// An instrument as Impulse Tracker 1 wrote it: one envelope, for volume, its points a tick and a
    /// level in a byte each and ended by 0xFFFF; a fade half as fine; and none of the rest, which is
    /// given what the tracker gives a new instrument.
    private static func readOldInstrument(_ m: inout IT2MemoryFile, _ ins: IT2Instrument) throws {
        m.skip(4)
        _ = try m.bytes(13) // its file's name
        ins.VolEnv.Flags = try m.u8()
        ins.VolEnv.LoopBegin = try m.u8()
        ins.VolEnv.LoopEnd = try m.u8()
        ins.VolEnv.SustainLoopBegin = try m.u8()
        ins.VolEnv.SustainLoopEnd = try m.u8()
        m.skip(2)
        ins.FadeOut = try m.u16()
        ins.NNA = try m.u8()
        ins.DCT = try m.u8()
        m.skip(4)
        _ = try m.bytes(26) // its name
        m.skip(6)
        try readSmpNoteTable(&m, ins)

        ins.FadeOut = ins.FadeOut &* 2
        ins.PitchPanCenter = 60
        ins.GlobVol = 128
        ins.DefPan = 32 + 128 // the middle, and not used

        m.skip(200) // the envelope worked out for every tick, which the old replayer played from

        var j = 0
        while j < 25 {
            let word = try m.u16()
            if word == 0xFFFF { break }
            ins.VolEnv.Tick[j] = word & 0xFF
            ins.VolEnv.Magnitude[j] = Int8(truncatingIfNeeded: word >> 8)
            j += 1
        }
        ins.VolEnv.Num = UInt8(j)

        ins.PanEnv.Num = 2
        ins.PanEnv.Tick[1] = 99
        ins.PitchEnv.Num = 2
        ins.PitchEnv.Tick[1] = 99
    }

    // MARK: Samples

    /// Room for a sample's sound of `length` bytes and what goes either side of it, all of it nought.
    private static func allocate(_ length: Int) -> UnsafeMutableRawPointer {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: length + SAMPLE_PAD_LENGTH, alignment: 16)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: length + SAMPLE_PAD_LENGTH)
        return memory
    }

    /// How much packed data a block of a compressed sample can have.
    private static let decompBufferLength = 65536

    /// Unpacks a sample compressed as Impulse Tracker 2.14 and 2.15 compress them: in blocks that
    /// unpack to 32,768 bytes, each with its packed length before it; all of the left of a stereo
    /// sample and then all of the right.
    ///
    /// Nothing here fails. Where the file ends, the blocks still to come are unpacked from what
    /// the block before left behind, as the original does, and so is whatever a block reads beyond
    /// its own packed length.
    private static func LoadCompressedSample(_ m: inout IT2MemoryFile, _ left: UnsafeMutableRawPointer, _ right: UnsafeMutableRawPointer?,
                                             length: Int, Sample16Bit: Bool, DeltaEncoded: Bool) {
        // (With a little more than is ever filled, so that the last of it can be read four bytes at a time.)
        let DecompBuffer = UnsafeMutableRawPointer.allocate(byteCount: decompBufferLength + 4, alignment: 4)
        DecompBuffer.initializeMemory(as: UInt8.self, repeating: 0, count: decompBufferLength + 4)
        defer { DecompBuffer.deallocate() }

        for channel in 0 ..< 2 {
            guard let base = channel == 0 ? left : right else { break }
            var done = 0
            while done < length {
                let BytesToUnpack = min(32768, length - done)
                if let PackedLen = m.u16IfThere() { _ = m.read(Int(PackedLen), into: DecompBuffer) }
                let DstPtr = base + done

                if Sample16Bit {
                    Decompress16BitData(DstPtr, DecompBuffer, BytesToUnpack)
                    if DeltaEncoded { // differences of differences (IT 2.15): summed again, from nought in every block
                        var LastSmp16: UInt16 = 0
                        for j in 0 ..< BytesToUnpack >> 1 {
                            LastSmp16 &+= DstPtr.load(fromByteOffset: j * 2, as: UInt16.self)
                            DstPtr.storeBytes(of: LastSmp16, toByteOffset: j * 2, as: UInt16.self)
                        }
                    }
                } else {
                    Decompress8BitData(DstPtr, DecompBuffer, BytesToUnpack)
                    if DeltaEncoded {
                        var LastSmp8: UInt8 = 0
                        for j in 0 ..< BytesToUnpack {
                            LastSmp8 &+= DstPtr.load(fromByteOffset: j, as: UInt8.self)
                            DstPtr.storeBytes(of: LastSmp8, toByteOffset: j, as: UInt8.self)
                        }
                    }
                }
                done += BytesToUnpack
            }
        }
    }

    // The packed data is a stream of bits: each sample is the difference from the one before, in a
    // number of bits that the stream itself changes as it goes, by values set aside to mean "from
    // here on, this many bits". Bad data can ask for any number of bits up to 255, which the
    // counters here follow as the original's do, wrapping round where its bytes wrap round. Data
    // read from beyond the buffer is nought, which always unpacks to a sample, so this ends.

    /// Unpacks one block of a sixteen-bit sample: `BlockLen` bytes of it.
    private static func Decompress16BitData(_ Dst: UnsafeMutableRawPointer, _ Src: UnsafeMutableRawPointer, _ BlockLen: Int) {
        var LastVal: UInt16 = 0
        var BitDepth: UInt8 = 17, BitDepthInv: UInt8 = 0, BitsRead: UInt8 = 0
        var src = 0, dst = 0

        var BlockLength = BlockLen >> 1
        while BlockLength != 0 {
            var Bytes32 = (src < decompBufferLength ? UInt32(littleEndian: Src.loadUnaligned(fromByteOffset: src, as: UInt32.self)) : 0) >> UInt32(BitsRead)

            BitsRead &+= BitDepth
            src += Int(BitsRead >> 3)
            BitsRead &= 7
            let shift = UInt32(BitDepthInv & 0x1F)

            if BitDepth <= 6 {
                Bytes32 <<= shift

                let Bytes16 = UInt16(truncatingIfNeeded: Bytes32)
                if Bytes16 != 0x8000 {
                    LastVal &+= UInt16(truncatingIfNeeded: Int32(Int16(bitPattern: Bytes16)) >> Int32(shift))
                    Dst.storeBytes(of: LastVal, toByteOffset: dst, as: UInt16.self)
                    dst += 2
                    BlockLength -= 1
                } else {
                    var Byte8 = UInt8(truncatingIfNeeded: (Bytes32 >> 16) & 0xF) &+ 1
                    if Byte8 >= BitDepth { Byte8 &+= 1 }
                    BitDepth = Byte8

                    BitDepthInv = 16
                    if BitDepthInv < BitDepth { BitDepthInv &+= 1 }
                    BitDepthInv &-= BitDepth

                    BitsRead &+= 4
                }
                continue
            }

            var Bytes16 = UInt16(truncatingIfNeeded: Bytes32)

            if BitDepth <= 16 {
                var DX = UInt16(truncatingIfNeeded: UInt32(0xFFFF) >> shift)
                Bytes16 &= DX
                DX = (DX >> 1) &- 8

                if Int32(Bytes16) > Int32(DX) + 16 || Bytes16 <= DX {
                    Bytes16 = UInt16(truncatingIfNeeded: UInt32(Bytes16) << shift)
                    Bytes16 = UInt16(truncatingIfNeeded: Int32(Int16(bitPattern: Bytes16)) >> Int32(shift))
                    LastVal &+= Bytes16
                    Dst.storeBytes(of: LastVal, toByteOffset: dst, as: UInt16.self)
                    dst += 2
                    BlockLength -= 1
                    continue
                }

                var Byte8 = UInt8(truncatingIfNeeded: Bytes16 &- DX)
                if Byte8 >= BitDepth { Byte8 &+= 1 }
                BitDepth = Byte8

                BitDepthInv = 16
                if BitDepthInv < BitDepth { BitDepthInv &+= 1 }
                BitDepthInv &-= BitDepth
                continue
            }

            if Bytes32 & 0x10000 != 0 {
                BitDepth = UInt8(truncatingIfNeeded: Bytes16 &+ 1)
                BitDepthInv = 16 &- BitDepth
            } else {
                LastVal &+= Bytes16
                Dst.storeBytes(of: LastVal, toByteOffset: dst, as: UInt16.self)
                dst += 2
                BlockLength -= 1
            }
        }
    }

    /// Unpacks one block of an eight-bit sample: `BlockLen` bytes of it.
    private static func Decompress8BitData(_ Dst: UnsafeMutableRawPointer, _ Src: UnsafeMutableRawPointer, _ BlockLen: Int) {
        var LastVal: UInt8 = 0
        var BitDepth: UInt8 = 9, BitDepthInv: UInt8 = 0, BitsRead: UInt8 = 0
        var src = 0, dst = 0

        var BlockLength = BlockLen
        while BlockLength != 0 {
            let word = src < decompBufferLength ? UInt16(littleEndian: Src.loadUnaligned(fromByteOffset: src, as: UInt16.self)) : 0
            var Bytes16 = word >> UInt16(BitsRead)

            BitsRead &+= BitDepth
            src += Int(BitsRead >> 3)
            BitsRead &= 7

            var Byte8 = UInt8(truncatingIfNeeded: Bytes16)
            let shift = UInt32(BitDepthInv & 0x1F)

            if BitDepth <= 6 {
                Bytes16 = UInt16(truncatingIfNeeded: UInt32(Bytes16) << shift)
                Byte8 = UInt8(truncatingIfNeeded: Bytes16)

                if Byte8 != 0x80 {
                    LastVal &+= UInt8(truncatingIfNeeded: Int32(Int8(bitPattern: Byte8)) >> Int32(shift))
                    Dst.storeBytes(of: LastVal, toByteOffset: dst, as: UInt8.self)
                    dst += 1
                    BlockLength -= 1
                    continue
                }

                Byte8 = UInt8(truncatingIfNeeded: (Bytes16 >> 8) & 7)
                BitsRead &+= 3
                src += Int(BitsRead >> 3)
                BitsRead &= 7
            } else if BitDepth == 8 {
                if Byte8 < 0x7C || Byte8 > 0x83 {
                    LastVal &+= Byte8
                    Dst.storeBytes(of: LastVal, toByteOffset: dst, as: UInt8.self)
                    dst += 1
                    BlockLength -= 1
                    continue
                }
                Byte8 &-= 0x7C
            } else if BitDepth < 8 {
                Byte8 <<= 1
                if Byte8 < 0x78 || Byte8 > 0x86 {
                    LastVal &+= UInt8(truncatingIfNeeded: Int32(Int8(bitPattern: Byte8)) >> Int32(shift))
                    Dst.storeBytes(of: LastVal, toByteOffset: dst, as: UInt8.self)
                    dst += 1
                    BlockLength -= 1
                    continue
                }
                Byte8 = (Byte8 >> 1) &- 0x3C
            } else {
                Bytes16 &= 0x1FF
                if Bytes16 & 0x100 == 0 {
                    LastVal &+= Byte8
                    Dst.storeBytes(of: LastVal, toByteOffset: dst, as: UInt8.self)
                    dst += 1
                    BlockLength -= 1
                    continue
                }
            }

            Byte8 &+= 1
            if Byte8 >= BitDepth { Byte8 &+= 1 }
            BitDepth = Byte8

            BitDepthInv = 8
            if BitDepthInv < BitDepth { BitDepthInv &+= 1 }
            BitDepthInv &-= BitDepth
        }
    }

    // MARK: The rest

    /// The tracker's own MIDI settings, which are what make Zxx and SFx work the filter. (The player
    /// has them too, for a file with none of its own; they are here for the file that ends part of
    /// the way through its own.)
    private static func defaultMIDIData() -> [UInt8] {
        var area = [UInt8](repeating: 0, count: midiDataLength)
        func put(_ slot: Int, _ text: String) {
            var at = slot * 32
            for byte in text.utf8 {
                area[at] = byte
                at += 1
            }
        }
        put(0, "FF")
        put(1, "FC")
        put(3, "9c n v")
        put(4, "9c n 0")
        put(7, "Bc 0 a 20 b")
        put(8, "Cc p")
        put(9, "F0F000z") // SF0: the cutoff
        for i in 0 ..< 16 { put(25 + i, "F0F001" + hex2(i * 8)) } // Z80 to Z8F: the resonance
        return area
    }

    /// A byte as two digits in base sixteen.
    private static func hex2(_ value: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for v in [(value >> 4) & 15, value & 15] { scalars.append(Unicode.Scalar(UInt8(v < 10 ? 48 + v : 55 + v))) }
        return String(scalars)
    }

    /// The name of what wrote a file, from the two versions in its header: of the tracker that made
    /// it, and of the oldest that can read it.
    private static func tracker(Cwtv: UInt16, Cmwt: UInt16) -> String {
        let minor = hex2(Int(Cwtv & 0xFF))
        // ModPlug Tracker gave itself away by pairs of versions Impulse Tracker never wrote.
        if Cwtv == 0x0214 && Cmwt == 0x0202 || Cwtv == 0x0217 && Cmwt == 0x0200 { return "ModPlug Tracker" }
        if Cwtv == 0x0888, Cmwt == 0x0888 { return "OpenMPT 1.17" }
        switch Cwtv >> 12 {
        // (The patches to 2.14, and 2.15 after them, counted on from 2.14 without saying which they were.)
        case 0 where Cwtv >= 0x0215 && Cwtv <= 0x0217: return "Impulse Tracker 2.14 or 2.15"
        case 0 where Cwtv >= 0x0100 && Cwtv <= 0x0214: return "Impulse Tracker \(Cwtv >> 8).\(minor)"
        case 1: return "Schism Tracker"
        case 5: return "OpenMPT \((Cwtv >> 8) & 0xF).\(minor)"
        default: return "Impulse Tracker"
        }
    }
}
