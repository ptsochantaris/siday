// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// Output sample rate used throughout. Everything renders interleaved stereo Float32 at this rate.
public let outputSampleRate = 48000

public struct TuneInfo: Sendable {
    public var format: String
    public var title = ""
    public var author = ""
    public var comment = ""
    /// Free-form detail such as tracker version or chip model.
    public var detail = ""
    /// What the file asks for that is not played as it asks: an instrument that is not heard, a
    /// command that is left out, a sample that is cut short. A sentence for each, to be shown as it
    /// is; none for a file that is played whole. A file that cannot be played at all is another
    /// matter, and is refused (see `TuneError`). Only what the tune itself uses is said, and only
    /// what may be heard: it is known when the file is loaded, and does not change as it plays.
    public var shortfalls: [String] = []
    /// The chips it is heard as made by, the one that makes the most of it first: set by a player
    /// that knows better than its kind of file does (`TuneFormat.likelyChip`), and otherwise left empty.
    public var chips: [SoundChip] = []

    public init(format: String) {
        self.format = format
    }
}

/// What can be said of one song of a tune without playing it.
public struct SongInfo: Sendable, Equatable {
    /// The song's own name, where the file names its songs; otherwise empty.
    public var title: String
    /// Its length in seconds, where the file or a database gives one.
    public var length: Double?
    /// True if it is known that there is nothing to it: a stretch of a module in which no note is
    /// played, which has a length all the same.
    public var empty: Bool
    /// True while how long it is has still to be found, by a player that finds its songs' lengths by
    /// playing them through unheard, and has not yet played this one (`LoadOptions.measuresEverySong`):
    /// `length` is nil and `empty` false until then.
    public var pending: Bool

    public init(title: String = "", length: Double? = nil, empty: Bool = false, pending: Bool = false) {
        self.title = title
        self.length = length
        self.empty = empty
        self.pending = pending
    }
}

/// What a player that finds its songs' lengths by playing them through unheard found of them, to be
/// given to another load of the same file (`LoadOptions.songMeasures`) so that it need not find it
/// again. Only a player of the same file can take it.
public struct SongMeasures: Sendable, Equatable {
    /// Each song's length in the player's own clocks; nil for one that never comes to an end.
    package var lengths: [UInt64?]

    package init(lengths: [UInt64?]) {
        self.lengths = lengths
    }

    /// As bytes, for a front end to keep or to hand from one thread or worker to another: nine for
    /// each song, a 1 for one that ends and then its length, low byte first.
    public var bytes: [UInt8] {
        lengths.flatMap { length in [length == nil ? 0 : 1] + (0 ..< 8).map { UInt8(truncatingIfNeeded: (length ?? 0) >> ($0 * 8)) } }
    }

    /// From `bytes`; nil for bytes that are not such.
    public init?(bytes: [UInt8]) {
        guard bytes.count % 9 == 0 else { return nil }
        lengths = stride(from: 0, to: bytes.count, by: 9).map { at in
            bytes[at] == 0 ? nil : (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(bytes[at + 1 + $1]) << ($1 * 8) }
        }
    }
}

