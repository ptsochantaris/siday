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

    public init(title: String = "", length: Double? = nil) {
        self.title = title
        self.length = length
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
    /// Seconds of fade-out the file itself asks for, if any.
    var fileFade: Double? { get }
    /// Number of times the tune has wrapped to its loop point, for formats that can tell.
    var loopCount: Int { get }
    /// True for formats that end by counting loops (trackers, register dumps) rather than on the clock.
    var endsByLooping: Bool { get }
    /// True once a tune that does not loop has finished.
    var hasEnded: Bool { get }
    /// Renders `frames` stereo frames (2 × frames floats).
    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int)
}

public extension Renderer {
    var subsongCount: Int { 1 }
    var defaultSubsong: Int { 0 }
    var currentSubsong: Int { 0 }
    func select(subsong _: Int) {}
    var songs: [SongInfo] { Array(repeating: SongInfo(), count: subsongCount) }
    var fileFade: Double? { nil }
    var hasEnded: Bool { false }
    var loopCount: Int { 0 }
    var endsByLooping: Bool { false }
}

public enum TuneError: Error, CustomStringConvertible {
    case unreadable(String)
    case unsupported(String)
    case malformed(String)

    public var description: String {
        switch self {
        case let .unreadable(s): "unreadable: \(s)"
        case let .unsupported(s): "unsupported: \(s)"
        case let .malformed(s): "malformed: \(s)"
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

    public init() {}
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

    @inline(__always) public subscript(_ address: Int) -> UInt8 {
        bytes[address & 0xFFFF]
    }

    /// Little-endian 16-bit read.
    @inline(__always) public func word(_ address: Int) -> Int {
        Int(bytes[address & 0xFFFF]) | Int(bytes[(address &+ 1) & 0xFFFF]) << 8
    }

    @inline(__always) public func signed(_ address: Int) -> Int {
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

    public var count: Int { data.count }

    @inline(__always) public subscript(_ i: Int) -> UInt8 {
        i >= 0 && i < data.count ? data[i] : 0
    }

    public func u16le(_ i: Int) -> Int { Int(self[i]) | Int(self[i + 1]) << 8 }
    public func u16be(_ i: Int) -> Int { Int(self[i]) << 8 | Int(self[i + 1]) }
    public func s16be(_ i: Int) -> Int { Int(Int16(truncatingIfNeeded: u16be(i))) }
    public func u32le(_ i: Int) -> Int { u16le(i) | u16le(i + 2) << 16 }
    public func u32be(_ i: Int) -> Int { u16be(i) << 16 | u16be(i + 2) }

    /// Reads a NUL-terminated string starting at `i`; returns the string and the index after the terminator.
    func cString(at i: Int, encoding: TextEncoding = .latin1) -> (String, Int) {
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
}
