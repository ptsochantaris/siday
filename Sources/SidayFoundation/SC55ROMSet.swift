// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// Which Sound Canvas a set of ROMs makes.
public enum SC55Model: String, Sendable, CaseIterable {
    /// Roland's SC-55 (1991), the first.
    case sc55
    /// The SC-55mkII (1993): more sounds from larger wave ROMs, 28 voices, and a second processor of its own
    /// for its MIDI ins.
    case sc55mk2

    /// What it is called, for a listener.
    public var name: String {
        switch self {
        case .sc55: "SC-55"
        case .sc55mk2: "SC-55mkII"
        }
    }
}

/// The ROMs of a Roland Sound Canvas that go together, whole, ready for its synthesiser: its controller's
/// program (the H8/532's own 32 KB) and the board's ROM of more of it, both of one firmware version; on the
/// SC-55mkII, its second processor's program; and its wave ROMs as they are dumped (their lines out of
/// order; the synthesiser puts them back): three of a megabyte on the SC-55, one of two and one of one on the
/// SC-55mkII.
public struct SC55ROMSet: Sendable {
    public let model: SC55Model
    /// The firmware's version, as Roland numbers it ("1.21").
    public let version: String
    public let program: [UInt8]
    public let extraProgram: [UInt8]
    /// The SC-55mkII's second processor's program (4 KB); empty for the SC-55, which has none.
    public let subProgram: [UInt8]
    public let waves: [[UInt8]]
    /// The wave ROMs with their lines put back in order, and the synthesiser as it is once its firmware has
    /// started, as bytes: worked out once when the set is put together (`assemble`), so that each tune
    /// played need not do it again. Empty if they were not.
    public let unscrambledWaves: [UInt8]
    public let started: [UInt8]

    public init(model: SC55Model = .sc55, version: String, program: [UInt8], extraProgram: [UInt8], subProgram: [UInt8] = [], waves: [[UInt8]],
                unscrambledWaves: [UInt8] = [], started: [UInt8] = []) {
        self.model = model
        self.version = version
        self.program = program
        self.extraProgram = extraProgram
        self.subProgram = subProgram
        self.waves = waves
        self.unscrambledWaves = unscrambledWaves
        self.started = started
    }

    /// What it is, for a listener.
    public var name: String { "Roland " + model.name + ", firmware " + version }
}

extension [SC55ROMSet] {
    /// The Sound Canvas to play on, of those whose ROMs are here, whole: the model asked for if it is here,
    /// and otherwise, or when none is asked for, the newest that is (the SC-55mkII before the SC-55).
    public func soundCanvas(_ model: SC55Model?) -> SC55ROMSet? {
        model.flatMap { asked in first { $0.model == asked } } ?? first { $0.model == .sc55mk2 } ?? first { $0.model == .sc55 } ?? first
    }
}