/// A loaded tune. The player calls this once per audio block; nothing below it is dynamically dispatched.
/// Instances are confined to the thread that created them.
public protocol Renderer: AnyObject {
    var info: TuneInfo { get }
    var subsongCount: Int { get }
    /// Zero-based index of the song the file asks to be played first.
    var defaultSubsong: Int { get }
    var currentSubsong: Int { get }
    /// Restarts playback at the given subsong.
    func select(subsong: Int)
    /// The tune's songs in order, `subsongCount` of them, with what is known of each before it is played.
    var songs: [SongInfo] { get }
    /// Length of the current subsong in seconds when the format knows it (to the loop point for trackers).
    var knownLength: Double? { get }
    /// For a tune that ends by looping, how long each pass after the first is, in seconds: from the
    /// place it goes back to, to the place it goes back from. Nil when it goes back to its beginning,
    /// or it is not known where it goes back to, and a pass is taken to be the whole of `knownLength`.
    var loopLength: Double? { get }
    /// Seconds of fade-out the file itself asks for, if any.
    var fileFade: Double? { get }
    /// Number of times the tune has wrapped to its loop point, for formats that can tell.
    var loopCount: Int { get }
    /// True for formats that end by counting loops (trackers, register dumps) rather than on the clock.
    var endsByLooping: Bool { get }
    /// True once a tune that does not loop has finished.
    var hasEnded: Bool { get }
    /// True if the tune is played on an Amiga's sound chip, so that which Amiga it is, and how far
    /// apart its two sides are kept, are part of how it sounds.
    var isPlayedOnAnAmiga: Bool { get }
    /// Renders `frames` stereo frames (2 × frames floats).
    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int)
    /// How many voices the tune is made of, for showing how loud each is: a chip's channels, a
    /// module's tracks. None, for a tune that cannot say.
    var channelCount: Int { get }
    /// How many of them, the first, are there in every tune of the kind. The rest are ones a tune may
    /// never use (a ZX Spectrum's beeper, the samples played on a SID's volume), and are worth showing
    /// only once they have been heard.
    var channelsAlwaysShown: Int { get }
    /// How loud each voice has been in the sound rendered since this was last asked: `channelCount`
    /// numbers, each from 0 to 1, where 1 is as loud as such a voice can be. See `ChannelLight`.
    func takeChannelLevels(into levels: UnsafeMutablePointer<Float>)
    /// What each voice is playing: its pitch now (see `ChannelPitch`; nought for a voice with none),
    /// and whether a note has been started on it since this was last asked. `channelCount` of each.
    func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>)
    /// Which side the tune has each voice on now: from -1, all on the left, to 1, all on the right.
    /// Nought is the middle, and is what every voice has in a tune that has no sides. `channelCount`
    /// of them. A module's voices are where the module puts them, and an Amiga's where the Amiga
    /// has them, whether or not the tune is being heard in mono or with its sides brought nearer
    /// together; the AY chip's three are where they are heard, or would be if it were heard in
    /// stereo. None of it depends on what the tune is being listened to through.
    func takeChannelSides(into sides: UnsafeMutablePointer<Float>)
    /// Which voices are playing a recording of a sound, a sample, and not a sound a chip makes of
    /// itself (a square wave, an FM voice, a waveform drawn in a tracker): true for those.
    /// `channelCount` of them. A voice that may play either says which it is playing now.
    func takeChannelsSampled(into sampled: UnsafeMutablePointer<Bool>)
    /// True if the tune's voices play samples: what `takeChannelsSampled` says of every one of
    /// them, for a player that does not say it voice by voice.
    var channelsAreSampled: Bool { get }
    /// The voice that is no chip's, nor a sample's, but a loudspeaker that the computer's own code
    /// moves in and out, a click at a time: the ZX Spectrum's beeper, the 8-bit Atari's console
    /// speaker. Nil if the tune has none.
    var speakerChannel: Int? { get }
    /// Starts keeping what each voice sounds like, for its scope, and gives what it is kept in; nil
    /// for a player that cannot. Kept from then on, at a little cost, so asked for only where
    /// scopes are drawn.
    func keepChannelWaves() -> ChannelWaves?
    /// Leaves voices out of the sound: a mark for each of the `channelCount`, true for one that is
    /// not to be heard, and none at all for every voice heard. A voice left out goes on playing: the
    /// tune is the same tune, note for note and to the same end, and what is said of the voice here
    /// (how loud it is, its pitch, its side) is what would be said if it were heard. It is taken
    /// out where it joins the others, so what the voices of a chip share is still shared: a muted
    /// voice of a SID still goes through the filter's sums, and one of an AY chip still has its part
    /// in the envelope. With no voice left out the sound is what it was before this was ever called.
    func setMuted(_ muted: [Bool])
    /// What was found of the songs' lengths by playing them through unheard, once every song has
    /// been, for a player that finds them so; nil for one that does not, or has not found them all.
    var songMeasures: SongMeasures? { get }
    /// Gives the player what another load of the same file found of its songs (`songMeasures`), so
    /// that those it has not yet played through are known without it (`songs`). What does not fit
    /// the tune is not taken.
    func adopt(_ measures: SongMeasures)
}

