// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Bringing every tune to the same loudness, if the listener asks: the tunes of a format are as loud
// as each other as their files have them, and each format as loud as any other (see FORMATS.md); a
// tune that was written quiet is heard quiet, and a loud one loud. Levelling measures each song as it
// is played and turns it up or down to meet the rest.

/// How far each song is brought to the loudness of every other.
public enum Levelling: String, Sendable, CaseIterable {
    /// Not at all: each is heard as loud as its file has it.
    case off
    /// All the way.
    case full
    /// Halfway, in decibels: what is quiet is still quieter than what is loud, but not by as much.
    case partial

    public var title: String {
        switch self {
        case .off: "Off"
        case .full: "Full"
        case .partial: "Partial"
        }
    }
}

/// How loud a song is heard, as it is played from its start to its end: what levelling needs to know of it.
public struct SongLevel: Sendable, Equatable {
    /// Its integrated loudness in LUFS; none for a song that is silent, or as near as makes no difference.
    public var loudness: Double?
    /// The highest its waveform reaches, in dB of full scale (dBTP).
    public var truePeak: Double

    /// The loudness every song is brought to: where the formats themselves are levelled (the middle
    /// of the loudness of their tunes, 2026-10-16), so that levelling moves a song by how far it is
    /// from the others of its kind and leaves the kinds as loud as each other.
    public static let target = -22.95
    /// The most a song is turned up, in dB: a song that is meant to be quiet is not made loud.
    public static let mostBoost = 6.0
    /// No song is turned up so far that its peaks come nearer the top than this, in dBTP. A song
    /// is turned down as far as it needs.
    public static let highestPeak = -1.0

    public init(loudness: Double?, truePeak: Double) {
        self.loudness = loudness
        self.truePeak = truePeak
    }

    /// What the song is turned up or down by, in dB.
    public func change(_ levelling: Levelling) -> Double {
        guard levelling != .off, let loudness else { return 0 }
        var change = Self.target - loudness
        if levelling == .partial { change /= 2 }
        guard change > 0 else { return change }
        return min(change, Self.mostBoost, max(0, Self.highestPeak - truePeak))
    }

    /// The same as a factor to multiply the samples by.
    public func gain(_ levelling: Levelling) -> Float {
        Float(pow(10, change(levelling) / 20))
    }
}

/// Plays a song through, unheard, as a `TuneSession` plays it to be heard (its loops, its fade, its
/// end), and measures how loud it is. A little at a time, so that it can be done beside the song
/// being heard, or ahead of it.
public final class SongMeasurement {
    private let session: TuneSession
    private var meter = LoudnessMeter()
    private let block: UnsafeMutablePointer<Float>
    private static let blockFrames = 512
    /// What was found, once the song has been played to its end.
    public private(set) var level: SongLevel?

    /// - Parameter renderer: a player of the song, at its start, that is used for nothing else.
    public init(renderer: any Renderer, policy: PlaybackPolicy) {
        session = TuneSession(renderer: renderer, policy: policy)
        block = .allocate(capacity: Self.blockFrames * 2)
    }

    deinit {
        block.deallocate()
    }

    /// Plays about `frames` more of the song, and returns what was found once it has all been played.
    @discardableResult
    public func measure(frames: Int) -> SongLevel? {
        var done = 0
        while level == nil, done < frames {
            let produced = session.render(into: block, frames: Self.blockFrames)
            meter.take(block, frames: produced)
            done += Self.blockFrames
            if session.finished { level = SongLevel(loudness: meter.loudness, truePeak: meter.truePeak) }
        }
        return level
    }

    /// Plays the whole song and returns what was found.
    public static func measure(_ renderer: any Renderer, policy: PlaybackPolicy) -> SongLevel {
        let measurement = SongMeasurement(renderer: renderer, policy: policy)
        while true {
            if let level = measurement.measure(frames: 1 << 20) { return level }
        }
    }
}

public extension SongLevel {
    /// What a song's level can be kept under once it has been measured, so that it need not be
    /// measured again: the file's digest, the song, and every setting that makes a difference to how
    /// the song sounds or how long it is played. (What it is heard through is not among them: a song
    /// is measured and levelled before any television it is played through.)
    static func key(of file: [UInt8], song: Int, options: LoadOptions, policy: PlaybackPolicy) -> String {
        key(digest: digest(of: file), song: song, options: options, policy: policy)
    }

    /// What a file is known by in a `key`: worked out once, for a file whose songs are each to be keyed.
    static func digest(of file: [UInt8]) -> String { MD5.hex(file) }

    /// The same, from the file's `digest`.
    static func key(digest: String, song: Int, options: LoadOptions, policy: PlaybackPolicy) -> String {
        func milli(_ value: Double?) -> String { value.map { String(Int(($0 * 1000).rounded())) } ?? "-" }
        let parts = [
            "1", digest, String(song),
            options.stereo.rawValue, options.chipType?.rawValue ?? "-", milli(options.clockHz), milli(options.frameHz),
            options.sidModel.rawValue, options.sidEngine.rawValue, milli(options.sidFilterCurve),
            options.songLengths == nil ? "-" : "own", options.usesBuiltInSongLengths ? "built-in" : "-",
            options.amigaModel.rawValue, milli(options.amigaSeparation), options.s3mCard?.rawValue ?? "-",
            String(policy.loops), milli(policy.defaultTime), milli(policy.maxTime), milli(policy.loopFade), milli(policy.endFade),
        ]
        return parts.joined(separator: " ")
    }

    /// The level as it can be kept in a line of text: the loudness and the true peak, in thousandths.
    var text: String {
        "\(loudness.map { String(Int(($0 * 1000).rounded())) } ?? "-") \(Int((max(truePeak, -999) * 1000).rounded()))"
    }

    /// A level kept as `text`.
    init?(text: String) {
        let parts = text.split(separator: " ")
        guard parts.count == 2, let peak = Int(parts[1]) else { return nil }
        if parts[0] == "-" {
            loudness = nil
        } else if let loudness = Int(parts[0]) {
            self.loudness = Double(loudness) / 1000
        } else {
            return nil
        }
        truePeak = Double(peak) / 1000
    }
}

/// The gain levelling puts on what a song sounds like, as it is played: none until the song has
/// been measured, and then a glide, over a second, to what it was found to need, so that a song
/// measured while it is heard is not heard to jump. (One measured before it begins starts there.)
public struct LevelGain: Sendable {
    public private(set) var gain: Float = 1
    private var target: Float = 1
    private var step: Float = 0
    private static let glideFrames = Float(outputSampleRate)

    public init(_ gain: Float = 1) {
        self.gain = gain
        target = gain
    }

    /// Glides to a gain from where it is.
    public mutating func glide(to gain: Float) {
        target = gain
        step = (target - self.gain) / Self.glideFrames
    }

    public mutating func apply(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        if step == 0 {
            guard gain != 1 else { return }
            for i in 0 ..< frames * 2 { buffer[i] *= gain }
            return
        }
        for i in 0 ..< frames {
            gain += step
            if (step > 0 && gain >= target) || (step < 0 && gain <= target) {
                gain = target
                step = 0
            }
            buffer[2 * i] *= gain
            buffer[2 * i + 1] *= gain
        }
    }
}
