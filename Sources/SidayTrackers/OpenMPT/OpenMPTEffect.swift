// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// what its effects have in common (`soundlib/plugins/PlugInterface.h`).

/// One of OpenMPT's own effects: an echo, a reverb, a chorus and the like, which the tracker has built in
/// so that a tune that asks for one sounds the same wherever it is played. Most of them are OpenMPT's
/// remakes of the effects that came with Windows, which is what such tunes were written with.
///
/// An effect is given sound a stretch at a time and gives back what it makes of it. What becomes of that
/// is not its business: how much of it is heard beside what went in, and whether it goes on to another
/// effect or to the listener, is for whoever owns the effect, as it is for OpenMPT's mixer.
///
/// Its settings are numbered, and each is a number from nought to one whatever it stands for, since that
/// is how OpenMPT keeps them, how a file stores them, and how a tune changes them as it plays. An effect
/// starts with the settings OpenMPT gives a new one.
class OpenMPTEffect {
    /// How many frames the tick of the tune that is being played is: what OpenMPT keeps for all
    /// its effects to ask, and one of them, an echo that counts its time in ticks, does.
    var tickFrames = 0
    /// How many settings it has, each a number from nought to one as OpenMPT keeps and files them.
    var parameterCount: Int { 0 }
    func parameter(_ index: Int) -> Float { 0 }
    func setParameter(_ index: Int, _ value: Float) {}
    /// Made ready to play from silence: OpenMPT's `Resume` and `PositionChanged`.
    func resume() {}
    /// `frames` frames from the two inputs to the two outputs, which are four different buffers.
    /// This is OpenMPT's `Process` up to, and not including, its call of `ProcessMixOps`.
    func process(inLeft: UnsafePointer<Float>, inRight: UnsafePointer<Float>, outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>, frames: Int) {}
    /// Takes its settings from the bytes a file keeps for it, and says whether it did: OpenMPT's `SetChunk`.
    /// Most effects are filed as a list of their numbered settings, which is for whoever reads the file
    /// to hand over one at a time, and they say no; the few that are filed in a form of their own say
    /// yes to bytes that are in that form.
    func restore(chunk: [UInt8]) -> Bool { false }
}