public extension Renderer {
    var subsongCount: Int { 1 }
    var defaultSubsong: Int { 0 }
    var currentSubsong: Int { 0 }
    func select(subsong _: Int) {}
    var songs: [SongInfo] { Array(repeating: SongInfo(), count: subsongCount) }
    var fileFade: Double? { nil }
    var loopLength: Double? { nil }
    var hasEnded: Bool { false }
    var loopCount: Int { 0 }
    var endsByLooping: Bool { false }
    var isPlayedOnAnAmiga: Bool { false }
    var channelCount: Int { 0 }
    var channelsAlwaysShown: Int { channelCount }
    func takeChannelLevels(into _: UnsafeMutablePointer<Float>) {}
    func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        for voice in 0 ..< channelCount {
            pitches[voice] = 0
            struck[voice] = false
        }
    }
    func takeChannelSides(into sides: UnsafeMutablePointer<Float>) {
        for voice in 0 ..< channelCount { sides[voice] = 0 }
    }
    var channelsAreSampled: Bool { false }
    var speakerChannel: Int? { nil }
    func keepChannelWaves() -> ChannelWaves? { nil }
    func setMuted(_: [Bool]) {}
    var songMeasures: SongMeasures? { nil }
    func adopt(_: SongMeasures) {}
    func takeChannelsSampled(into sampled: UnsafeMutablePointer<Bool>) {
        let all = channelsAreSampled
        for voice in 0 ..< channelCount { sampled[voice] = all }
    }
}

/// A player whose output can be had exactly as the player it is ported from makes it, in sixteen bits,
/// for comparing the two: one channel for the Atari ST (AtariAudio), left and right in turn for a
/// module (pt2-clone).
public protocol ReferenceComparable {
    func renderRaw(frames: Int) -> [Int16]
}

public enum TuneError: Error, CustomStringConvertible {
    case unreadable(String)
    case unsupported(String)
    case malformed(String)
    /// The tune keeps part of itself in another file (see `Companions`), which was not given with it.
    case missingCompanion(String)

    public var description: String {
        switch self {
        case let .unreadable(s): "unreadable: \(s)"
        case let .unsupported(s): "unsupported: \(s)"
        case let .malformed(s): "malformed: \(s)"
        case let .missingCompanion(s): s
        }
    }
}

public enum StereoLayout: String, Sendable, CaseIterable {
    case abc, acb, mono
}

public enum AYChipType: String, Sendable, CaseIterable {
    case ay, ym
}

