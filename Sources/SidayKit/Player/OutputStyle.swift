// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// What a tune is heard through: the one choice of how its sound is put out, for both front ends.
///
/// It is a single list and not a stereo setting beside a television one, because the two do not
/// combine: a television has one loudspeaker, and whatever is played through it comes out mono.
public enum OutputStyle: String, Sendable, CaseIterable {
    /// Both speakers the same. The usual choice: many AY tunes layer the chip's three channels into one sound.
    case mono
    /// Stereo. A module is heard in its own; the AY chip's three channels are spread across the
    /// stereo field, A left, B centre, C right.
    case abc
    /// The same, with the AY chip's B and C changed over: A left, C centre, B right. (A front end
    /// with settings can list stereo once and keep the way round among them: see `Setting.stereoOrder`.)
    case acb
    /// Through the speaker of a small early-1980s portable television in a plastic case.
    case plastic
    /// Through the speaker of a large early-1980s television in a wooden cabinet.
    case wood

    /// How the AY chip's channels are placed between the speakers. It makes no difference to a SID
    /// tune: the SID has a single output.
    public var stereo: StereoLayout {
        switch self {
        case .abc: .abc
        case .acb: .acb
        case .mono, .plastic, .wood: .mono
        }
    }

    /// The television the sound is played through, if any.
    public var television: TelevisionSet? {
        switch self {
        case .plastic: .plastic
        case .wood: .wood
        case .mono, .abc, .acb: nil
        }
    }

    /// What to call it in a list of choices.
    public var title: String {
        switch self {
        case .mono: "Mono"
        case .abc: "Stereo"
        case .acb: "Stereo (ACB)"
        case .plastic: "Plastic TV"
        case .wood: "Wooden TV"
        }
    }
}
