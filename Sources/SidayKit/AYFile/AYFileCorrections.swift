// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation

/// Fixes for individual `.ay` files whose ripped player does not reproduce the timing of the program
/// it was taken from. A file is recognised by the MD5 of its whole contents.
///
/// A ZXAYEMUL file can only ask for its interrupt routine once per 1/50 s. Programs that drove their
/// music from a free-running loop instead were ripped with a wrapper that approximates the rate by
/// calling the music routine more than once on some interrupts, which is both uneven and only as
/// accurate as the ripper's estimate.
struct AYFileCorrection {
    /// Zero-based song the correction applies to.
    var song: Int
    /// Routine to call on every tick instead of the file's interrupt routine; nil keeps the file's.
    var interruptAddress: Int?
    /// Ticks per second; nil keeps the usual 50.
    var frameHz: Double?
    /// CPU clock in Hz; nil keeps the usual one.
    var cpuHz: Double?
    /// Call the routine again as soon as it returns, with interrupts off.
    var freeRunning = false
    /// Ticks that replace one of the file's 1/50 s interrupts, to convert its length and fade.
    var ticksPerFrame: Double

    static func corrections(for data: Data) -> [AYFileCorrection] {
        let hash = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return table[hash] ?? []
    }

    func apply(to song: inout AYFile.Song) {
        if let interruptAddress { song.interruptAddress = interruptAddress }
        song.frameHz = frameHz
        song.cpuHz = cpuHz
        song.freeRunning = freeRunning
        song.timingCorrected = true
        song.lengthFrames = Int((Double(song.lengthFrames) * ticksPerFrame).rounded())
        song.fadeFrames = Int((Double(song.fadeFrames) * ticksPerFrame).rounded())
    }

    // Rates were measured by running each game on an emulated 128K with memory contention and counting
    // calls to the music routine.

    /// Exolon (Hewson, 1987), 128K title tune. The game runs with interrupts off and calls the music
    /// routine at $B767 on every fourth character its title screen prints: 78.9 calls per second, one
    /// about every 44,960 T-states. The rip's wrapper at $CB20 makes nine calls every five interrupts,
    /// 90 per second.
    private static let exolon = [AYFileCorrection(song: 0, interruptAddress: 0xB767, frameHz: 78.9, ticksPerFrame: 9.0 / 5.0)]

    /// Kenny Dalglish Soccer Match (Impressions, 1990), 128K menu tune. The routine at $C01E plays one
    /// step of the tune and paces itself with delay loops, about 403,000 T-states a call. The game's menu
    /// calls it back to back with interrupts off, on average every 403,345 T-states of a 128K's 3.5469 MHz
    /// clock (113.7 ms). Run from the 1/50 s interrupt it starts every sixth frame, 120 ms apart.
    private static let kennyDalglish = [
        AYFileCorrection(song: 0, interruptAddress: nil, frameHz: nil, cpuHz: 3_546_900, freeRunning: true, ticksPerFrame: 113.72 / 120),
    ]

    private static let table: [String: [AYFileCorrection]] = [
        // Two rips of Exolon carry the same wrapper: the 20-song one with the beeper effects and a single-song one.
        "d74ea09a7d0e308ba4485508a82b5423": exolon,
        "a6b3cc8298c1f5cfac511351b86e03e0": exolon,
        "32971ef4223e4ea7a61a227583180ebf": kennyDalglish,
    ]
}