public struct LoadOptions: Sendable {
    public var stereo: StereoLayout = .mono
    /// Overrides the chip type the file (or format default) would choose.
    public var chipType: AYChipType?
    /// Overrides the AY clock in Hz.
    public var clockHz: Double?
    /// Overrides the player interrupt rate in Hz.
    public var frameHz: Double?
    public var sidModel: SIDModelChoice = .auto
    public var sidEngine: SIDEngineChoice = .residfp
    /// Where the 6581's filter sits, 0 (bright) to 1 (dark). Real chips varied this much from one to the
    /// next. Only the reSIDfp engine has it.
    public var sidFilterCurve = 0.5
    /// HVSC's song-length database, for SID tunes: a copy of its `Songlengths.md5`, asked first.
    public var songLengths: SongLengthDatabase?
    /// A SID tune that `songLengths` does not know, or that there is no `songLengths` to ask, is looked
    /// up in the lengths that come with the player (`BuiltInSongLengths`).
    public var usesBuiltInSongLengths = true
    /// Run an AY file's songs silently to find the lengths the file does not give. Off saves the time when
    /// lengths are not wanted.
    public var findsMissingLengths = true
    /// Whether a player that finds its songs' lengths by playing them through unheard (the emulated
    /// Amiga's, which can take a second or two over a file of many songs) plays every song through
    /// when the tune is loaded, or only as many as it needs to know which to start with. The others
    /// are played through as they are selected, or are given from another load of the file (see
    /// `Renderer.adopt`), and are `SongInfo.pending` until then. Every song comes out as long either
    /// way: the songs are always played through in the same order, which is what each length can
    /// depend on.
    public var measuresEverySong = true
    /// What another load of the same file found of its songs (`Renderer.songMeasures`), so that this
    /// one need not play them through.
    public var songMeasures: SongMeasures?
    /// Which Amiga a module is heard on.
    public var amigaModel: AmigaModel = .a1200
    /// How far apart the Amiga's two sides are kept, from 0 (together) to 1 (the Amiga's own, with
    /// nothing in between, which is hard on the ears in headphones).
    public var amigaSeparation = 0.2
    /// The same for a recording of the first Sound Blaster Pro's two FM chips, one heard on each side,
    /// or of the Creative Music System's chips, whose voices are mostly each on one side.
    public var sbProSeparation = 0.2
    /// The sound card an S3M file is played on; nil for the one the file was saved with, where it
    /// says, and otherwise the Gravis Ultrasound.
    public var s3mCard: ST3Card?
    /// How a Sierra AGI sound is played: as the Amiga versions of the games played it, with Sierra's
    /// first routine or its later one, or on the PC's chip.
    public var agiReplay: AGIReplay = .amiga
    /// The ROMs of an MT-32 of the LAPC-I's generation, kept by the front end once they were given it:
    /// a MIDI file written for the MT-32 is played on it when they are here, and on FM when they are not.
    public var mt32ROMs: MT32ROMSet?

    public init() {}
}

/// Which Amiga the sound comes out of. The two differ in what stands between the chip and the socket.
public enum AmigaModel: String, Sendable, CaseIterable {
    /// The Amiga 500: everything goes through a low-pass filter at 4.4 kHz, which is the muffled sound
    /// most music for the machine was written on.
    case a500
    /// The Amiga 1200: no such filter worth the name, and a brighter sound for it.
    case a1200
}

/// The sound card a tune is played on. Scream Tracker played the same tune quite differently on each.
public enum ST3Card: String, Sendable, CaseIterable {
    /// The Gravis Ultrasound: the card mixes the voices itself, smoothly, each where it is placed.
    case gus
    /// The Sound Blaster Pro: Scream Tracker mixes the voices itself, into eight bits at 22 kHz in
    /// stereo, eight channels hard to each side.
    case sb
}

/// How a Sierra AGI sound is played: as Sierra's interpreter for the Amiga played it, with either of
/// the two routines it had in its time, or on the chip it was written for.
public enum AGIReplay: String, Sendable, CaseIterable {
    /// Sierra's first routine for the Amiga: each tone a square wave, its volume as the note says.
    case amiga
    /// Its later routine: each tone a rounder wave, which dies away over a second of its note.
    case amigaLater = "amiga-later"
    /// The PCjr's and Tandy 1000's chip, as the interpreter for those wrote to it.
    case pc
}

/// Which SID emulation plays a tune.
public enum SIDEngineChoice: String, Sendable, CaseIterable {
    /// The port of reSIDfp: the more faithful 6581 filter, and about twice the work.
    case residfp
    /// The port of reSID 1.0.
    case resid
}

public enum SIDModelChoice: String, Sendable, CaseIterable {
    case auto
    case mos6581 = "6581"
    case mos8580 = "8580"
}

/// 64 KB of zero-initialised memory that a module is copied into. Tracker modules were written for a
/// 16-bit address space, and their players are ported with the same wrap-around addressing, so a
/// corrupt pointer reads some other byte of the module instead of trapping.
public final class ModuleMemory {
    public let bytes: UnsafeMutablePointer<UInt8>
    public let size: Int

