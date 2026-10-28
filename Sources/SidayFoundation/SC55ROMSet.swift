// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// The ROMs of a Roland SC-55 that go together, whole, ready for its synthesiser: its controller's program
/// (the H8/532's own 32 KB) and the board's ROM of more of it, both of one firmware version, and its three
/// wave ROMs as they are dumped (their lines out of order; the synthesiser puts them back).
public struct SC55ROMSet: Sendable {
    /// The firmware's version, as Roland numbers it ("1.21").
    public let version: String
    public let program: [UInt8]
    public let extraProgram: [UInt8]
    public let waves: [[UInt8]]

    public init(version: String, program: [UInt8], extraProgram: [UInt8], waves: [[UInt8]]) {
        self.version = version
        self.program = program
        self.extraProgram = extraProgram
        self.waves = waves
    }

    /// What it is, for a listener.
    public var name: String { "Roland SC-55, firmware " + version }
}
