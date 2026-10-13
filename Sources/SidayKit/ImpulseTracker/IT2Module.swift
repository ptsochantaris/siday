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
    /// True for a file that says ModPlug Tracker or OpenMPT made it. Those trackers played some
    /// things otherwise than Impulse Tracker, and a file of theirs is played as they played it
    /// where that is known to matter: an instrument with a MIDI channel plays its sample.
    var madeByModPlug: Bool { madeWith.utf8.starts(with: "ModPlug".utf8) || madeWith.utf8.starts(with: "OpenMPT".utf8) }
    /// True if the file says Impulse Tracker itself made it.
    var madeByImpulseTracker: Bool { madeWith.utf8.starts(with: "Impulse Tracker".utf8) }
    /// Whose resonant filter a file was made to be heard through.
    ///
    /// ModPlug Tracker had a filter of its own, which rings less than Impulse Tracker's for the
    /// same setting and went by other rules: a note has it from its start only if its cutoff is
    /// below the top, and once a voice has it, by that or by a macro or an envelope, it keeps it
    /// until its next note, wide open and all, when it still takes the top off the sound at five
    /// kilohertz. OpenMPT kept that filter for the files made with it, and so does this: a file
    /// goes on sounding as it did to whoever made it. OpenMPT took up Impulse Tracker's filter in
    /// its version 1.20, for files that ask to be played as Impulse Tracker would play them; and
    /// even then it uses its own curve where a file asks for the wider range of cutoffs, which
    /// Impulse Tracker's has not.
    enum Filter {
        /// Impulse Tracker's.
        case impulseTrackers
        /// OpenMPT's curve, on and off as Impulse Tracker's is.
        case openMPTsCurve
        /// ModPlug Tracker's and OpenMPT's own.
        case openMPTs
    }

    /// The ways of ModPlug Tracker's and OpenMPT's own that a file of theirs is played in, where
    /// it does not ask for Impulse Tracker's. A file of any other tracker's has none of them.
    struct ModPlugWays {
        var filter = Filter.impulseTrackers
        /// True if a note's random swing of its filter is added to whatever the filter is set to
        /// while the note lasts, as OpenMPT had it before its version 1.17.02.50, and has it still
        /// for a file made then.
        var oldFilterSwing = false
        /// True if an envelope that is to carry on from the note before does so as ModPlug Tracker
        /// had it: not after a note whose key has been let go or that is fading, if the row names
        /// its instrument.
        var ownEnvelopeCarry = false
        /// True if a slide to a note on a row that names the instrument starts the instrument's
        /// envelopes again when it has none for volume, as it did before OpenMPT's version 1.19.
        var slideRestartsEnvelopes = false

        init() {}

        /// Those of a file that lists these of Impulse Tracker's ways (see `ModPlugExtras.behaviours`)
        /// and was last saved by this version of OpenMPT, a byte for each of its four parts.
        init(asked behaviours: [Bool], savedWith: Int, wideRange: Bool) {
            func listed(_ behaviour: Int) -> Bool { behaviour < behaviours.count && behaviours[behaviour] }
            // (Before there was a way to ask for each by itself, they all came with "compatible
            // play", each from the version of OpenMPT that first had it.)
            func asks(_ behaviour: Int, since: Int) -> Bool {
                if listed(Self.compatiblePlay), savedWith < 0x0126_0000 { return savedWith >= since || savedWith == since & 0x7FFF_0000 }
                return listed(behaviour)
            }
            filter = !asks(Self.filterBehaviour, since: 0x0120_0035) ? .openMPTs : wideRange ? .openMPTsCurve : .impulseTrackers
            oldFilterSwing = listed(Self.oldSwing)
            ownEnvelopeCarry = !asks(Self.envelopeReset, since: 0x0117_0251)
            slideRestartsEnvelopes = !asks(Self.portamentoInstrument, since: 0x0119_0001)
        }

        /// OpenMPT's numbers for the ways of playing that are looked at: "compatible play", its
        /// own old way with what is random in an instrument, and Impulse Tracker's ways with when
        /// an envelope starts again, with an instrument named beside a slide to a note, and with
        /// the filter.
        static let compatiblePlay = 0, oldSwing = 1, envelopeReset = 19, portamentoInstrument = 32, filterBehaviour = 36
    }

    let modPlug: ModPlugWays
    var filter: Filter { modPlug.filter }
    /// True for a module of a tracker in which a slide to a note, once begun, goes on by itself
    /// on the rows after, until it gets there or the channel has another note. UltraTracker's is one.
    var slidesToNotesCarryOn = false
    /// True for a module of a tracker in which an instrument named on a row with no note never
    /// started one, and was that instrument's volume and no more. Impulse Tracker starts the note
    /// again if the channel has stopped playing it.
    var instrumentAloneStartsNothing = false
    /// Where in the list a module of another tracker's goes on from when it has come to the end.
    /// (An MPTM file's songs each have their own: see `OpenMPTSong`.)
    var restartOrder = 0
    /// What a sample's header says of how it is kept when it is not a sound but a patch for the FM chip.
    static let adLibPatch: UInt8 = 0x40
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

    /// What an MPTM file says of its song that an IT file has no way to say: see `MPTMFile`. Nil for
    /// every other module, and nothing in the replayer that is for it is reached then.
    let openMPT: OpenMPTSong?
    /// What a file of ModPlug Tracker's or OpenMPT's has to be heard besides its samples, if it has
    /// any: plug-ins that are played, and instruments for the FM chip. Nil for every other module.
    let sound: ModPlugSound?
    /// For an IT file that ModPlug Tracker or OpenMPT made: which of OpenMPT's ways of adding the
    /// channels up it is played by (0 to 2 its oldest, which are quieter the more channels a song
    /// has; 3 that of its version 1.17, which is twice as loud; 4 and 5 those that are as loud as
    /// Impulse Tracker and FastTracker), and its "sample pre-amp", which is the header's mixing
    /// volume unless the file says more. Nil for any other file; and for an MPTM file, which says
    /// how loud it is for itself (see `OpenMPTSong.gain`). And how many channels the file says it
    /// has, which may be more than its patterns use; nought if it does not say. See
    /// `IT2Mixer.modPlugLevel`.
    private(set) var modPlugLevels: (mixLevels: Int, preAmp: Int, channels: Int)?

    private let instruments: [IT2Instrument]
    private let samples: [IT2Sample]
    private let patterns: [[UInt8]?]
    private let rows: [UInt16]
    private let noInstrument = IT2Module.blankInstrument()

    // What is found as a file is read that `shortfalls` is made from: none of it is played.
    /// The samples, counted from nought, whose sound is kept in a form that is not read.
    let samplesNotRead: [Int]
    /// The samples the file ends before the end of.
    let cutShort: Shortfall.CutShort
    /// The plug-ins ModPlug Tracker and OpenMPT put in a file, and what is played through them.
    let extras: ModPlugExtras

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

    /// - Parameter openMPT: true for the IT file that an MPTM file begins with, whose list of
    ///   patterns may be longer than Impulse Tracker's and is kept whole elsewhere in the file: as
    ///   much of it as there is room for is read here, and `MPTMFile` puts the whole in its place.
    init(_ data: [UInt8], openMPT: Bool = false) throws {
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
        guard OrdNum <= Self.MAX_ORDERS + 1 || openMPT, InsNum <= Self.mostInstruments, SmpNum <= Self.mostSamples, PatNum <= Self.mostPatterns else {
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
        madeWith = Self.tracker(Cwtv: Cwtv, Cmwt: Cmwt)
        // A title is in the letters of the system its tracker ran on: DOS, or for ModPlug Tracker, Windows.
        title = ByteReader(data).encoded(at: 4, length: 25, as: madeWith.utf8.starts(with: "ModPlug".utf8) || madeWith.utf8.starts(with: "OpenMPT".utf8) ? .windows1252 : .dos)

        // The list of patterns to play. The count of them includes the 255 that ends the list,
        // which is not read.
        var Orders = [UInt8](repeating: 255, count: Self.MAX_ORDERS)
        let OrdersToLoad = OrdNum - 1
        if OrdersToLoad > 0 {
            let at = try m.bytes(OrdersToLoad)
            for i in 0 ..< min(OrdersToLoad, Self.MAX_ORDERS) { Orders[i] = data[at + i] }
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

        // ModPlug Tracker and OpenMPT put their plug-ins here, before the first thing the header
        // points at, and what else they say of an instrument wherever it fits. (For `shortfalls`.)
        var extras = ModPlugExtras()
        let byModPlug = madeWith.utf8.starts(with: "ModPlug".utf8) || madeWith.utf8.starts(with: "OpenMPT".utf8)
        if byModPlug {
            let reader = ByteReader(data)
            var firstPointed = data.count
            for i in 0 ..< InsNum + SmpNum + PatNum {
                let high = reader.u16le(PtrListOffset + i * 4 + 2)
                let pointed = high >= 0x4000 ? data.count : high << 16 | reader.u16le(PtrListOffset + i * 4)
                if pointed > 0 { firstPointed = min(firstPointed, pointed) }
            }
            _ = extras.readPieces(reader, at: m.position, before: firstPointed)
            extras.readInstrumentExtras(reader, from: PtrListOffset, instruments: InsNum)
            extras.readSongExtras(reader)
        }

        let ways = Self.modPlugWays(data, Cwtv: Cwtv, Cmwt: Cmwt, OrdNum: OrdNum, extras: &extras, extrasRead: byModPlug)
        let wideRange = Flags & ITF_MPT_EXT_FILTER_RANGE != 0
        var modPlug = ModPlugWays()
        if let asked = ways.asked {
            modPlug = ModPlugWays(asked: asked, savedWith: ways.savedWith, wideRange: wideRange)
        } else if wideRange {
            modPlug.filter = .openMPTsCurve
        }

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
        // (An IT file has room in an instrument for a MIDI channel, and these two trackers put a
        // plug-in there: its number and 128.)
        for i in 0 ..< InsNum where instruments[i].MIDIChn > 128 && !extras.playsThroughPlugIn(instrument: i) {
            extras.set(plugIn: Int(instruments[i].MIDIChn) - 128, ofInstrument: i)
        }
        self.extras = extras

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
        var samplesNotRead: [Int] = []
        var cutShort = Shortfall.CutShort()
        for i in 0 ..< SmpNum {
            let s = samples[i]
            if s.OffsetInFile == 0 || s.Flags & SMPF_ASSOCIATED_WITH_HEADER == 0 { continue }
            // A sample whose sound would begin at or beyond the end of the file has none. (The player
            // this is ported from gives up on the whole file there, even for a sample of no length,
            // which is how ModPlug Tracker wrote its empty ones: one file in twenty-five.)
            m.seek(UInt64(s.OffsetInFile))
            if m.eof {
                cutShort.add(length: Int(min(s.Length, 1 << 28)), there: 0)
                continue
            }

            let Stereo = s.Flags & SMPF_STEREO != 0
            let Compressed = s.Flags & SMPF_COMPRESSED != 0
            let Sample16Bit = s.Flags & SMPF_16BIT != 0
            let SignedSamples = s.Cvt & 1 != 0
            let DeltaEncoded = s.Cvt & 4 != 0

            // These are left with the length they claim and no sound: a sample kept as differences
            // without being compressed, an empty one, and one in a form that is not handled (its
            // bytes the other way round, and stranger things).
            if s.Cvt == Self.adLibPatch, openMPT || byModPlug {
                // Not a sound at all, but a patch for the AdLib's FM chip, which OpenMPT can have
                // in a sample's place: twelve bytes.
                var patch = [UInt8](repeating: 0, count: 12)
                let got = patch.withUnsafeMutableBytes { m.read(12, into: $0.baseAddress!) }
                if got == 12 { s.AdLib = patch }
                continue
            }
            if s.Length != 0, (DeltaEncoded && !Compressed) || s.Cvt & 0b1111_1010 != 0 { samplesNotRead.append(i) }
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

            // (For `shortfalls`. A whole number in a browser has 32 bits: a length is kept within them.)
            let said = min(length, 1 << 29) * (Stereo ? 2 : 1)
            if Compressed {
                let unpacked = Self.LoadCompressedSample(&m, left + Self.SMP_DAT_OFFSET, right, length: length, Sample16Bit: Sample16Bit, DeltaEncoded: DeltaEncoded)
                cutShort.add(length: said, there: unpacked)
            } else {
                cutShort.add(length: said, there: data.count - m.position)
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
        self.samplesNotRead = samplesNotRead
        self.cutShort = cutShort

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
        self.openMPT = nil

        // (An OpenMPT that reads a file of before its version 1.17.02.50 with anything random
        // in its instruments plays what is random as it was played then.)
        if ways.savedWith < 0x0117_0250, (0 ..< InsNum).contains(where: { instruments[$0].RandVol | instruments[$0].RandPan != 0 }) || !extras.cutoffSwings.isEmpty
            || !extras.resonanceSwings.isEmpty {
            modPlug.oldFilterSwing = true
        }
        self.modPlug = modPlug

        // (And an envelope for pitch or the filter as it was played before 1.20, by a file that
        // did not ask for Impulse Tracker's ways, or asked before 1.17.03.02.)
        if let asked = ways.asked, ways.savedWith < 0x0120_0000 {
            let compatible = asked.first == true && !(ways.savedWith < 0x0117_0246 && ways.savedWith != 0x0117_0000)
            if !compatible || ways.savedWith < 0x0117_0302 {
                for i in 0 ..< InsNum {
                    instruments[i].PitchEnvAsModPlug = MPTMFile.asFastTrackerLooped(instruments[i].PitchEnv)
                    // (OpenMPT goes no further than the first instrument with anything random
                    // in it, in a file of before 1.17.02.50: the rest are left as they are.)
                    let random = instruments[i].RandVol | instruments[i].RandPan | (i < extras.cutoffSwings.count ? extras.cutoffSwings[i] : 0)
                        | (i < extras.resonanceSwings.count ? extras.resonanceSwings[i] : 0)
                    if ways.savedWith < 0x0117_0250, random != 0 { break }
                }
            }
        }

        // And what else an older OpenMPT meant differently by an instrument's or a sample's
        // numbers, which OpenMPT changes as it reads such a file: here they are kept beside the
        // file's own, for the replayer to choose between. (An MPTM file's are changed where it is
        // read: see `MPTMFile`, which this follows.)
        if let asked = ways.asked, Cmwt <= 0x888 {
            let saved = ways.savedWith
            let compatible = asked.first == true && !(saved < 0x0117_0246 && saved != 0x0117_0000)
            let oldSwing = asked.count > ModPlugWays.oldSwing && asked[ModPlugWays.oldSwing]
            for i in 0 ..< InsNum {
                let ins = instruments[i]
                var loudness = ins.RandVol, place = ins.RandPan, separation = ins.PitchPanSep
                if saved < 0x0120_0000 {
                    // The volume's random swing was of 64 and not of 100.
                    loudness = UInt8(min(100, Int(loudness) * 100 / 64))
                    if !compatible || saved < 0x0118_0000 { separation = MPTMFile.halved(separation) }
                }
                if saved < 0x0122_0312, saved != 0x0122_0000, compatible || oldSwing, ins.PanEnv.Flags & ENVF_ENABLED != 0 { place = 0 }
                if saved < 0x0126_0000 {
                    // How far higher notes go to one side was half as much, and the random swing
                    // of a note's place a quarter.
                    separation = MPTMFile.halved(separation)
                    if !compatible || saved < 0x0118_0000 { place = UInt8((Int(place) + 3) / 4) }
                }
                if loudness != ins.RandVol { ins.RandVolAsModPlug = loudness }
                if place != ins.RandPan { ins.RandPanAsModPlug = place }
                if separation != ins.PitchPanSep { ins.PitchPanSepAsModPlug = separation }
            }
            if saved < 0x0120_0000, saved < 0x0117_0302 || !compatible {
                // A sample's own vibrato that was to come in at once said so with nought.
                for s in samples.prefix(SmpNum) where s.AutoVibratoRate == 0 && (s.AutoVibratoDepth & 0x7F) | s.AutoVibratoSpeed != 0 {
                    s.AutoVibratoRateAsModPlug = 255
                }
            }
        }

        // How loud OpenMPT plays it, by which of its ways of adding up the file asks for: ModPlug
        // Tracker's own unless it says, for a file read as that tracker's, and the one that is
        // like Impulse Tracker's for any other that OpenMPT made. (See `MPTMFile`, where this is
        // told at length.)
        let mixLevels = extras.mixLevels ?? (ways.ownLevels ? 0 : 4)
        let preAmp = max(1, min(2000, extras.preAmp ?? Int(MixVolume)))
        if ways.asked != nil, Cmwt <= 0x888 { modPlugLevels = (mixLevels, preAmp, extras.channels) }

        // MARK: Plug-ins and FM

        // What a file of ModPlug Tracker's or OpenMPT's has to hear besides samples (see
        // `ModPlugSound`), if it has any: plug-ins that are OpenMPT's own, with something sent
        // through them, and patches for the FM chip.
        var sound = ModPlugSound()
        if byModPlug, !openMPT {
            sound.plugIns = extras.plugIns
            sound.channelPlugIns = Array(extras.channelPlugIns.prefix(MAX_HOST_CHANNELS))
            let plugInOf = (0 ..< InsNum).map { $0 < extras.instrumentPlugIns.count ? extras.instrumentPlugIns[$0] : 0 }
            for i in 0 ..< InsNum {
                instruments[i].MixPlug = UInt8(max(0, min(255, plugInOf[i])))
                if i < extras.cutoffSwings.count { instruments[i].CutSwing = extras.cutoffSwings[i] }
                if i < extras.filterModes.count, extras.filterModes[i] <= 1 { instruments[i].FilterMode = extras.filterModes[i] }
                if i < extras.resonanceSwings.count { instruments[i].ResSwing = extras.resonanceSwings[i] }
            }
            sound.level = Float(preAmp) / Float(min(preAmp, 128)) * (mixLevels == 3 ? 2 : 1)
            sound.levelIsTheMixers = mixLevels < 3
            sound.plugInScale = mixLevels == 0 ? 0.5 : mixLevels == 1 ? 1.0 / 16.0 : 1
            sound.globalVolumeAtMaster = mixLevels >= 2
            sound.adLibLevel = ModPlugSound.adLibLevel(synthVolume: extras.synthVolume ?? 48)
            if samples.contains(where: { $0.AdLib != nil }) { sound.adLib = OpenMPTAdLib.Behaviour() }
            self.sound = sound.adLib != nil || sound.sendsToPlugIns(instruments: plugInOf) ? sound : nil
        } else {
            self.sound = nil
        }
    }

    /// A module that did not come from an IT file: one of another tracker's, set down as Impulse
    /// Tracker would hold it so that this replayer can play it (see `IT2ForeignModule`). It has samples
    /// and no instruments, and none of what only an IT file can say.
    /// - Parameters:
    ///   - samples: as many as the replayer is to have room for, which is at least `MAX_SAMPLES`.
    ///   - patterns: packed as an IT file packs them, and `rows` how many rows each has; at least
    ///     `MAX_PATTERNS` of each.
    init(title: String, madeWith: String, orders: [UInt8], flags: UInt16, globalVolume: UInt8, mixVolume: UInt8, speed: UInt8, tempo: UInt8,
         channelPans: [UInt8], samples: [IT2Sample], patterns: [[UInt8]?], rows: [UInt16], slidesToNotesCarryOn: Bool = false,
         instrumentAloneStartsNothing: Bool = false, restart: Int = 0, sound: ModPlugSound? = nil) {
        self.slidesToNotesCarryOn = slidesToNotesCarryOn
        self.instrumentAloneStartsNothing = instrumentAloneStartsNothing
        restartOrder = restart < orders.count && orders[restart] < 200 ? restart : 0
        self.title = title
        self.madeWith = madeWith
        var Orders = [UInt8](repeating: 255, count: Self.MAX_ORDERS)
        for i in 0 ..< min(orders.count, Self.MAX_ORDERS) { Orders[i] = orders[i] }
        self.Orders = Orders
        OrdNum = min(orders.count, Self.MAX_ORDERS) + 1
        InsNum = 0
        SmpNum = samples.count
        PatNum = patterns.count
        // (Impulse Tracker 2.14's numbers, which nothing here takes to mean anything.)
        Cwtv = 0x0214
        Cmwt = 0x0200
        Flags = flags
        Special = 0
        GlobalVol = globalVolume
        MixVolume = mixVolume
        InitialSpeed = speed
        InitialTempo = max(tempo, Self.MIN_BPM)
        PanSep = 128
        var ChnlPan = [UInt8](repeating: 32 | 128, count: MAX_HOST_CHANNELS)
        for i in 0 ..< min(channelPans.count, MAX_HOST_CHANNELS) { ChnlPan[i] = channelPans[i] }
        self.ChnlPan = ChnlPan
        ChnlVol = [UInt8](repeating: 64, count: MAX_HOST_CHANNELS)
        midiData = nil
        instruments = (0 ..< Self.MAX_INSTRUMENTS).map { _ in Self.blankInstrument() }
        self.samples = samples
        self.patterns = patterns
        self.rows = rows
        samplesNotRead = []
        cutShort = Shortfall.CutShort()
        extras = ModPlugExtras()
        modPlug = ModPlugWays()
        openMPT = nil
        self.sound = sound
    }

    /// An MPTM file's module: what its IT file's part gave, which `file` is, with the list of
    /// patterns, the patterns and the settings that OpenMPT's own part of the file has in their
    /// place (see `MPTMFile`). The list may be longer than Impulse Tracker's 256 places. The samples
    /// and instruments are `file`'s own, changed where they stand before this is made.
    init(openMPT song: OpenMPTSong, sound: ModPlugSound?, file: IT2Module, madeWith: String, orders: [UInt8], mixVolume: UInt8, speed: UInt8, tempo: UInt8,
         channelPans: [UInt8], channelVolumes: [UInt8], patterns: [[UInt8]?], rows: [UInt16], ways: ModPlugWays) {
        self.sound = sound
        title = file.title
        self.madeWith = madeWith
        var Orders = [UInt8](repeating: 255, count: max(Self.MAX_ORDERS, orders.count + 1))
        for i in orders.indices { Orders[i] = orders[i] }
        self.Orders = Orders
        OrdNum = file.OrdNum
        InsNum = file.InsNum
        SmpNum = file.SmpNum
        PatNum = file.PatNum
        Cwtv = file.Cwtv
        Cmwt = file.Cmwt
        // (OpenMPT has no mono, and nothing that narrows the space between the speakers.)
        Flags = file.Flags | ITF_STEREO
        Special = file.Special
        GlobalVol = min(file.GlobalVol, 128)
        MixVolume = mixVolume
        InitialSpeed = speed
        InitialTempo = max(tempo, Self.MIN_BPM)
        PanSep = 128
        ChnlPan = channelPans
        ChnlVol = channelVolumes
        midiData = file.midiData
        instruments = file.instruments
        samples = file.samples
        self.patterns = patterns
        self.rows = rows
        modPlug = ways
        openMPT = song
        samplesNotRead = file.samplesNotRead
        cutShort = file.cutShort
        extras = file.extras
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
    static func allocate(_ length: Int) -> UnsafeMutableRawPointer {
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
    ///
    /// Says how many bytes were unpacked from what the file has: all of both sides, unless the
    /// file ended first. (Nothing that is unpacked goes by it.)
    @discardableResult
    private static func LoadCompressedSample(_ m: inout IT2MemoryFile, _ left: UnsafeMutableRawPointer, _ right: UnsafeMutableRawPointer?,
                                             length: Int, Sample16Bit: Bool, DeltaEncoded: Bool) -> Int {
        var fromTheFile = 0
        var ended = false
        // (With a little more than is ever filled, so that the last of it can be read four bytes at a time.)
        let DecompBuffer = UnsafeMutableRawPointer.allocate(byteCount: decompBufferLength + 4, alignment: 4)
        DecompBuffer.initializeMemory(as: UInt8.self, repeating: 0, count: decompBufferLength + 4)
        defer { DecompBuffer.deallocate() }

        for channel in 0 ..< 2 {
            guard let base = channel == 0 ? left : right else { break }
            var done = 0
            while done < length {
                let BytesToUnpack = min(32768, length - done)
                if let PackedLen = m.u16IfThere() {
                    if m.read(Int(PackedLen), into: DecompBuffer) < Int(PackedLen) { ended = true }
                } else {
                    ended = true
                }
                if !ended { fromTheFile += BytesToUnpack }
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
        return fromTheFile
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
    static func defaultMIDIData() -> [UInt8] {
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
    /// Which of Impulse Tracker's ways an IT file asks for, if it is one that OpenMPT takes for
    /// ModPlug Tracker's or its own, which it knows by these signs; nil for any other, which is
    /// played in all of Impulse Tracker's ways. And the version of OpenMPT it was last saved
    /// with, a byte for each of its four parts, or a number greater than any for another tracker's file.
    private static func modPlugWays(_ data: [UInt8], Cwtv: UInt16, Cmwt: UInt16, OrdNum: Int, extras: inout ModPlugExtras,
                                    extrasRead: Bool) -> (asked: [Bool]?, savedWith: Int, ownLevels: Bool) {
        let file = ByteReader(data)
        let reserved = file.u16le(0x3C) | file.u16le(0x3E) << 16
        let byOpenMPT = Cwtv & 0xF000 == 0x5000
        var savedWith = 0
        var byModPlug = false
        if byOpenMPT {
            savedWith = Int(Cwtv & 0x0FFF) << 16
            // ("OMPT" there is a file saved as OpenMPT plays; without it, one saved to be played as Impulse Tracker would.)
            if reserved == 0x5450_4D4F { byModPlug = true } else if savedWith >= 0x0129_0000 { savedWith |= reserved & 0xFFFF }
        } else if Cmwt == 0x0888 || Cwtv == 0x0888 {
            byModPlug = true
            savedWith = 0x0117_0000
        } else if Cwtv == 0x0214, Cmwt == 0x0202, reserved == 0 {
            byModPlug = true
            savedWith = 0x0109_0000
        } else if Cwtv == 0x0300, Cmwt == 0x0300, reserved == 0, OrdNum == 256, file[0x34] == 128, file[0x35] == 0 {
            byModPlug = true
            savedWith = 0x0117_0220
        } else if Cwtv == 0x0217, Cmwt == 0x0200, reserved == 0, !extras.byBeRoTracker {
            byModPlug = true
            savedWith = 0x0116_0000
        }
        // (The letters that begin a song's extras turn up by chance in other trackers' files.)
        guard byModPlug || byOpenMPT else { return (nil, Int(Int32.max), false) }
        if !extrasRead { extras.readSongExtras(file) }
        // A file saved to be played as Impulse Tracker would play it asks for all of its ways, as
        // far as the OpenMPT that saved it had them; any other asks for those it lists, and for
        // none if it has no list.
        var asked = byModPlug && !extras.byBeRoTracker ? [] : [Bool](repeating: true, count: 64)
        if extras.hasSongExtras {
            asked = extras.behaviours
            if let saved = extras.savedWith { savedWith = saved }
        }
        // (And such a file is added up ModPlug Tracker's own way unless it says another.)
        return (asked, savedWith, byModPlug && !extras.byBeRoTracker)
    }

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
