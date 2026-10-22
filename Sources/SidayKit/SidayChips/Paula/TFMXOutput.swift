// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A port of libtfmxaudiodecoder's player of TFMX (src/Chris/), Copyright (C) Michael Schwendt, used
// under the GPL-2.0-or-later, as it is at its commit dcec102 of 2026-09-26.

/// What the TFMX player plays through: Paula's registers for each voice. (For the seven voices of TFMX
/// 7V, voices 3 to 6 are mixed onto Paula's fourth by whoever plays them.)
///
/// The period and the volume of each voice are not told: they are read from the player after each
/// tick (`TFMXPlayer.period(_:)` and `volume(_:)`), as libtfmxaudiodecoder's mixer reads them.
protocol TFMXOutput {
    /// DMA on: a voice that is not playing starts at what it was last given; one playing goes on.
    mutating func on(_ voice: Int)
    mutating func off(_ voice: Int)
    /// Paula's location (an offset into the player's memory) and length in words, as last given:
    /// told every time either is set, as libtfmxaudiodecoder calls its voice's `takeNextBuf`. A voice
    /// that is not playing takes them as where to start; one that is, as where to go on from when it
    /// comes to the end of what it is playing.
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16)
    /// How many times the voice has come to the end of what it was playing and gone round again, since
    /// it was last started; nought for one that is not playing.
    func loopCount(_ voice: Int) -> UInt16
    /// For a player whose own code is run on an emulated Amiga (`AmigaMachine`), which tells Paula
    /// each thing at the moment in the tick it does it: what is told from here on is told `clocks` of
    /// Paula's clocks into the tick; and her period, volume and filter, told as they are written. (Every
    /// other player tells her all of a tick at its start, and its period, volume and filter after it.)
    mutating func timed(at clocks: Int)
    mutating func writePeriod(_ voice: Int, _ period: UInt16)
    mutating func writeVolume(_ voice: Int, _ volume: UInt16)
    mutating func writeLightFilter(_ on: Bool)
}

extension TFMXOutput {
    mutating func timed(at _: Int) {}
    mutating func writePeriod(_: Int, _: UInt16) {}
    mutating func writeVolume(_: Int, _: UInt16) {}
    mutating func writeLightFilter(_: Bool) {}
}
