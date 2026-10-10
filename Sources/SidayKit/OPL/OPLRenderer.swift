// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A tune for an AdLib or Sound Blaster card's FM chip, as its player runs it: a tick of the PC's
/// timer at a time, on each of which the chip's registers are set.
protocol OPLTune: AnyObject {
    /// One tick of the tune's clock.
    /// - Returns: how many of the chip's samples there are until the next, or nil if the tune ended
    ///   on this one.
    func tick() -> Int?
    /// What is to be said of the tune once it has been played through: the player and its voices.
    var detail: String { get }
}

/// Plays a tune for the FM chip: keeps the tune's clock and the chip in step, and brings what the
/// chip makes to the player's rate.
///
/// Such a tune does not go round. It ends, and its last notes are given a second to die away. Some
/// would ring on for longer than that, so the end of the second is faded.
final class OPLRenderer<Tune: OPLTune>: Renderer, ReferenceComparable {
    private(set) var info: TuneInfo
    private(set) var knownLength: Double?
    private(set) var hasEnded = false

    private let card = OPLCard()
    /// Starts the tune afresh, on a card or on none.
    private let start: (OPLCard?) -> Tune
    private var tune: Tune
    /// The chip's samples still to make after the tune has ended; nil while it plays.
    private var tail: Int?

    /// How long the last notes are given to die away, in the chip's samples.
    private static var tailLength: Int { 49716 }
    /// How much of that is faded: a fifth of a second.
    private static var fadeLength: Int { 9943 }
    /// An hour, in the chip's samples: a tune that has not ended by then is taken to have no end.
    private static var longest: Int { 3600 * 49716 }
    /// Set by measure, so that a tune on the FM chip is about as loud as the others it is played among,
    /// while the loudest of them still fit. The chip itself is quiet: it leaves room for nine voices at
    /// full level, and few tunes come near that.
    private static var gain: Float { 1.4 }

    init(info: TuneInfo, start: @escaping (OPLCard?) -> Tune) {
        self.start = start
        var info = info

        // Once through in silence, to find how long it is.
        let silent = start(nil)
        var samples = 0
        while samples < Self.longest {
            guard let more = silent.tick() else {
                knownLength = Double(samples + Self.tailLength) / OPL3Chip.rate
                break
            }
            samples += more
        }
        info.detail = silent.detail
        self.info = info

        tune = start(card)
    }

    private func restart() {
        card.reset()
        tune = start(card)
        tail = nil
        hasEnded = false
    }

    func select(subsong _: Int) {
        restart()
    }

    /// Runs the tune's clock until the chip has samples to make, or the tune is over.
    private func advance() {
        while card.samplesLeft == 0, !hasEnded {
            if tail != nil {
                hasEnded = true
            } else if let samples = tune.tick() {
                card.samplesLeft = samples
            } else {
                tail = Self.tailLength
                card.samplesLeft = Self.tailLength
            }
        }
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            advance()
            if hasEnded {
                (buffer + done * 2).update(repeating: 0, count: (frames - done) * 2)
                return
            }
            done += card.render(into: buffer + done * 2, frames: frames - done, gain: Self.gain, fade: tail == nil ? 0 : Self.fadeLength)
        }
    }

    /// The chip's nine voices. Where a tune has drums, they are the last three.
    var channelCount: Int { 9 }

    func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) {
        card.takeLevels(into: levels)
    }

    func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        card.takeNotes(pitches: pitches, struck: struck)
    }

    /// The tune from its start as the chip makes it: its own samples at its own rate, one channel,
    /// to the end of the tune or `frames` of them. For comparing with a reference player.
    func renderRaw(frames: Int) -> [Int16] {
        restart()
        var output: [Int16] = []
        output.reserveCapacity(min(frames, 1 << 24))
        while output.count < frames {
            advance()
            if hasEnded { break }
            while card.samplesLeft > 0, output.count < frames { output.append(card.raw()) }
        }
        restart()
        return output
    }
}