    public init(_ data: [UInt8]) {
        bytes = .allocate(capacity: 65536)
        bytes.initialize(repeating: 0, count: 65536)
        size = min(data.count, 65536)
        data.withUnsafeBufferPointer { source in
            if let base = source.baseAddress, size > 0 {
                bytes.update(from: base, count: size)
            }
        }
    }

    deinit {
        bytes.deallocate()
    }

    // (These three, and the reader's below, are inlinable, for the players of every other module.)
    @inlinable @inline(__always) public subscript(_ address: Int) -> UInt8 {
        bytes[address & 0xFFFF]
    }

    /// Little-endian 16-bit read.
    @inlinable @inline(__always) public func word(_ address: Int) -> Int {
        Int(bytes[address & 0xFFFF]) | Int(bytes[(address &+ 1) & 0xFFFF]) << 8
    }

    @inlinable @inline(__always) public func signed(_ address: Int) -> Int {
        Int(Int8(bitPattern: bytes[address & 0xFFFF]))
    }

    /// Text field with trailing padding removed; bytes outside printable ASCII become spaces.
    public func text(at address: Int, length: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for i in 0 ..< length {
            let b = self[address + i]
            scalars.append(Unicode.Scalar(b >= 0x20 && b < 0x7F ? b : 0x20))
        }
        return String(scalars).trimmed()
    }
}

/// Bounds-checked view over file bytes: out-of-range reads return zero.
public struct ByteReader {
    public let data: [UInt8]

    public init(_ bytes: [UInt8]) {
        data = bytes
    }

    @inlinable public var count: Int { data.count }

    @inlinable @inline(__always) public subscript(_ i: Int) -> UInt8 {
        i >= 0 && i < data.count ? data[i] : 0
    }

    @inlinable public func u16le(_ i: Int) -> Int { Int(self[i]) | Int(self[i + 1]) << 8 }
    @inlinable public func u16be(_ i: Int) -> Int { Int(self[i]) << 8 | Int(self[i + 1]) }
    @inlinable public func s16be(_ i: Int) -> Int { Int(Int16(truncatingIfNeeded: u16be(i))) }
    @inlinable public func s16le(_ i: Int) -> Int { Int(Int16(truncatingIfNeeded: u16le(i))) }
    @inlinable public func u32le(_ i: Int) -> Int { u16le(i) | u16le(i + 2) << 16 }
    @inlinable public func u32be(_ i: Int) -> Int { u16be(i) << 16 | u16be(i + 2) }

    /// Reads a NUL-terminated string starting at `i`; returns the string and the index after the terminator.
    package func cString(at i: Int, encoding: TextEncoding = .latin1) -> (String, Int) {
        var end = i
        while end < data.count, data[end] != 0 { end += 1 }
        let s = (i < data.count ? encoding.decode(data[i ..< end]) : nil) ?? ""
        return (s.trimmed(newlines: true), end + 1)
    }

    public func ascii(at i: Int, length: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for k in 0 ..< length {
            let b = self[i + k]
            if b == 0 { break }
            scalars.append(Unicode.Scalar(b >= 0x20 && b < 0x7F ? b : 0x20))
        }
        return String(scalars).trimmed()
    }

    /// A text field of a file from a DOS program, up to its first zero byte, in the PC's own
    /// characters: the lines, blocks and accented letters that titles were decorated with are kept.
    package func dos(at i: Int, length: Int) -> String {
        encoded(at: i, length: length, as: .dos)
    }

    /// A text field up to its first zero byte, in one of the encodings tune files were written in.
    /// (If a byte of it is nothing in that encoding, the field is read as plain letters.)
    package func encoded(at i: Int, length: Int, as encoding: TextEncoding) -> String {
        var bytes: [UInt8] = []
        for k in 0 ..< max(0, length) {
            let b = self[i + k]
            if b == 0 { break }
            bytes.append(b)
        }
        return encoding.decode(bytes)?.trimmed() ?? ascii(at: i, length: length)
    }
}
